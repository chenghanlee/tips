#!/usr/bin/env python3
"""Stress the actual launcher and feedback hook using disposable synthetic source."""
import argparse
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

from neovim_probe import nvim_environment, poll
from probe import MCP, alive, prepare, process_table


class LaunchedMCP(MCP):
    def __init__(self, vendor, root, output, name):
        self.root, self.name, self.counter = root, name, 0
        self.responses, self.owned = queue.Queue(), {}
        self.log = (output / f'{name}.stderr.log').open('w')
        self.transcript = (output / f'{name}.jsonl').open('w')
        env = nvim_environment(vendor, output, name, sync_reads=True, feedback=True, automatic=True)
        self.registry = Path(env['VV_MCP_REGISTRY'])
        environment = output / f'{name}.environment.json'
        environment.write_text(json.dumps(env) + '\n')
        self.proc = subprocess.Popen([
            sys.executable, str(Path(__file__).with_name('neovim_launcher.py')),
            '--vendor', str(vendor), '--workspace', str(root), '--environment', str(environment),
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, bufsize=1, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                   'clientInfo': {'name': 'hook-inversion', 'version': '1'}}, timeout=40)
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.request('tools/list', {}, timeout=10)
        self.remember()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    process_table()
    output.mkdir(parents=True)
    root, _, _, _ = prepare(output)
    results, clients = {}, []

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:400], flush=True)

    def hook(client):
        start = time.monotonic()
        proc = subprocess.run([
            sys.executable, str(Path(__file__).with_name('neovim_hook.py')),
            '--vendor', str(vendor), '--registry', str(client.registry), '--workspace', str(root),
        ], input=json.dumps({'hook_event_name': 'PostToolUse', 'tool_name': 'Bash', 'cwd': str(root)}),
            text=True, capture_output=True, timeout=7, check=True)
        return {'seconds': round(time.monotonic() - start, 3), 'output': json.loads(proc.stdout)}

    try:
        # A real MCP handshake ensures EOF exercises the supported transport lifecycle.
        for mode in ('eof', 'parent_kill'):
            client = LaunchedMCP(vendor, root, output, mode)
            clients.append(client)
            if mode == 'eof':
                client.proc.stdin.close()
            else:
                client.proc.kill()  # Keep the host's stdin pipe open deliberately.
            client.proc.wait(timeout=10)
            gone = poll(lambda: alive(client.owned), lambda value: not value, 8)
            save(mode, {'exit_code': client.proc.returncode, 'cleanup': gone})
            assert gone['matched'], f'{mode}: orphaned descendants'
            if mode == 'eof':
                assert client.proc.returncode == 0

        client = LaunchedMCP(vendor, root, output, 'failures')
        clients.append(client)
        assert hook(client)['output'] == {}
        extra = root / 'lib/new_error.ex'
        extra.write_text('defmodule V2NewError do\n  def call, do: missing_new()\nend\n')
        save('new_file', hook(client))
        assert 'missing_new/0' in json.dumps(results['new_file'])
        extra.unlink()
        save('deleted_file', hook(client))
        assert 'cleared' in json.dumps(results['deleted_file'])

        # Inject the inversion: an editor-owned unsaved change plus an external write.
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        rpc = pynvim.attach('socket', path=entry['socket'])
        caller = root / 'lib/caller.ex'
        original = caller.read_text()
        try:
            rpc.command('edit ' + str(caller))
            rpc.current.buffer.append('# unsaved sentinel')
            caller.write_text(original.replace('V2Target.answer()', 'missing_conflict()', 1))
            save('unsaved_conflict', hook(client))
            assert 'unsaved changes' in json.dumps(results['unsaved_conflict'])
            assert rpc.current.buffer[-1] == '# unsaved sentinel'
            assert 'missing_conflict' not in '\n'.join(rpc.current.buffer[:])
            save('unsaved_buffer_preserved', True)
        finally:
            caller.write_text(original)
            rpc.command('edit!')
            rpc.exec_lua('vim.lsp.stop_client(vim.lsp.get_clients(), true)')
            rpc.close()

        save('language_server_stopped', hook(client))
        assert 'unavailable' in json.dumps(results['language_server_stopped'])

        client.remember()
        client.proc.stdin.close()
        client.proc.wait(timeout=10)
        gone = poll(lambda: alive(client.owned), lambda value: not value, 8)
        save('failure_session_cleanup', gone)
        assert gone['matched']
        save('server_unavailable', hook(client))
        assert 'unavailable' in json.dumps(results['server_unavailable'])
        assert results['server_unavailable']['seconds'] < 3
        save('completed', True)
    finally:
        for client in clients:
            client.cleanup()


if __name__ == '__main__':
    main()
