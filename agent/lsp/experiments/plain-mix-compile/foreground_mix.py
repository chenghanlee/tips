#!/usr/bin/env python3
"""Foreground compiler feedback prototype. No server, worker queue, or automatic retry."""
import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


class Interrupted(Exception):
    pass


def write_json(path, data):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2) + '\n')
    temp.replace(path)


def process_table():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat='], text=True, timeout=2)
    return {int(pid): (int(parent), status) for pid, parent, status in
            (line.split() for line in output.splitlines())}


def discover(pid, owned):
    rows = process_table()
    found = {pid} | owned
    while True:
        expanded = found | {child for child, (parent, _) in rows.items() if parent in found}
        if expanded == found:
            return found
        found = expanded


def living(owned):
    rows = process_table()
    return {pid for pid in owned if pid in rows and not rows[pid][1].startswith('Z')}


def compile_project(command, workspace, env, timeout, log):
    # Fail before starting a compiler if owned-process cleanup is unavailable.
    process_table()
    start, proc, owned = time.monotonic(), None, set()
    reason = None
    try:
        with log.open('w') as output:
            proc = subprocess.Popen(command, cwd=workspace, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            owned.add(proc.pid)
            deadline = start + timeout
            while proc.poll() is None:
                owned = discover(proc.pid, owned)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    reason = f'compilation reached its {timeout:g}-second safety limit'
                    break
                try:
                    proc.wait(timeout=min(0.25, remaining))
                except subprocess.TimeoutExpired:
                    pass
    except Interrupted:
        reason = 'compiler feedback was interrupted'
    finally:
        # unbuffer can place its child in another process group. Reuse observed
        # descendant ownership rather than assuming killing the wrapper is enough.
        if proc is not None:
            owned = discover(proc.pid, owned)
            for sig in (signal.SIGTERM, signal.SIGKILL):
                remaining = living(owned)
                if not remaining:
                    break
                for pid in remaining:
                    try:
                        os.kill(pid, sig)
                    except ProcessLookupError:
                        pass
                if sig == signal.SIGTERM:
                    time.sleep(0.15)
            proc.wait(timeout=2)
            until = time.monotonic() + 1
            while living(owned) and time.monotonic() < until:
                time.sleep(0.02)
    survivors = sorted(living(owned)) if owned else []
    if survivors:
        reason = 'compiler cleanup could not confirm that all observed processes exited'
    return {'exit_code': proc.returncode if proc else None, 'reason': reason,
            'survivors': survivors, 'compile_seconds': time.monotonic() - start}


def snapshot(workspace, state):
    start = time.monotonic()
    result = subprocess.run(['git', '-C', str(workspace), 'ls-files', '-z',
        '--cached', '--others', '--exclude-standard'], capture_output=True, check=True, timeout=5)
    files = {}
    for raw in set(result.stdout.split(b'\0')) - {b''}:
        relative = os.fsdecode(raw)
        path = workspace / relative
        if path.is_relative_to(state):
            continue
        if time.monotonic() - start > 5:
            raise TimeoutError('source observation exceeded five seconds')
        try:
            data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
        except FileNotFoundError:
            continue
        files[relative] = hashlib.sha256(data).hexdigest()
    return files


def changed(before, after):
    return {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}


def configure(args):
    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4'}
    signature = {'workspace': str(args.workspace), 'toolchain': str(args.toolchain),
                 'build_environment': {key: env.get(key) for key in
                    ('MIX_BUILD_PATH', 'MIX_BUILD_ROOT', 'MIX_TARGET')}}
    manifest = json.loads((args.toolchain / 'foreground-mix-manifest.json').read_text())
    for name, digest in manifest['files'].items():
        if hashlib.sha256((args.toolchain / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('Private Mix integrity mismatch: ' + name)
    signature['manifest'] = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    env['PATH'] = str(args.toolchain / 'bin') + os.pathsep + env['PATH']
    return env, signature


def perform(args, event):
    started = time.monotonic()
    env, identity = configure(args)
    state_file = args.state / 'state.json'
    previous = json.loads(state_file.read_text()) if state_file.exists() else None
    if args.mode != 'prepare' and (previous is None or previous.get('identity') != identity):
        return {'status': 'unfinished', 'message': 'Validation unfinished: run foreground_mix.py prepare for this workspace and toolchain first.'}
    before = snapshot(args.workspace, args.state)
    previous = previous if previous and previous.get('identity') == identity else {}
    delta = changed(previous.get('files', {}), before)
    pending = set(previous.get('pending', [])) | delta
    if args.mode == 'hook' and event.get('hook_event_name') == 'Stop':
        if delta:
            return {'status': 'unfinished', 'message': 'Validation unfinished: files changed since the last compiler check. Run foreground_mix.py check.'}
        if previous.get('status') != 'passed':
            return previous.get('result', {'status': 'unfinished', 'message': 'Validation unfinished: the previous compiler check did not complete. Run foreground_mix.py check.'})
        return None
    if args.mode == 'hook' and not delta:
        # A failed/timed-out generation stays pending, but unrelated reads do not
        # restart it. An explicit check or another edit is required to try again.
        return None
    timeout = args.timeout or (180 if args.mode == 'prepare' else 60)
    command = ['unbuffer', 'mix', 'compile', '--warnings-as-errors']
    for path in sorted(pending):
        command += ['--force-path', str(args.workspace / path)]
    data = {'identity': identity, 'files': before, 'pending': sorted(pending), 'status': 'running'}
    write_json(state_file, data)
    result = compile_project(command, args.workspace, env, timeout, args.state / 'compile.log')
    after = snapshot(args.workspace, args.state)
    during = changed(before, after)
    pending |= during
    if result['reason']:
        status, message = 'unfinished', 'Validation unfinished: ' + result['reason'] + '. Run foreground_mix.py check to retry; no background compilation is scheduled.'
    elif during:
        status, message = 'unfinished', 'Validation unfinished: files changed during compilation. Results may describe earlier contents; run foreground_mix.py check.'
    elif result['exit_code']:
        status, message = 'failed', 'Mix compilation failed.'
    else:
        status, message = 'passed', 'Mix compilation passed; no input change was observed during the check. Tests were not run.'
        pending.clear()
    output = (args.state / 'compile.log').read_text(errors='replace')
    output = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output).strip()
    if output:
        excerpt = output if len(output) <= 10000 else output[:4500] + '\n[output shortened]\n' + output[-4500:]
        message += '\n' + excerpt
    message += '\nCompiler log: ' + str(args.state / 'compile.log')
    result.update({'status': status, 'message': message, 'changed': sorted(delta),
                   'changed_during_compile': sorted(during), 'targeted': bool(args.toolchain),
                   'timeout_seconds': timeout, 'command': command,
                   'total_seconds': time.monotonic() - started})
    data.update({'files': after, 'pending': sorted(pending), 'status': status, 'result': result})
    write_json(state_file, data)
    write_json(args.state / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'check', 'hook'])
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--toolchain', type=Path, required=True)
    parser.add_argument('--timeout', type=float)
    args = parser.parse_args()
    args.workspace, args.state = args.workspace.resolve(), args.state.resolve()
    args.toolchain = args.toolchain.resolve()
    if args.timeout is not None and (not math.isfinite(args.timeout) or args.timeout <= 0):
        parser.error('timeout must be finite and positive')
    event, result = {}, None
    started = time.monotonic()

    def interrupted(_signum, _frame):
        raise Interrupted()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if args.mode == 'hook':
            event = json.load(sys.stdin)
            if event.get('hook_event_name') not in ('PostToolUse', 'Stop'):
                raise ValueError('Unsupported hook event')
            if Path(event.get('cwd', args.workspace)).resolve() != args.workspace:
                raise ValueError('Hook workspace differs from assigned workspace')
        if args.workspace.is_relative_to(args.state) or not (args.workspace / 'mix.exs').is_file():
            raise ValueError('Use a Mix project and a separate private state directory')
        args.state.mkdir(parents=True, exist_ok=True)
        with (args.state / 'lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = perform(args, event)
    except BlockingIOError:
        result = {'status': 'unfinished', 'message': 'Validation unfinished: another foreground check is active.'}
    except Exception as error:
        result = {'status': 'unfinished', 'message': f'Validation unfinished: {error or type(error).__name__}. No successful compiler result was established.'}
    if args.mode == 'hook':
        output = {}
        if result and event.get('hook_event_name') == 'Stop':
            if not event.get('stop_hook_active'):
                output = {'decision': 'block', 'reason': result['message']}
        elif result:
            output = {'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': result['message']}}
    else:
        output = result or {'status': 'unchanged'}
    if result:
        result['total_seconds'] = time.monotonic() - started
    print(json.dumps(output))
    if args.mode != 'hook' and result and result['status'] != 'passed':
        sys.exit(1 if result['status'] == 'failed' else 2)


if __name__ == '__main__':
    main()
