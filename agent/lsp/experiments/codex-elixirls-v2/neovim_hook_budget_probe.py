#!/usr/bin/env python3
"""Real compiler acceptance for a five-second synchronous hook and final check."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from inversion_probe import target_text
from bundle_probe import BundleMCP
from neovim_hook_inversion_probe import LaunchedMCP
from neovim_probe import poll
from probe import alive, prepare, process_table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else None
    vendor = bundle / 'vendor' if bundle else args.vendor.resolve()
    output = args.output.resolve()
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    process_table()
    output.mkdir(parents=True)
    root, _, _, _ = prepare(output)
    client, results = None, {}

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:500], flush=True)

    def hook(event='PostToolUse', active=False):
        start = time.monotonic()
        command = [
            sys.executable, str(Path(__file__).with_name('neovim_hook.py')),
            '--vendor', str(vendor), '--registry', str(client.registry), '--workspace', str(root),
        ]
        if bundle:
            command = [sys.executable, str(bundle / 'bundle.py'), 'hook', '--workspace',
                       str(root), '--state', str(client.state_dir)]
        proc = subprocess.run(command, input=json.dumps({'hook_event_name': event, 'tool_name': 'Bash', 'cwd': str(root),
                             'stop_hook_active': active}),
            text=True, capture_output=True, timeout=7, check=True)
        return {'seconds': round(time.monotonic() - start, 3), 'output': json.loads(proc.stdout)}

    def slow_error(marker, delay):
        return target_text(marker, delay=delay).replace('def answer, do: :ok',
                                                       'def answer, do: missing_budget()')

    try:
        client = (BundleMCP(bundle, root, output, 'budget') if bundle else
                  LaunchedMCP(vendor, root, output, 'budget'))
        # This measures edit feedback after startup, not private-server
        # installation time. Launcher warmup may legitimately return pending.
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        ready_rpc = pynvim.attach('socket', path=entry['socket'])
        try:
            assert poll(lambda: ready_rpc.exec_lua("return require('neovim_sync').ready()"),
                        bool, 60)['matched']
        finally:
            ready_rpc.close()
        target = root / 'lib/target.ex'
        original = target.read_text()
        save('initial_stop', hook('Stop'))
        assert results['initial_stop']['output'] == {}

        target.write_text(slow_error('BUDGET_THREE', 3000))
        save('three_second_error', hook())
        assert 'missing_budget/0' in json.dumps(results['three_second_error'])
        assert 2 < results['three_second_error']['seconds'] < 4.5
        target.write_text(original)
        save('fast_repair', hook())
        assert 'cleared' in json.dumps(results['fast_repair'])
        assert results['fast_repair']['seconds'] < 1.5

        target.write_text(slow_error('BUDGET_EIGHT', 8000))
        save('eight_second_pending', hook())
        assert 'pending' in json.dumps(results['eight_second_pending']).lower()
        assert 4.6 < results['eight_second_pending']['seconds'] < 5.3
        save('unchanged_tool_does_not_wait', hook())
        assert results['unchanged_tool_does_not_wait']['output'] == {}
        assert results['unchanged_tool_does_not_wait']['seconds'] < 0.7
        save('final_edit_stop_feedback', hook('Stop'))
        assert results['final_edit_stop_feedback']['output']['decision'] == 'block'
        assert 'missing_budget/0' in json.dumps(results['final_edit_stop_feedback'])
        assert results['final_edit_stop_feedback']['seconds'] < 4.5
        save('stop_not_repeated', hook('Stop', active=True))
        assert results['stop_not_repeated']['output'] == {}
        target.write_text(original)
        assert 'cleared' in json.dumps(hook())

        # A new edit can need a final check even after a prior Stop continuation.
        target.write_text(slow_error('BUDGET_FIFTEEN', 15000))
        save('very_slow_pending', hook())
        save('stop_budget_exhausted', hook('Stop', active=True))
        assert 'pending' in json.dumps(results['stop_budget_exhausted']).lower()
        assert results['stop_budget_exhausted']['output']['decision'] == 'block'
        assert 4.6 < results['stop_budget_exhausted']['seconds'] < 5.3
        assert hook('Stop', active=True)['output'] == {}
        assert hook()['output'] == {}  # An unchanged tool must not re-arm Stop.
        assert hook('Stop', active=True)['output'] == {}
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        rpc = pynvim.attach('socket', path=entry['socket'])
        try:
            nvim_pid = rpc.exec_lua('return vim.fn.getpid()')
            assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 8)['matched']
        finally:
            rpc.close()
        assert 'missing_budget/0' in json.dumps(hook())
        target.write_text(original)
        assert 'cleared' in json.dumps(hook())
        assert hook('Stop')['output'] == {}
        try:
            os.kill(nvim_pid, signal.SIGSTOP)
            save('stalled_rpc', hook())
            assert 'unavailable' in json.dumps(results['stalled_rpc'])
            assert 4.8 < results['stalled_rpc']['seconds'] < 5.3
        finally:
            os.kill(nvim_pid, signal.SIGCONT)
        client.remember()
        client.proc.stdin.close()
        client.proc.wait(timeout=10)
        save('cleanup', poll(lambda: alive(client.owned), lambda value: not value, 8))
        assert results['cleanup']['matched']
        save('completed', True)
    finally:
        if client:
            client.cleanup()


if __name__ == '__main__':
    main()
