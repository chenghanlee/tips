#!/usr/bin/env python3
"""Acceptance tests for normal disk writes and shared Codex/Claude hook feedback."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from neovim_probe import NvimMCP, poll
from inversion_probe import target_text
from probe import alive, prepare, process_table


def main():
    # These checks read the opt-in LSP trace; the launched Neovim inherits it.
    os.environ['TIPS_LSP_TRACE'] = '1'
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    sys.path.insert(0, str(vendor / 'python'))
    process_table()
    output.mkdir(parents=True)
    results, clients = {}, []

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:300], flush=True)

    def hook(client, tool='apply_patch', event='PostToolUse', budget=5000):
        start = time.monotonic()
        proc = subprocess.run([
            sys.executable, str(Path(__file__).with_name('neovim_hook.py')),
            '--vendor', str(vendor), '--registry', str(client.registry),
            '--workspace', str(client.root), '--budget-ms', str(budget),
        ], input=json.dumps({'hook_event_name': event, 'tool_name': tool,
                             'cwd': str(client.root), 'tool_input': {}}),
            text=True, capture_output=True, timeout=7)
        assert proc.returncode == 0, proc.stderr
        return {'seconds': round(time.monotonic()-start, 3), 'output': json.loads(proc.stdout)}

    try:
        alpha, beta, _, _ = prepare(output)
        for root in (alpha, beta):
            c = NvimMCP(vendor, root, output, root.name, sync_reads=True, feedback=True, automatic=True)
            clients.append(c)
            assert poll(lambda: c.nav('hover'), lambda v: root.name.upper() in json.dumps(v), 30)['matched']
            hook(c, budget=2000)
        a, b = clients
        caller, target = alpha / 'lib/caller.ex', alpha / 'lib/target.ex'
        original, original_target = caller.read_text(), target.read_text()
        caller.write_text(original.replace('V2Target.answer()', 'missing_local()', 1))
        # Observe only the buffer: no LSP query or hook is allowed to refresh it.
        automatic = poll(lambda: a.state()['buffers'], lambda v: 'missing_local()' in json.dumps(v), 4)
        save('automatic_buffer_refresh_without_query', automatic)
        assert automatic['matched']
        value = hook(a)
        save('codex_error', value)
        assert 'missing_local/0' in json.dumps(value)
        save('unchanged_error', hook(a))
        assert results['unchanged_error']['output'] == {}
        save('beta_unaffected', hook(b))
        assert results['beta_unaffected']['output'] == {}

        replacement = caller.with_suffix('.replacement')
        replacement.write_text(original)
        replacement.replace(caller)
        save('claude_atomic_repair', hook(a, 'Edit'))
        assert 'cleared' in json.dumps(results['claude_atomic_repair'])
        caller.write_text(original.replace('V2Target.answer()', 'missing_local()', 1))
        save('claude_failed_shell', hook(a, 'Bash', 'PostToolUseFailure'))
        assert 'missing_local/0' in json.dumps(results['claude_failed_shell'])
        assert results['claude_failed_shell']['output']['hookSpecificOutput']['hookEventName'] == 'PostToolUseFailure'
        caller.write_text(original)
        assert 'cleared' in json.dumps(hook(a, 'Bash'))

        mark = len(a.events())
        target.write_text(target_text('HOOK_SLOW', delay=3000))
        save('slow_pending', hook(a, 'Bash', budget=500))
        assert 'pending' in json.dumps(results['slow_pending']).lower()
        assert results['slow_pending']['seconds'] < 1.5
        done = poll(lambda: hook(a, 'Bash'), lambda v: 'Compilation completed' in json.dumps(v), 8)
        save('slow_later_feedback', done)
        assert done['matched']

        # Overlap no longer latches a session-wide restriction. These observations
        # deliberately make no claim about the bytes consumed by Mix.
        target.write_text(target_text('HOOK_OVERLAP_A', delay=1500))
        assert poll(lambda: a.events()[mark:], lambda v: 'INVERSION_HOOK_OVERLAP_A_STARTED' in json.dumps(v), 5)['matched']
        target.write_text(target_text('HOOK_OVERLAP_B', delay=1500))
        save('overlap_feedback', hook(a, 'Bash', budget=2000))
        assert 'uncertain' not in json.dumps(results['overlap_feedback']).lower()
        target.write_text(original_target)
        save('overlap_repair', hook(a, 'Bash', budget=2000))
        assert poll(lambda: a.rpc().exec_lua("return require('neovim_sync').ready()"), bool, 10)['matched']
        save('events', a.events())
        for c in clients:
            c.remember()
            c.proc.stdin.close()
            c.proc.wait(timeout=8)
            save(c.name+'_cleanup', poll(lambda: alive(c.owned), lambda v: not v, 6))
            assert results[c.name+'_cleanup']['matched']
        save('completed', True)
    finally:
        for c in clients:
            c.cleanup()


if __name__ == '__main__':
    main()
