#!/usr/bin/env python3
"""Installed-stack boundary tests for startup, ownership, shutdown and scan recovery."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import MCP, alive, prepare


class BoundMCP(MCP):
    def __init__(self, bundle, root, output, environment):
        self.root, self.name, self.counter = root, 'bound', 0
        self.responses, self.owned = queue.Queue(), {}
        self.log = (output / 'bound.stderr.log').open('w')
        self.transcript = (output / 'bound.jsonl').open('w')
        self.proc = subprocess.Popen([str(bundle / 'vendor/vv-mcp'), '--instance-id',
            'deliberately-absent-instance'], cwd=root, env=os.environ | environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, bufsize=1, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
            'clientInfo': {'name': 'bound-instance-gate', 'version': '1'}}, timeout=15)
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--case', action='append', help='Run only the named boundary (repeatable)')
    args = p.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    results = {}

    def check(name, fn):
        try:
            detail = fn()
            results[name] = {'passed': True, 'detail': detail}
        except Exception as error:
            results[name] = {'passed': False, 'error': repr(error)}
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(results[name])[:1600], flush=True)

    def fixture(name):
        directory = output / name
        directory.mkdir()
        root, _, _, _ = prepare(directory)
        return directory, root

    def hook(client, event='PostToolUse', budget=5000):
        t = time.monotonic()
        proc = subprocess.run([sys.executable, str(bundle / 'bundle.py'), 'hook',
            '--workspace', str(client.root), '--state', str(client.state_dir),
            '--budget-ms', str(budget)], input=json.dumps({'hook_event_name': event,
            'tool_name': 'Bash'}), text=True, capture_output=True, timeout=6)
        assert proc.returncode == 0, proc.stderr
        return {'seconds': time.monotonic() - t, 'output': json.loads(proc.stdout)}

    def cold_start():
        directory, root = fixture('cold')
        target = root / 'lib/target.ex'
        target.write_text(target.read_text().replace('defmodule V2Target do',
            'defmodule V2Target do\n  File.write!(' + json.dumps(str(root / 'compile-started'))
            + ', "started")\n  Process.sleep(16000)'))
        client = None
        try:
            t = time.monotonic()
            client = BundleMCP(bundle, root, directory, 'cold')
            elapsed = time.monotonic() - t
            reply = client.call('lsp', operation='document_symbols',
                uri=str(target), timeoutMs=500)
            detail = {'initialize_seconds': elapsed, 'reply': reply}
            (directory / 'observed.json').write_text(json.dumps(detail, indent=2))
            assert elapsed < 5, detail
            assert reply['data']['feedback']['status'] in {'pending', 'unavailable'}, reply
            assert poll(lambda: (root / 'compile-started').exists(), bool, 10)['matched']
            detail['compiler_entered_slow_module_before_shutdown'] = True
            (directory / 'observed.json').write_text(json.dumps(detail, indent=2))
            return detail
        finally:
            if client:
                try:
                    client.remember()
                    client.proc.stdin.close()
                    client.proc.wait(timeout=6)
                    cleanup = poll(lambda: alive(client.owned), lambda x: not x, 4)
                    (directory / 'cleanup.json').write_text(json.dumps(cleanup, indent=2))
                    assert cleanup['matched'], cleanup
                finally:
                    client.cleanup()

    def death():
        directory, root = fixture('death')
        client = BundleMCP(bundle, root, directory, 'death')
        try:
            pid = client.rpc().exec_lua('return vim.fn.getpid()')
            client.remember()
            os.kill(pid, signal.SIGKILL)
            # Race a request against the launcher's child-death observation.
            try:
                reply = client.request('tools/call', {'name': 'lsp', 'arguments': {
                    'operation': 'document_symbols', 'uri': str(root / 'lib/target.ex'),
                    'timeoutMs': 500}}, timeout=2)
            except (queue.Empty, BrokenPipeError, RuntimeError) as error:
                reply = {'closed': type(error).__name__}
            exited = poll(lambda: client.proc.poll(), lambda x: x is not None, 3)
            feedback = hook(client)
            entries = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
            detail = {'exited': exited, 'reply': reply, 'hook': feedback, 'registry': entries}
            (directory / 'observed.json').write_text(json.dumps(detail, indent=2))
            assert exited['matched'], detail
            assert all(e.get('kind') != 'managed' for e in entries), detail
            assert 'unavailable' in json.dumps(feedback).lower(), detail
            assert poll(lambda: alive(client.owned), lambda x: not x, 4)['matched']
            return detail
        finally:
            client.cleanup()

    def stalled_shutdown(trigger='eof'):
        directory, root = fixture('stalled-' + trigger)
        client = BundleMCP(bundle, root, directory, 'stalled')
        pid = client.rpc().exec_lua('return vim.fn.getpid()')
        try:
            client.remember()
            os.kill(pid, signal.SIGSTOP)
            t = time.monotonic()
            if trigger == 'eof':
                client.proc.stdin.close()
            else:
                client.proc.terminate()
            try:
                client.proc.wait(timeout=6)
                exited = True
            except subprocess.TimeoutExpired:
                exited = False
            detail = {'exited': exited, 'seconds': time.monotonic() - t,
                      'survivors': alive(client.owned)}
            (directory / 'observed.json').write_text(json.dumps(detail, indent=2))
            assert exited, detail
            assert poll(lambda: alive(client.owned), lambda x: not x, 4)['matched']
            return detail
        finally:
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
            client.cleanup()

    def absent_bound_instance():
        directory, root = fixture('bound')
        subprocess.run([sys.executable, str(bundle / 'bundle.py'), 'prepare',
            '--workspace', str(root), '--state', str(directory / 'session')],
            check=True, capture_output=True)
        env = json.loads((directory / 'session/environment.json').read_text())
        client = BoundMCP(bundle, root, directory, env)
        try:
            reply = client.call('lsp', operation='document_symbols',
                uri=str(root / 'lib/target.ex'), timeoutMs=500)
            client.remember()
            entries = list(Path(env['VV_MCP_REGISTRY']).glob('*.json'))
            detail = {'reply': reply, 'registry_files': [str(p) for p in entries],
                      'owned': client.owned}
            (directory / 'observed.json').write_text(json.dumps(detail, indent=2))
            assert not entries, 'a bound MCP request spawned a managed instance'
            assert 'deliberately-absent-instance' in json.dumps(reply), reply
            return detail
        finally:
            client.cleanup()

    def scan_failure():
        directory, root = fixture('scan')
        client = BundleMCP(bundle, root, directory, 'scan')
        try:
            rpc = client.rpc()
            assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 15)['matched']
            rpc.exec_lua('''
              local m = require('neovim_sync')
              local observe = m.observe
              m.observe = function(method, data)
                if method == 'telemetry/event' and data.name == 'build' and not _G.scan_fault then
                  local system = vim.system
                  vim.system = function() return {wait=function() return {code=1,stdout=''} end} end
                  local ok, err = pcall(observe, method, data)
                  vim.system = system
                  _G.scan_fault = {ok=ok, error=tostring(err), state=m.status()}
                else observe(method, data) end
              end
            ''')
            path = root / 'lib/target.ex'
            path.write_text(path.read_text().replace('def answer', 'def failure, do: missing_scan_probe()\n  def answer'))
            rpc.exec_lua("require('neovim_sync').scan()")
            captured = poll(lambda: rpc.exec_lua('return _G.scan_fault'), bool, 15)
            assert captured['matched'], captured
            failed = captured['samples'][-1]['value']
            # No diagnostic reads or additional edits between failure and this hook.
            time.sleep(0.25)
            retried = hook(client)
            detail = {'at_failure': failed, 'retry_hook': retried,
                      'after_retry': rpc.exec_lua("return require('neovim_sync').status()")}
            (directory / 'observed.json').write_text(json.dumps(detail, indent=2))
            assert not failed['state']['building'], detail
            assert failed['state']['status'] == 'sync_error', detail
            assert 'missing_scan_probe/0' in json.dumps(retried), detail
            assert detail['after_retry']['status'] == 'failed', detail
            return detail
        finally:
            client.cleanup()

    def hook_identity():
        directory, root = fixture('identity')
        client = BundleMCP(bundle, root, directory, 'identity')
        try:
            entry_path, = client.registry.glob('*.json')
            original = entry_path.read_text()
            entry = json.loads(original)
            entry['instanceId'] += '-replacement'
            entry_path.write_text(json.dumps(entry))
            try:
                reply = hook(client)
            finally:
                entry_path.write_text(original)
            assert 'differs from the session owner' in json.dumps(reply), reply
            return reply
        finally:
            client.cleanup()

    for name, fn in [('cold_start', cold_start), ('neovim_death', death),
                     ('stalled_shutdown', stalled_shutdown), ('bound_instance', absent_bound_instance),
                     ('scan_failure_recovery', scan_failure), ('hook_identity', hook_identity),
                     ('stalled_sigterm', lambda: stalled_shutdown('sigterm'))]:
        if not args.case or name in args.case:
            check(name, fn)
    assert results, 'No matching boundary selected'
    assert all(r['passed'] for r in results.values()), results


if __name__ == '__main__':
    main()
