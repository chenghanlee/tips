#!/usr/bin/env python3
"""Actual Codex normal edits + automatic hook feedback, synthetic source only."""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

from neovim_probe import nvim_environment
from probe import alive, descendants, prepare, process_table


def toml(value):
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k)+'='+toml(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '[' + ','.join(toml(v) for v in value) + ']'
    return json.dumps(value)


def validate_feedback(output, root, original, slow=False):
    events = [json.loads(line) for line in (output / 'events.jsonl').read_text().splitlines()]
    items = [event['item'] for event in events if event['type'] == 'item.completed']
    changes = [item for item in items if item['type'] == 'file_change']
    assert len(changes) == 2 and all(item['status'] == 'completed' for item in changes)
    assert all(item['changes'] == [{'path': str(root / 'lib/caller.ex'), 'kind': 'update'}]
               for item in changes)
    assert all(item['type'] in {'agent_message', 'file_change', 'error'} for item in items), items
    all_audit = [json.loads(line) for line in (output / 'hook-audit.jsonl').read_text().splitlines()]
    audit = [entry for entry in all_audit if entry['event'] != 'Stop']
    stops = [entry for entry in all_audit if entry['event'] == 'Stop' and entry['output']]
    assert [entry['result']['status'] for entry in audit] == ['pending' if slow else 'diagnostics', 'cleared']
    assert len(stops) == (1 if slow else 0)
    assert all(entry['tool'] == 'apply_patch' for entry in audit)
    receipts = [entry['output']['hookSpecificOutput']['additionalContext'].split('Feedback receipt: ')[1]
                for entry in audit]
    first, second = (items.index(item) for item in changes)
    assert any(receipts[0] in item.get('text', '') for item in items[first + 1:second])
    assert any(receipts[1] in item.get('text', '') for item in items[second + 1:])
    assert (root / 'lib/caller.ex').read_text() == original
    result = {'normal_edits_only': True, 'error_receipt_before_repair': receipts[0],
              'repair_receipt_after_repair': receipts[1], 'source_restored': True,
              'hook_seconds': [entry['seconds'] for entry in audit]}
    if slow:
        assert stops[0]['result']['status'] == 'diagnostics' and stops[0]['output']['decision'] == 'block'
        receipt = stops[0]['output']['reason'].split('Feedback receipt: ')[1]
        assert any(receipt in item.get('text', '') for item in items[first + 1:second])
        assert 4.6 < audit[0]['seconds'] < 5.3
        result['pending_receipt_before_stop'] = result.pop('error_receipt_before_repair')
        result['stop_error_receipt_before_repair'] = receipt
        result['stop_seconds'] = stops[0]['seconds']
    (output / 'feedback-results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--slow-final-edit', action='store_true')
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    process_table()
    output.mkdir(parents=True)
    root, _, _, _ = prepare(output)
    original = (root / 'lib/caller.ex').read_text()
    env = nvim_environment(vendor, output, 'codex', sync_reads=True, feedback=True, automatic=True)
    environment = output / 'environment.json'
    environment.write_text(json.dumps(env, indent=2) + '\n')
    here = Path(__file__).parent.resolve()
    hook = shlex.join([sys.executable, str(here / 'neovim_hook.py'), '--vendor', str(vendor),
                      '--workspace', str(root), '--registry', env['VV_MCP_REGISTRY'],
                      '--audit', str(output / 'hook-audit.jsonl')])
    config = {
        'mcp_servers.elixir_neovim.command': sys.executable,
        'mcp_servers.elixir_neovim.args': [str(here / 'neovim_launcher.py'), '--vendor', str(vendor),
                                        '--workspace', str(root), '--environment', str(environment)],
        'mcp_servers.elixir_neovim.cwd': str(root),
        'mcp_servers.elixir_neovim.enabled_tools': ['lsp'],
        'mcp_servers.elixir_neovim.required': True,
        'mcp_servers.elixir_neovim.startup_timeout_sec': 60,
        'hooks.PostToolUse': [{'matcher': '^(apply_patch|Bash)$', 'hooks': [
            {'type': 'command', 'command': hook, 'timeout': 6, 'statusMessage': 'Reading ElixirLS compiler feedback'}]}],
        'hooks.Stop': [{'hooks': [
            {'type': 'command', 'command': hook, 'timeout': 6, 'statusMessage': 'Checking pending ElixirLS feedback'}]}],
    }
    prompt = '''This is a controlled integration test on generated synthetic code.
Use only your normal apply_patch writing tool. Do not run shell commands, MCP tools,
read other projects, inspect hook files/logs, or delegate.
The file lib/caller.ex contains:
defmodule V2Caller do
  def call_1, do: V2Target.answer()
  def call_2, do: V2Target.answer()
end
First use apply_patch to replace only call_1's V2Target.answer() with missing_local().
If automatic compiler feedback arrives, quote that feedback INCLUDING any receipt
identifier in a commentary message before doing anything else. If none arrives, say so.
Then use apply_patch to restore exactly the original call_1.
Report any automatic repair feedback and its receipt identifier in your final answer.
Do not fabricate feedback or receipts. Do not request diagnostics yourself.
'''
    if args.slow_final_edit:
        prompt = '''This is a controlled integration test on generated synthetic code.
Use only your normal apply_patch writing tool. Do not run shell commands, MCP tools,
read other projects, inspect hook files/logs, or delegate.
The file lib/caller.ex contains:
defmodule V2Caller do
  def call_1, do: V2Target.answer()
  def call_2, do: V2Target.answer()
end
First use one apply_patch to insert `  Process.sleep(8000)` immediately after the
defmodule line and replace only call_1's V2Target.answer() with missing_local().
Quote the automatic pending feedback INCLUDING its receipt, then finish your
response without any more tools. Do not repair yet: this tests the final-edit gap.
If a subsequent automatic Stop continuation supplies compiler diagnostics, quote
those diagnostics INCLUDING their receipt before doing anything else. Then use
one apply_patch to restore the file exactly: remove Process.sleep and restore call_1.
Report the automatic repair feedback and receipt in your final response.
Do not fabricate feedback or receipts. Do not request diagnostics yourself.
'''
    command = ['codex', 'exec', '--ignore-user-config', '--ephemeral', '--json',
               '--dangerously-bypass-hook-trust', '-s', 'workspace-write', '-C', str(root)]
    for key, value in config.items():
        command.extend(['-c', key+'='+toml(value)])
    command.append(prompt)
    (output / 'command.json').write_text(json.dumps(command, indent=2)+'\n')
    owned = {}
    try:
        with (output / 'events.jsonl').open('w') as out, (output / 'stderr.log').open('w') as err:
            proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    start_new_session=True)
            deadline = time.monotonic() + 240
            while proc.poll() is None and time.monotonic() < deadline:
                owned.update(descendants(proc.pid))
                time.sleep(0.3)
            if proc.poll() is None:
                raise TimeoutError('Actual Codex hook test')
        deadline = time.monotonic() + 8
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.2)
        result = {'exit_code': proc.returncode, 'owned': owned, 'remaining': alive(owned)}
        (output / 'process-results.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps({'exit_code': proc.returncode, 'remaining': list(result['remaining'])}), flush=True)
        assert proc.returncode == 0 and not result['remaining'], 'Codex or lifecycle acceptance failed'
        print(json.dumps(validate_feedback(output, root, original, args.slow_final_edit)), flush=True)
    finally:
        for pid in alive(owned):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.2)
        for pid in alive(owned):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


if __name__ == '__main__':
    main()
