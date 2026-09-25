#!/usr/bin/env python3
"""Installed beta: an ElixirLS crash must not leave compiler port programs running.

A compile waits on two port programs in their own process groups: one ignores
SIGTERM, one writes into .elixir_ls/ later. The BEAM is then killed, which orphans
them (parent PID 1). The session must stop them before it releases the worktree
lock, and a relaunch must not see a late write.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import prepare, process_table


def table():
    rows = {}
    out = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat=,command='], text=True)
    for line in out.splitlines():
        pid, ppid, pgid, stat, command = line.strip().split(None, 4)
        rows[int(pid)] = {'ppid': int(ppid), 'pgid': int(pgid), 'stat': stat, 'command': command}
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sleep', type=int, default=30)
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    process_table()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    root, _, _, _ = prepare(output)
    marker = f'v2-crash-orphan-{os.getpid()}'
    late = root / '.elixir_ls' / 'late-write.txt'
    results, clients = {}, []

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:600], flush=True)

    def spawned():
        return {pid: row for pid, row in table().items()
                if marker in row['command'] and not row['stat'].startswith('Z')}

    def lock_free():
        proc = subprocess.run([sys.executable, str(bundle / 'bundle.py'), 'prepare', '--workspace', str(root),
                               '--state', str(output / 'lock-probe-state')], capture_output=True, text=True, timeout=20)
        return proc.returncode == 0

    def hook(client, event='PostToolUse'):
        return subprocess.run([sys.executable, str(bundle / 'bundle.py'), 'hook', '--workspace', str(client.root),
                               '--state', str(client.state_dir)], input=json.dumps(
                                   {'hook_event_name': event, 'tool_name': 'Bash'}),
                              text=True, capture_output=True, timeout=8).stdout

    try:
        first = BundleMCP(bundle, root, output, 'first')
        clients.append(first)
        save('first_ready', poll(lambda: first.rpc().exec_lua(
            "return require('neovim_sync').ready()"), bool, 60)['matched'])
        (root / 'lib/slow.ex').write_text(
            'defmodule V2Slow do\n'
            f'  {{_, 0}} = System.cmd("sh", ["-c", "trap \'\' TERM; exec -a {marker} sleep {args.sleep}"])\n'
            '  def ok, do: :ok\n'
            'end\n')
        (root / 'lib/late.ex').write_text(
            'defmodule V2Late do\n'
            f'  Port.open({{:spawn_executable, "/bin/sh"}}, [:nouse_stdio, args: ["-c", '
            f'"trap \'\' TERM; sleep {args.sleep // 2}; echo {marker} > {late}"]])\n'
            '  def ok, do: :ok\n'
            'end\n')
        hook(first)
        save('ports_seen', poll(lambda: len(spawned()) >= 2 or None, bool, 30)['matched'])
        time.sleep(0.6)  # More than two samples of the editor's group record.
        first.remember()
        beam = next(pid for pid, row in first.owned.items() if 'ElixirLS.LanguageServer.main()' in row['command'])
        ports = spawned()
        save('ports_before_crash', {pid: {k: row[k] for k in ('ppid', 'pgid')} for pid, row in ports.items()})
        crashed = time.monotonic()
        os.kill(beam, signal.SIGKILL)
        orphaned = poll(lambda: all(row['ppid'] == 1 for row in spawned().values()) or None, bool, 3)
        save('ports_orphaned_by_crash', orphaned['matched'])
        # A dead server must say so and ask for a restart, never promise a retry.
        after_crash = hook(first)
        save('hook_after_crash', {'s': round(time.monotonic() - crashed, 3), 'output': after_crash})
        guidance = 'Retry in about' not in after_crash and 'reconnect' in after_crash.lower()
        # Sample until the lock is accepted; record which port programs are alive then.
        samples, accepted = [], None
        while time.monotonic() - crashed < 12 and accepted is None:
            ok = lock_free()
            now = round(time.monotonic() - crashed, 3)
            living = spawned()
            samples.append({'s': now, 'lock_accepted': ok, 'ports_alive_after_attempt': len(living)})
            if ok:
                accepted = {'s': now, 'ports_alive_after_accept': sorted(living)}
            time.sleep(0.1)
        save('teardown', {'samples': samples, 'first_accept': accepted})
        first.proc.wait(timeout=10)
        save('launcher_exit', {'code': first.proc.returncode, 'stderr': Path(first.log.name).read_text()[-800:]})
        save('editor_log', (first.state_dir / 'environment.nvim.log').read_text()[-800:]
             if (first.state_dir / 'environment.nvim.log').exists() else None)
        (root / 'lib/slow.ex').unlink()
        (root / 'lib/late.ex').unlink()
        second = BundleMCP(bundle, root, output, 'second')
        clients.append(second)
        save('relaunch_ready', poll(lambda: second.rpc().exec_lua(
            "return require('neovim_sync').ready()"), bool, 60)['matched'])
        save('late_write', poll(lambda: late.exists(), bool, args.sleep // 2 + 3)['matched'])
        second.remember()
        second.proc.stdin.close()
        second.proc.wait(timeout=15)
        passed = (orphaned['matched'] and guidance and accepted is not None and not accepted['ports_alive_after_accept']
                  and not results['late_write'] and results['relaunch_ready'])
        save('passed', passed)
    finally:
        for client in clients:
            client.cleanup()
        leftovers = spawned()
        for pid in leftovers:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        results['probe_killed_leftovers'] = sorted(leftovers)
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    sys.exit(0 if results.get('passed') else 1)


if __name__ == '__main__':
    main()
