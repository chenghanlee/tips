#!/usr/bin/env python3
"""Two actual Sol sessions: late errors through ordinary hooks and Stop, without polling."""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

from neovim_hook_codex_probe import toml
from probe import alive, descendants, prepare


def run(bundle, output, delivery):
    output.mkdir(parents=True, exist_ok=False)
    root, _, _, _ = prepare(output)
    original = (root / 'lib/caller.ex').read_text()
    state = output / 'session'
    hook = shlex.join([sys.executable, str(bundle / 'bundle.py'), 'hook',
        '--workspace', str(root), '--state', str(state), '--budget-ms', '5000',
        '--audit', str(output / 'hook-audit.jsonl')])
    config = {
        'mcp_servers.elixir_neovim.command': sys.executable,
        'mcp_servers.elixir_neovim.args': [str(bundle / 'bundle.py'), 'serve',
            '--workspace', str(root), '--state', str(state)],
        'mcp_servers.elixir_neovim.cwd': str(root),
        'mcp_servers.elixir_neovim.enabled_tools': ['lsp'],
        'mcp_servers.elixir_neovim.required': True,
        # Deliberately use Codex's normal startup timeout.
        'hooks.PostToolUse': [{'matcher': '^(apply_patch|Bash)$', 'hooks': [
            {'type': 'command', 'command': hook, 'timeout': 6}]}],
        'hooks.Stop': [{'hooks': [{'type': 'command', 'command': hook, 'timeout': 6}]}],
    }
    following = ('After quoting pending feedback, finish your response with a brief pending status.'
                 if delivery == 'stop' else
                 'After quoting pending feedback, run exactly one Bash command: '
                 '`sleep 5`. This represents other work during compilation; it does not '
                 'query diagnostics. Then respond to any automatic feedback.')
    prompt = f'''Controlled feedback test on generated synthetic Elixir code. Use normal
apply_patch edits. Do not call MCP tools or read hook files, audit logs or other projects.
The only permitted shell command is the single sleep below, if specified.
lib/caller.ex currently contains:
{original}
In one apply_patch, insert `  Process.sleep(8000)` immediately after the defmodule
line and replace only call_1's V2Target.answer() with missing_late_feedback().
Quote automatic feedback and its unpredictable receipt identifier when you receive it.
{following}
When automatic compiler feedback reports the actual undefined-function error,
quote that error and receipt BEFORE using apply_patch to restore the file exactly.
Do not repair merely because you know an error was injected. Report automatic repair
feedback and its receipt. If no compiler error arrives, report that honestly and leave
the controlled fixture for the test harness. Never fabricate feedback or receipts.
'''
    (output / 'prompt.md').write_text(prompt)
    command = ['codex', 'exec', '--ignore-user-config', '--ephemeral', '--json',
        '--dangerously-bypass-hook-trust', '--approve-for-me', '-m', 'gpt-6-sol',
        '-C', str(root), '-o', str(output / 'final.md')]
    for key, value in config.items():
        command += ['-c', key + '=' + toml(value)]
    command.append('-')
    (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    owned, proc = {}, None
    try:
        with (output / 'events.jsonl').open('w') as stdout, (output / 'stderr.log').open('w') as stderr:
            proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
                env=os.environ | {'ERL_FLAGS': '+S 4:4'}, text=True, start_new_session=True)
            proc.stdin.write(prompt)
            proc.stdin.close()
            deadline = time.monotonic() + 300
            while proc.poll() is None and time.monotonic() < deadline:
                owned.update(descendants(proc.pid))
                time.sleep(0.4)
            if proc.poll() is None:
                raise TimeoutError('Late-feedback Codex session exceeded five minutes')
        deadline = time.monotonic() + 6
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.2)
        events = [json.loads(line) for line in (output / 'events.jsonl').read_text().splitlines()]
        items = [e['item'] for e in events if e['type'] == 'item.completed']
        audit = [json.loads(line) for line in (output / 'hook-audit.jsonl').read_text().splitlines()]
        edits = [i for i in items if i['type'] == 'file_change']
        errors = [a for a in audit if a['result']['status'] == 'diagnostics']
        assert proc.returncode == 0 and not alive(owned)
        assert len(edits) == 2, items
        assert not any(i['type'] == 'mcp_tool_call' for i in items), items
        assert audit[0]['result']['status'] == 'pending', audit
        assert errors and 'missing_late_feedback/0' in json.dumps(errors[0]), audit
        error = errors[0]
        assert error['event'] == ('Stop' if delivery == 'stop' else 'PostToolUse'), error
        if delivery == 'tool':
            assert error['tool'] == 'Bash', error
        error_text = (error['output']['reason'] if delivery == 'stop' else
                      error['output']['hookSpecificOutput']['additionalContext'])
        receipt = error_text.split('Feedback receipt: ')[1]
        first, second = (items.index(e) for e in edits)
        assert any(receipt in i.get('text', '') for i in items[first + 1:second]), items
        assert (root / 'lib/caller.ex').read_text() == original
        assert any(a['result']['status'] == 'cleared' for a in audit), audit
        assert max(a['seconds'] for a in audit) < 5.1, audit
        result = {'delivery': delivery, 'error_receipt_before_repair': receipt,
            'source_restored': True, 'no_diagnostic_requests': True,
            'hook_seconds': [a['seconds'] for a in audit], 'remaining': alive(owned)}
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        return result
    finally:
        if proc and proc.poll() is None:
            owned.update(descendants(proc.pid))
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid in alive(owned):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
            if sig == signal.SIGTERM:
                deadline = time.monotonic() + 3
                while alive(owned) and time.monotonic() < deadline:
                    time.sleep(0.2)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    for delivery in ('stop', 'tool'):
        run(args.bundle.resolve(), args.output.resolve() / delivery, delivery)


if __name__ == '__main__':
    main()
