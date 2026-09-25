#!/usr/bin/env python3
"""Replay existing Tips workload tests with live LSP; no models or source edits."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from neovim_dogfood import TASKS
from neovim_hook_inversion_probe import LaunchedMCP
from neovim_probe import poll
from probe import alive


def main():
    # These checks read the opt-in LSP trace; the launched Neovim inherits it.
    os.environ['TIPS_LSP_TRACE'] = '1'
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--cohort', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    output.mkdir(parents=True)
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    results = {}
    for name, task in TASKS.items():
        run = output / name
        run.mkdir()
        root = Path('/private/tmp/tips-lsp-sol-v2-' + name)
        values = json.loads((args.cohort / name / 'application-environment.json').read_text())
        values.pop('MIX_ENV', None)
        original_env = os.environ.copy()
        os.environ.update(values)
        client = rpc = None
        try:
            client = LaunchedMCP(vendor, root, run, name)
            entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
            rpc = pynvim.attach('socket', path=entry['socket'])
            assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 120)['matched']
            before = rpc.exec_lua('return #_G.v2_events')
            # Positive control: the no-fixture and no-build checks below mean nothing on an empty trace.
            assert before > 0, 'LSP trace is empty; TIPS_LSP_TRACE is not on'
            start = time.monotonic()
            command = ['unbuffer', 'mix', 'test', *task['tests']]
            with (run / 'mix-test.log').open('w') as log:
                proc = subprocess.run(command, cwd=root, env=os.environ | {'MIX_ENV': 'test'},
                                      stdout=log, stderr=subprocess.STDOUT, timeout=180)
            duration = time.monotonic() - start
            time.sleep(1.2)  # Drain the native watcher's notification debounce.
            events = rpc.exec_lua('return _G.v2_events')
            (run / 'events.json').write_text(json.dumps(events, indent=2) + '\n')
            later = events[before:]
            fixture_events = [e for e in later if e['method'] == 'sent:workspace/didChangeWatchedFiles'
                and any(c['uri'].startswith((root / 'tmp').as_uri() + '/') for c in e['data']['changes'])]
            builds = [e for e in later if e['method'] == 'telemetry/event' and e['data'].get('name') == 'build']
            diagnostics = client.call('lsp', operation='workspace_diagnostics', uri=str(root / 'mix.exs'))
            results[name] = {'command': command, 'exit_code': proc.returncode, 'test_seconds': duration,
                'fixture_notification_batches': len(fixture_events), 'builds_during_tests': len(builds),
                'diagnostics': diagnostics}
            assert proc.returncode == 0, (run / 'mix-test.log').read_text()[-2000:]
            assert not fixture_events, 'Disposable fixtures reached ElixirLS'
            assert not builds, 'Test output unexpectedly triggered a language-server build'
            assert not diagnostics['data'].get('error')
            assert diagnostics['data']['feedback']['status'] == 'current'
            client.remember()
            rpc.close()
            rpc = None
            client.proc.stdin.close()
            client.proc.wait(timeout=10)
            results[name]['cleanup'] = poll(lambda: alive(client.owned), lambda v: not v, 8)['matched']
            assert results[name]['cleanup']
            print(name, json.dumps(results[name])[:600], flush=True)
        finally:
            (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            if rpc:
                rpc.close()
            if client:
                client.cleanup()
            os.environ.clear()
            os.environ.update(original_env)


if __name__ == '__main__':
    main()
