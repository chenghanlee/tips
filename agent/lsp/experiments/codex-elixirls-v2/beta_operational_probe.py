#!/usr/bin/env python3
"""Installed beta ownership, crash/reconnect and quiet-runtime acceptance."""
import argparse
import hashlib
import json
import os
import queue
from pathlib import Path
import signal
import subprocess
import sys
import time

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import alive, prepare, process_table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ownership-only', action='store_true')
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    process_table()  # Do not start children if host process observation is unavailable.
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    alpha, beta, _, _ = prepare(output)
    results, clients = {}, []

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:800], flush=True)

    def start(root, name):
        client = BundleMCP(bundle, root, output, name)
        clients.append(client)
        assert poll(lambda: client.rpc().exec_lua("return require('neovim_sync').ready()"), bool, 20)['matched']
        return client

    def attempt(root, state, mode='serve'):
        before = time.monotonic()
        proc = subprocess.run([sys.executable, str(bundle / 'bundle.py'), mode,
            '--workspace', str(root), '--state', str(state)], input='', text=True,
            capture_output=True, timeout=8)
        return {'exit': proc.returncode, 'seconds': time.monotonic() - before,
                'stderr': proc.stderr[-2000:]}

    def hook(client, event='PostToolUse'):
        before = time.monotonic()
        proc = subprocess.run([sys.executable, str(bundle / 'bundle.py'), 'hook',
            '--workspace', str(client.root), '--state', str(client.state_dir)],
            input=json.dumps({'hook_event_name': event, 'tool_name': 'Bash'}),
            text=True, capture_output=True, timeout=6)
        assert proc.returncode == 0, proc.stderr
        return {'seconds': time.monotonic() - before, 'output': json.loads(proc.stdout)}

    def close(client, expected_exit=0, removed_state=True):
        client.remember()
        if client.proc.poll() is None:
            client.proc.stdin.close()
            client.proc.wait(timeout=6)
        observed = poll(lambda: alive(client.owned), lambda value: not value, 5)
        assert observed['matched'], observed
        assert client.proc.returncode == expected_exit, (client.proc.returncode, Path(client.log.name).read_text())
        stderr = Path(client.log.name).read_text()
        if expected_exit == 0:
            assert not stderr, stderr
        else:
            assert 'Operation not permitted' not in stderr, stderr
        if removed_state:
            assert not (client.state_dir / 'owner.json').exists()
            assert not Path(client.instance['socket']).exists()
        observed.update(exit=client.proc.returncode, stderr=stderr, removed_state=removed_state)
        return observed

    try:
        first = start(alpha, 'first')
        protected = [first.state_dir / name for name in ('environment.json', 'owner.json', 'config/nvim/init.lua')]
        hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
        alias = output / 'alpha-alias'
        alias.symlink_to(alpha, target_is_directory=True)
        for name, root, state, mode in (
            ('same_root', alpha, output / 'other-state', 'serve'),
            ('same_state', beta, first.state_dir, 'serve'),
            ('root_alias', alias, output / 'alias-state', 'serve'),
            ('prepare_live', alpha, first.state_dir, 'prepare'),
            ('configure_live', alpha, first.state_dir, 'configure'),
        ):
            result = attempt(root, state, mode)
            save(name, result)
            assert result['exit'] != 0 and 'owns' in result['stderr'] and 3 <= result['seconds'] < 4.5, result
            assert hashes == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
            assert first.rpc().exec_lua("return require('neovim_sync').ready()")
        second = start(beta, 'second')
        save('separate_root', {'alpha_pid': first.instance['pid'], 'beta_pid': second.instance['pid']})
        save('first_eof_cleanup', close(first))
        restarted = start(alpha, 'first')  # Same state, same build, no stale registry confusion.
        save('same_state_reconnect', {'pid': restarted.instance['pid'], 'ready': True})
        restarted.remember()
        os.kill(restarted.instance['pid'], signal.SIGSTOP)
        os.kill(restarted.proc.pid, signal.SIGKILL)
        restarted.proc.wait(timeout=3)
        result = attempt(alpha, output / 'after-kill-state')
        save('killed_launcher_stopped_child', result)
        assert result['exit'] != 0 and ('owns' in result['stderr'] or 'still owns' in result['stderr'])
        os.kill(restarted.instance['pid'], signal.SIGCONT)
        save('killed_launcher_cleanup', close(restarted, -signal.SIGKILL, False))
        recovered = start(alpha, 'after-kill')
        save('after_sigkill_reconnect', {'pid': recovered.instance['pid'], 'ready': True})
        assert second.rpc().exec_lua("return require('neovim_sync').ready()")
        if not args.ownership_only:
            runtime = recovered.rpc().exec_lua("return {events=#_G.v2_events, log_level=vim.lsp.log.get_level()}")
            save('default_runtime', runtime)
            assert runtime['events'] == 0 and runtime['log_level'] > 1, runtime
            recovered.remember()
            beams = [pid for pid, row in recovered.owned.items()
                     if 'beam.smp' in row['command'] and 'ElixirLS.LanguageServer.main()' in row['command']]
            assert len(beams) == 1, beams
            os.kill(beams[0], signal.SIGKILL)
            # A racing MCP request may finish before the editor's bounded exit grace.
            try:
                response = recovered.request('tools/call', {'name': 'lsp', 'arguments': {
                    'operation': 'hover', 'uri': str(alpha / 'lib/caller.ex'),
                    'line': 2, 'character': 29, 'timeoutMs': 1000}}, timeout=2)
                save('server_exit_reply', response)
                payload = '\n'.join(c.get('text', '') for c in response.get('content', []))
                if 'elixirls_exited' in payload:
                    error = json.loads(payload)['error']
                    assert error['retryable'] is False and 'retryAfterMs' not in error
            except (queue.Empty, OSError, RuntimeError) as error:
                assert poll(lambda: recovered.proc.poll(), lambda value: value is not None, 3)['matched']
                save('server_exit_reply', {'transport_closed': True, 'error': str(error)})
            assert poll(lambda: recovered.proc.poll(), lambda value: value is not None, 5)['matched']
            response = hook(recovered)
            save('server_exit_hook', response)
            assert 'reconnect' in json.dumps(response).lower(), response
            assert hook(recovered, 'Stop')['output'] == {}
            assert hook(recovered)['output'] == {}
            save('dead_session_reported_once', True)
            save('server_exit_cleanup', close(recovered, 1))
            final = start(alpha, 'after-kill')
            save('server_exit_reconnect', {'pid': final.instance['pid'], 'ready': True})
            final.remember()
            beam = next(pid for pid, row in final.owned.items()
                        if 'beam.smp' in row['command'] and 'ElixirLS.LanguageServer.main()' in row['command'])
            os.kill(beam, signal.SIGSTOP)
            os.kill(final.proc.pid, signal.SIGKILL)
            final.proc.wait(timeout=3)
            # Exercise the compiler-held lock with neither parent holding a lock.
            if alive([final.instance['pid']]):
                os.kill(final.instance['pid'], signal.SIGKILL)
            assert poll(lambda: alive([final.instance['pid']]), lambda v: not v, 3)['matched']
            for name, root, state in (
                    ('orphan_beam_root', alpha, output / 'orphan-state'),
                    ('orphan_beam_state', beta, final.state_dir)):
                # Beta is already live, so use a third root for shared-state refusal.
                if name == 'orphan_beam_state':
                    root = output / 'gamma'
                    subprocess.run(['git', 'clone', '-q', str(alpha), str(root)], check=True)
                result = attempt(root, state)
                save(name, result)
                assert result['exit'] != 0 and 'server.lock' in result['stderr'], result
            holders = subprocess.check_output(['/usr/sbin/lsof', '-Fpg',
                str(alpha / '.elixir_ls/server.lock')], text=True)
            save('orphan_lock_holders', holders.splitlines())
            assert f'p{beam}\n' in holders and f'g{final.instance["pid"]}\n' in holders
            gamma_client = start(output / 'gamma', 'third')
            save('new_root_while_orphaned', {'pid': gamma_client.instance['pid'], 'ready': True})
            save('new_root_cleanup', close(gamma_client))
            assert second.rpc().exec_lua("return require('neovim_sync').ready()")
            os.kill(beam, signal.SIGKILL)
            save('orphan_beam_cleanup', close(final, -signal.SIGKILL, False))
            last = start(alpha, 'after-kill')
            last.remember()
            os.kill(last.instance['pid'], signal.SIGSTOP)
            os.kill(last.proc.pid, signal.SIGTERM)
            time.sleep(0.15)
            os.kill(last.proc.pid, signal.SIGTERM)
            save('repeated_termination_cleanup', close(last, 143))
            healthy = start(alpha, 'after-kill')
            save('last_eof_cleanup', close(healthy))
        else:
            save('last_eof_cleanup', close(recovered))
        save('independent_session_cleanup', close(second))
        save('passed', True)
    finally:
        for client in clients:
            client.cleanup()


if __name__ == '__main__':
    main()
