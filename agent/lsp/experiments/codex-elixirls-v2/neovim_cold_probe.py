#!/usr/bin/env python3
"""Cold compilation, concurrent hooks and expired Stop with a real ElixirLS."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from inversion_probe import target_text
from neovim_hook_inversion_probe import LaunchedMCP
from neovim_probe import poll
from probe import prepare


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    output.mkdir(parents=True)
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    root, beta, _, _ = prepare(output)
    results, clients = {}, []

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:700], flush=True)

    def hook(client, event='PostToolUse'):
        started = time.monotonic()
        proc = subprocess.run([sys.executable, str(Path(__file__).with_name('neovim_hook.py')),
            '--vendor', str(vendor), '--registry', str(client.registry), '--workspace', str(client.root)],
            input=json.dumps({'hook_event_name': event, 'tool_name': 'apply_patch'}),
            text=True, capture_output=True, check=True, timeout=6)
        return {'seconds': time.monotonic()-started, 'output': json.loads(proc.stdout)}

    def attach(client):
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        return pynvim.attach('socket', path=entry['socket'])

    try:
        (root / 'lib/target.ex').write_text(target_text('COLD_BOUNDARY', delay=16000))
        cold = LaunchedMCP(vendor, root, output, 'cold')
        clients.append(cold)
        rpc = attach(cold)
        try:
            save('cold_start', rpc.exec_lua("return require('neovim_sync').status()"))
            assert results['cold_start']['building']
            caller = root / 'lib/caller.ex'
            caller.write_text(caller.read_text().replace('V2Target.answer()', 'missing_cold()', 1))
            save('cold_edit', hook(cold))
            assert 'pending' in json.dumps(results['cold_edit'])
            assert 4 < results['cold_edit']['seconds'] < 5
            done = poll(lambda: rpc.exec_lua("local m=require('neovim_sync'); return not m.building and m.completed==m.generation"), bool, 25)
            assert done['matched']
            save('cold_diagnostics', cold.call('lsp', operation='diagnostics', uri=str(caller)))
            assert 'missing_cold/0' in json.dumps(results['cold_diagnostics'])
            assert results['cold_diagnostics']['data']['feedback']['status'] in {'pending', 'failed'}
            assert not results['cold_diagnostics']['data'].get('error')
            assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 3)['matched']
            save('cold_late_hook', hook(cold))
            assert 'missing_cold/0' in json.dumps(results['cold_late_hook'])
            caller.write_text(caller.read_text().replace('missing_cold()', 'V2Target.answer()', 1))
            save('cold_repair', hook(cold))
            assert 'cleared' in json.dumps(results['cold_repair'])
            assert rpc.exec_lua("return require('neovim_sync').ready()")
        finally:
            rpc.close()

        warm = LaunchedMCP(vendor, beta, output, 'concurrent')
        clients.append(warm)
        rpc = attach(warm)
        try:
            (beta / 'lib/target.ex').write_text(target_text('CONCURRENT_BOUNDARY', delay=12000))
            with ThreadPoolExecutor(max_workers=2) as executor:
                jobs = [executor.submit(hook, warm) for _ in range(2)]
                replies = [job.result() for job in jobs]
            save('concurrent_hooks', replies)
            assert all(r['seconds'] < 5 for r in replies)
            assert any('pending' in json.dumps(r) for r in replies)
            assert not any('unavailable' in json.dumps(r) for r in replies)
            assert rpc.exec_lua("return require('neovim_sync').stop_pending")
            pid = rpc.exec_lua('return vim.fn.getpid()')
            try:
                os.kill(pid, signal.SIGSTOP)
                save('expired_stop', hook(warm, 'Stop'))
                assert results['expired_stop']['seconds'] < 5
                assert 'unavailable' in json.dumps(results['expired_stop'])
            finally:
                os.kill(pid, signal.SIGCONT)
            # Queued collect executes after its caller timed out. Its expiry must
            # preserve Stop delivery, even as real server messages are drained.
            rpc.exec_lua('vim.wait(300)')
            save('stop_preserved', rpc.exec_lua("return require('neovim_sync').stop_pending"))
            assert results['stop_preserved']
            save('stop_retry', hook(warm, 'Stop'))
            assert results['stop_retry']['seconds'] < 5
            assert results['stop_retry']['output']['decision'] == 'block'
            assert hook(warm, 'Stop')['output'] == {}
            save('completed', True)
        finally:
            rpc.close()
    finally:
        for client in clients:
            client.cleanup()


if __name__ == '__main__':
    main()
