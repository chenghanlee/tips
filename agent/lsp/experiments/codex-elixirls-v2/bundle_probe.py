#!/usr/bin/env python3
"""Use the installed launcher through actual stdio MCP, not an alternate server path."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading

from neovim_probe import NvimMCP, poll
from probe import alive, prepare


class BundleMCP(NvimMCP):
    def __init__(self, bundle, root, output, name):
        self.root, self.name, self.counter = root, name, 0
        self.responses, self.owned, self.nvim = queue.Queue(), {}, None
        self.log = (output / f'{name}.stderr.log').open('w')
        self.transcript = (output / f'{name}.jsonl').open('w')
        self.state_dir = output / (name + '-session')
        self.registry = self.state_dir / 'registry'
        self.proc = subprocess.Popen([sys.executable, str(bundle / 'bundle.py'), 'serve',
            '--workspace', str(root), '--state', str(self.state_dir)], cwd=root,
            env=os.environ | {'ERL_FLAGS': '+S 4:4'}, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.initialize = self.request('initialize', {'protocolVersion': '2024-11-05',
            'capabilities': {}, 'clientInfo': {'name': 'bundle-gate', 'version': '1'}}, timeout=30)
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.tools = self.request('tools/list', {})


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    root, _, _, _ = prepare(output)
    empty = root / 'lib/empty.ex'
    empty.write_text('# Intentionally no declarations.\n')
    target = root / 'lib/target.ex'
    target.write_text(target.read_text().replace('defmodule V2Target do',
        'defmodule V2Target do\n  Process.sleep(16000)'))
    results, client = {}, None
    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:500], flush=True)
    try:
        client = BundleMCP(bundle, root, output, 'symbols')
        response = client.call('lsp', operation='document_symbols', uri=str(empty), timeoutMs=2000)
        save('cold_empty_document_symbols', response)
        assert response['data']['feedback']['status'] == 'pending', response
        assert not any(response['data']['symbols'].values()), response
        for operation in ('document_symbols', 'workspace_symbols'):
            response = client.call('lsp', operation=operation, uri=str(target), query='V2', timeoutMs=2000)
            save('cold_' + operation, response)
            assert response['data']['feedback']['status'] == 'pending', response
            assert 'empty result' in response['data']['feedback']['message']
        assert poll(lambda: client.rpc().exec_lua("return require('neovim_sync').ready()"), bool, 25)['matched']
        for operation in ('document_symbols', 'workspace_symbols'):
            response = client.call('lsp', operation=operation, uri=str(target), query='V2', timeoutMs=2000)
            save('warm_' + operation, response)
            assert response['data']['feedback']['status'] == 'current', response
            assert 'V2Target' in json.dumps(response), response
        save('server_command', client.rpc().exec_lua('return vim.lsp.get_clients()[1].config.cmd'))
        client.remember()
        client.proc.stdin.close()
        client.proc.wait(timeout=8)
        save('eof_cleanup', poll(lambda: alive(client.owned), lambda p: not p, 6))
        assert results['eof_cleanup']['matched']
        save('completed', True)
    finally:
        if client: client.cleanup()


if __name__ == '__main__':
    main()
