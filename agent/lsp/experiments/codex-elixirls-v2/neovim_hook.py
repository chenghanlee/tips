#!/usr/bin/env python3
"""Bounded synchronous compiler feedback; Stop rechecks an edit left pending."""
import argparse
import json
from pathlib import Path
import signal
import sys
import time
import uuid

ENTERED = time.monotonic()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--registry', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--budget-ms', type=int, default=5000)
    parser.add_argument('--audit', type=Path)
    args = parser.parse_args()
    if not 1 <= args.budget_ms <= 5000:
        parser.error('--budget-ms must be between 1 and 5000')
    event = json.load(sys.stdin)
    name = event.get('hook_event_name')
    if name not in {'PostToolUse', 'PostToolUseFailure', 'Stop'}:
        print('{}')
        return
    root = args.workspace.resolve()
    sys.path.insert(0, str(args.vendor.resolve() / 'python'))
    start, client = ENTERED, None
    deadline = start + args.budget_ms / 1000
    phases = {}
    result, rpc_failed = {}, False
    try:
        # The budget includes imports, connection and RPC, not just compiler wait.
        def timeout(*_):
            raise TimeoutError('hook deadline reached while waiting for feedback')
        signal.signal(signal.SIGALRM, timeout)
        # Leave a small output allowance even when Neovim never answers.
        signal.setitimer(signal.ITIMER_REAL, max(0.001, deadline - time.monotonic() - 0.1))
        import pynvim
        owner = json.loads((args.registry.parent / 'owner.json').read_text())
        entries = [json.loads(p.read_text()) for p in args.registry.glob('*.json')]
        entries = [e for e in entries if any(Path(r).resolve() == root for r in e.get('roots', []))
                   or Path(e['cwd']).resolve() == root]
        if len(entries) != 1:
            raise RuntimeError(f'Expected one Neovim for the assigned workspace; found {len(entries)}')
        entry = entries[0]
        if entry.get('kind') != 'interactive' or any(
                entry.get(key) != owner.get(key) for key in ('instanceId', 'pid', 'socket')):
            raise RuntimeError('Neovim instance differs from the session owner; restart the session')
        client = pynvim.attach('socket', path=entry['socket'])
        phases['attached_ms'] = round((time.monotonic() - start) * 1000, 3)
        # Budget covers scan + wait, with 300 ms for RPC, teardown and output.
        # Unix expiry also rejects a request queued behind another RPC. Lua uses
        # its own monotonic elapsed time; no shared monotonic epoch is assumed.
        remaining_ms = max(0, int((deadline - time.monotonic()) * 1000) - 300)
        expires_at = time.time() + remaining_ms / 1000
        result = client.exec_lua("return require('neovim_sync').collect(...)", remaining_ms, name, expires_at)
        phases['rpc_return_ms'] = round((time.monotonic() - start) * 1000, 3)
        if result['status'] == 'expired':
            raise TimeoutError('hook deadline reached before feedback could be collected')
        message = result['message']
    except Exception as error:
        rpc_failed = True
        message = f'ElixirLS feedback unavailable: {error}. This does not mean the source is error-free.'
        result = {'status': 'unavailable', 'message': message}
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
        signal.setitimer(signal.ITIMER_REAL, 0)
        phases['closed_ms'] = round((time.monotonic() - start) * 1000, 3)
    if args.audit and message:
        # Test-only unpredictable marker proves the model actually received hook output.
        message += '\nFeedback receipt: ' + uuid.uuid4().hex[:12]
    if name == 'Stop':
        # If Neovim is gone it cannot remember that Stop already reported failure.
        repeat_failure = rpc_failed and event.get('stop_hook_active', False)
        output = {'decision': 'block', 'reason': message} if message and not repeat_failure else {}
    else:
        output = {'hookSpecificOutput': {'hookEventName': name, 'additionalContext': message}} if message else {}
    if args.audit:
        with args.audit.open('a') as file:
            file.write(json.dumps({'event': name, 'tool': event.get('tool_name'), 'result': result,
                                   'output': output, 'phases': phases,
                                   'seconds': round(time.monotonic()-start, 3)}) + '\n')
    print(json.dumps(output))


if __name__ == '__main__':
    main()
