#!/usr/bin/env python3
"""Measure separate beta phases on a disposable real Tips checkout."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

from bundle_probe import BundleMCP
from neovim_dogfood import environment
from neovim_probe import poll
from probe import alive, process_table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--saved-bundle', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    # A new worktree after `bundle.py prepare-deps`: only dependencies are seeded.
    parser.add_argument('--prepared', action='store_true')
    args = parser.parse_args()
    bundle, root, output = args.bundle.resolve(), args.workspace.resolve(), args.output.resolve()
    process_table()
    build = root / '.elixir_ls/build'
    if args.prepared:
        assert not any(build.glob('*/lib/tips')), 'Prepared sample needs an unbuilt project'
    else:
        assert not build.exists(), 'Cold sample needs a new worktree'
    output.mkdir(parents=True, exist_ok=False)
    values = environment(root, 0, 'performance', 'beta', 100)
    values.pop('MIX_ENV')
    os.environ.update(values)
    os.environ.pop('MIX_ENV', None)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    results, clients = {}, []
    target = root / 'lib/tips/health.ex'
    original = target.read_text()
    caller = root / 'lib/tips/search_probe.ex'
    line, text = next((i, line) for i, line in enumerate(caller.read_text().splitlines(), 1)
                      if '&Tips.ProviderConfig.mode/0' in line)
    column = text.index('mode/0') + 1

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:500], flush=True)

    def nav(client, operation):
        return client.call('lsp', operation=operation, uri=str(caller), line=line,
                           character=column, timeoutMs=1000)

    def start(installed, name):
        then = time.monotonic()
        client = BundleMCP(installed, root, output, name)
        clients.append(client)
        save(name + '_connection_s', time.monotonic() - then)
        assert results[name + '_connection_s'] < 2
        return client, then

    def close(client):
        client.remember()
        then = time.monotonic()
        client.proc.stdin.close()
        client.proc.wait(timeout=6)
        assert poll(lambda: alive(client.owned), lambda p: not p, 3)['matched']
        assert client.proc.returncode == 0, client.proc.returncode
        assert not Path(client.log.name).read_text(), Path(client.log.name).read_text()
        assert not any((client.state_dir / 'registry').glob('*.json'))
        assert not Path(client.instance['socket']).exists()
        return time.monotonic() - then

    def hook(client):
        then = time.monotonic()
        proc = subprocess.run([sys.executable, str(bundle / 'bundle.py'), 'hook',
            '--workspace', str(root), '--state', str(client.state_dir)],
            input=json.dumps({'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch'}),
            text=True, capture_output=True, check=True, timeout=6)
        return {'seconds': time.monotonic() - then, 'output': json.loads(proc.stdout)}

    try:
        client, then = start(bundle, 'cold')
        first, ready_at = {}, None
        deadline = then + 120
        while time.monotonic() < deadline:
            for operation in ('hover', 'definition', 'references'):
                if operation in first:
                    continue
                reply = nav(client, operation)
                payload = reply['data']
                useful = bool(payload.get('items')) if operation == 'hover' else bool(payload.get('locations'))
                if useful:
                    first[operation] = {'seconds': time.monotonic() - then, 'response': reply}
                    save('first_useful_' + operation, first[operation])
            state = client.rpc().exec_lua("return require('neovim_sync').status()")
            if ready_at is None and state['status'] == 'current':
                ready_at = time.monotonic() - then
                save('cold_compiler_ready_s', ready_at)
            if ready_at is not None and len(first) == 3:
                break
            time.sleep(0.2)
        assert ready_at is not None and len(first) == 3, (ready_at, first)
        save('cold_shutdown_s', close(client))
        client, then = start(bundle, 'warm')
        assert poll(lambda: client.rpc().exec_lua("return require('neovim_sync').ready()"), bool, 10)['matched']
        save('warm_compiler_ready_s', time.monotonic() - then)
        # Count completions without enabling full protocol recording in the timed runtime.
        client.rpc().exec_lua("""
          local m = require('neovim_sync'); local observe = m.observe
          _G.beta_builds = 0
          m.observe = function(method, data)
            if method == 'telemetry/event' and data.name == 'build' then _G.beta_builds = _G.beta_builds + 1 end
            return observe(method, data)
          end
        """)
        client.call('lsp', operation='hover', uri=str(target), line=1, character=13, timeoutMs=1000)
        samples = []
        for i in range(20):
            target.write_text(original.replace('can reach its database.', f'can reach its database. Probe {i:02}.'))
            sample = hook(client)
            sample['status'] = client.rpc().exec_lua("return require('neovim_sync').status()")
            assert sample['status']['status'] == 'current', sample
            assert sample['seconds'] <= 5, sample
            samples.append(sample)
        times = [sample['seconds'] for sample in samples]
        save('warm_edits', {'samples': samples, 'median_s': statistics.median(times),
            'p95_s': sorted(times)[18], 'max_s': max(times),
            'build_completions': client.rpc().exec_lua('return _G.beta_builds')})
        assert statistics.median(times) <= 2.5
        unchanged = [hook(client)['seconds'] for _ in range(10)]
        save('unchanged_hooks', {'samples': unchanged, 'median_s': statistics.median(unchanged), 'max_s': max(unchanged)})
        target.write_text(original)
        save('restore_hook', hook(client))
        save('warm_shutdown_s', close(client))
        for name, installed in (('rollback_saved', args.saved_bundle.resolve()), ('rollback_beta', bundle)):
            client, then = start(installed, name)
            assert poll(lambda: client.rpc().exec_lua("return require('neovim_sync').ready()"), bool, 15)['matched']
            save(name + '_ready_s', time.monotonic() - then)
            for operation in ('hover', 'definition', 'references'):
                reply = nav(client, operation)
                assert reply['data'].get('items') or reply['data'].get('locations'), reply
            save(name + '_shutdown_s', close(client))
        assert target.read_text() == original
        save('passed', True)
    finally:
        target.write_text(original)
        for client in clients:
            client.cleanup()


if __name__ == '__main__':
    main()
