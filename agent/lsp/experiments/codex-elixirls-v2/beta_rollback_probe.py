#!/usr/bin/env python3
"""Supported rollback: switch one Tips worktree between immutable bundles.

Each step runs the user-facing `configure` and launches exactly the generated MCP
entry. Sequence: new, saved, new.
Timings are recorded, not asserted; navigation and strict cleanup are asserted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import tomllib

from neovim_dogfood import environment
from neovim_probe import NvimMCP, poll
from probe import alive, process_table


class ConfiguredMCP(NvimMCP):
    """The generated `mcp_servers.elixir_neovim` entry, not a harness command."""

    def __init__(self, root, output, name, server):
        self.root, self.name, self.counter = root, name, 0
        self.responses, self.owned, self.nvim = queue.Queue(), {}, None
        self.log = (output / f'{name}.stderr.log').open('w')
        self.transcript = (output / f'{name}.jsonl').open('w')
        args = server['args']
        self.state_dir = Path(args[args.index('--state') + 1])
        self.registry = self.state_dir / 'registry'
        self.proc = subprocess.Popen([server['command'], *args], cwd=server['cwd'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True,
            bufsize=1, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.initialize = self.request('initialize', {'protocolVersion': '2024-11-05',
            'capabilities': {}, 'clientInfo': {'name': 'rollback-gate', 'version': '1'}},
            timeout=30)
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.tools = self.request('tools/list', {})


def load():
    return os.getloadavg()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--saved-bundle', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    new, saved = args.bundle.resolve(), args.saved_bundle.resolve()
    root, output = args.workspace.resolve(), args.output.resolve()
    process_table()
    output.mkdir(parents=True, exist_ok=False)
    values = environment(root, 0, 'rollback', 'beta', 100)
    values.pop('MIX_ENV')
    os.environ.update(values)
    os.environ.pop('MIX_ENV', None)
    sys.path.insert(0, str(new / 'vendor/python'))
    caller = root / 'lib/tips/search_probe.ex'
    line, text = next((i, row) for i, row in enumerate(caller.read_text().splitlines(), 1)
                      if '&Tips.ProviderConfig.mode/0' in row)
    column = text.index('mode/0') + 1
    results, clients = {'load_start': load()}, []

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:400], flush=True)

    def bundle_command(bundle, *extra):
        return subprocess.run([sys.executable, str(bundle / 'bundle.py'), *extra],
                              capture_output=True, text=True, timeout=120)

    def ready(client):
        try:
            return client.rpc().exec_lua("return require('neovim_sync').ready()")
        except Exception as error:
            return 'unavailable: ' + type(error).__name__

    def close(client):
        client.remember()
        then = time.monotonic()
        client.proc.stdin.close()
        client.proc.wait(timeout=6)
        gone = poll(lambda: alive(client.owned), lambda p: not p, 3)
        return {'seconds': time.monotonic() - then, 'exit': client.proc.returncode,
                'no_survivors': gone['matched'], 'stderr': Path(client.log.name).read_text(),
                'registry_empty': not any((client.state_dir / 'registry').glob('*.json')),
                'socket_removed': not Path(client.instance['socket']).exists()}

    try:
        for index, (name, bundle) in enumerate((('new', new), ('saved', saved), ('return', new))):
            step = {'bundle': str(bundle), 'load': load()}
            doctor = bundle_command(bundle, 'doctor')
            step['doctor_exit'] = doctor.returncode
            step['manifest_sha256'] = hashlib.sha256((bundle / 'manifest.json').read_bytes()).hexdigest()
            plain = bundle_command(bundle, 'configure', '--workspace', str(root))
            step['configure'] = {'exit': plain.returncode, 'stderr': plain.stderr.strip()}
            if plain.returncode:
                forced = bundle_command(bundle, 'configure', '--workspace', str(root), '--force')
                step['configure_force'] = {'exit': forced.returncode, 'stderr': forced.stderr.strip()}
            server = tomllib.loads((root / '.codex/config.toml').read_text())['mcp_servers']['elixir_neovim']
            step['server'] = [server['command'], *server['args']]
            then = time.monotonic()
            client = ConfiguredMCP(root, output, name, server)
            clients.append(client)
            step['connection_s'] = time.monotonic() - then
            waited = poll(lambda: ready(client), lambda v: v is True or isinstance(v, str),
                          300 if index == 0 else 90)
            step['ready'] = waited['samples'][-1]
            navigation = {}
            if waited['samples'][-1]['value'] is True:
                for operation in ('hover', 'definition', 'references'):
                    reply = client.call('lsp', operation=operation, uri=str(caller), line=line,
                                        character=column, timeoutMs=5000)
                    navigation[operation] = bool(reply['data'].get('items') or reply['data'].get('locations'))
            step['navigation'] = navigation
            step['cleanup'] = close(client)
            cleanup = step['cleanup']
            step['passed'] = all([
                step['doctor_exit'] == 0,
                server['args'][0] == str(bundle / 'bundle.py'),
                step['ready']['value'] is True,
                navigation == {'hover': True, 'definition': True, 'references': True},
                cleanup['exit'] == 0, cleanup['no_survivors'], cleanup['stderr'] == '',
                cleanup['registry_empty'], cleanup['socket_removed'],
            ])
            save(name, step)
        save('load_end', load())
        save('passed', all(results[name]['passed'] for name in ('new', 'saved', 'return')))
    finally:
        for client in clients:
            client.cleanup()


if __name__ == '__main__':
    main()
