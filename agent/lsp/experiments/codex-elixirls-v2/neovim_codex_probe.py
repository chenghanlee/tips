#!/usr/bin/env python3
"""Actual Codex -> vv-mcp -> headless Neovim -> ElixirLS, synthetic source only."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from neovim_probe import nvim_environment
from probe import alive, descendants, prepare, process_table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    process_table()
    output.mkdir(parents=True)
    root, _, _, _ = prepare(output)
    env = nvim_environment(vendor, output, 'codex', sync_reads=True)
    source = root / 'lib/caller.ex'
    prompt = f'''This is a read-only MCP integration test on generated synthetic code.
Use only the elixir_neovim MCP tools. Do not use shell commands, edit files,
access other projects or services, or delegate.
Call the lsp tool with operations hover, definition, references (includeDeclaration=false),
and diagnostics on {source}, line 2, character 29, timeoutMs 10000.
Then call list_instances. If a navigation result is empty, retry it at most twice.
Report the actual documentation, definition path, reference count, diagnostics,
and workspace root. Do not infer that empty diagnostics prove compilation finished.
'''
    config = {
        'mcp_servers.elixir_neovim.command': str(vendor / 'vv-mcp'),
        'mcp_servers.elixir_neovim.cwd': str(root),
        'mcp_servers.elixir_neovim.enabled_tools': ['lsp', 'list_instances'],
        'mcp_servers.elixir_neovim.startup_timeout_sec': 60,
        'mcp_servers.elixir_neovim.tool_timeout_sec': 120,
        'mcp_servers.elixir_neovim.required': True,
        'mcp_servers.elixir_neovim.default_tools_approval_mode': 'approve',
    }
    for key, value in env.items():
        config[f'mcp_servers.elixir_neovim.env.{key}'] = value
    command = ['codex', 'exec', '--ignore-user-config', '--ephemeral', '--json',
               '-s', 'read-only', '-C', str(root)]
    for key, value in config.items():
        command.extend(['-c', f'{key}={json.dumps(value)}'])
    command.append(prompt)
    (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    (output / 'prompt.txt').write_text(prompt)
    owned = {}
    proc = None
    try:
        with (output / 'events.jsonl').open('w') as stdout, (output / 'stderr.log').open('w') as stderr:
            proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout,
                                    stderr=stderr, start_new_session=True)
            deadline = time.monotonic() + 240
            while proc.poll() is None and time.monotonic() < deadline:
                owned.update(descendants(proc.pid))
                time.sleep(0.5)
            if proc.poll() is None:
                raise TimeoutError('Codex smoke test')
        deadline = time.monotonic() + 8
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.2)
        result = {'exit_code': proc.returncode, 'owned': owned, 'remaining': alive(owned)}
        (output / 'process-results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'exit_code': proc.returncode, 'remaining': list(result['remaining'])}), flush=True)
    finally:
        for pid in alive(owned):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


if __name__ == '__main__':
    main()
