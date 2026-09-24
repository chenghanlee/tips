#!/usr/bin/env python3
"""Real MCP qualification, native watcher scope, and queried-file error/repair."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

from neovim_hook_inversion_probe import LaunchedMCP
from neovim_probe import poll
from probe import prepare


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--batching', action='store_true')
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    output.mkdir(parents=True)
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    root, _, _, _ = prepare(output)
    client = rpc = None
    results = {}

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:650], flush=True)

    def nav(operation):
        return client.call('lsp', operation=operation, uri=str(root / 'lib/caller.ex'),
                           line=2, character=29)

    def hook():
        start = time.monotonic()
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('neovim_hook.py')),
            '--vendor', str(vendor), '--registry', str(client.registry), '--workspace', str(root)],
            input=json.dumps({'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch'}),
            text=True, capture_output=True, check=True, timeout=6)
        return {'seconds': time.monotonic() - start, 'output': json.loads(result.stdout)}

    def events():
        return rpc.exec_lua('return _G.v2_events')

    def build_count():
        return sum(e['method'] == 'telemetry/event' and e['data'].get('name') == 'build'
                   for e in events())

    try:
        client = LaunchedMCP(vendor, root, output, 'patch')
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        rpc = pynvim.attach('socket', path=entry['socket'])
        assert poll(lambda: nav('hover'), lambda v: 'ALPHA documentation' in json.dumps(v), 10)['matched']
        assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 10)['matched']
        if args.batching:
            # A native notification need not change the scanner's generation.
            # Real queued work must still qualify cached diagnostic results.
            initial_builds = build_count()
            queued = rpc.exec_lua('''
              local m = require('neovim_sync')
              local before = m.generation
              local c = vim.lsp.get_clients({name='elixirls'})[1]
              assert(c:notify('workspace/didChangeWatchedFiles', {
                changes={{uri=vim.uri_from_fname(...),type=2}}
              }))
              assert(vim.wait(150, function() return m.queued end, 5))
              return {before=before, state=m.status()}
            ''', str(root / 'lib/target.ex'))
            save('real_queued_status', queued)
            assert queued['state']['queued'] and not queued['state']['building']
            assert queued['before'] == queued['state']['generation']
            assert queued['state']['status'] == 'pending'
            save('real_queued_diagnostics', nav('diagnostics'))
            assert results['real_queued_diagnostics']['data']['feedback']['status'] == 'pending'
            assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"),
                        bool, 10)['matched']
            assert build_count() == initial_builds + 1
        rpc.exec_lua("require('neovim_sync').completed=-1")
        for operation in ('hover', 'definition', 'references', 'diagnostics'):
            value = nav(operation)
            save('pending_' + operation, value)
            assert not value['data'].get('error')
            assert value['data']['feedback']['status'] == 'pending'
        assert 'ALPHA documentation' in json.dumps(results['pending_hover']['data']['items'])
        assert results['pending_definition']['data']['locations']
        assert results['pending_references']['data']['locations']
        assert not results['pending_diagnostics']['data']['diagnostics']
        assert 'empty result' in results['pending_diagnostics']['data']['feedback']['message']
        rpc.exec_lua("local m=require('neovim_sync'); m.completed=m.generation; m.result='mix_compile_error'; m.activity=0")
        save('failed_hover', nav('hover'))
        assert results['failed_hover']['data']['feedback']['status'] == 'failed'
        assert 'ALPHA documentation' in json.dumps(results['failed_hover']['data']['items'])
        rpc.exec_lua("require('neovim_sync').result='mix_compile_ok'")

        # Exercise the real watcher, not just the scanner's Git filtering.
        time.sleep(1.2)
        mark, initial_builds = len(events()), build_count()
        fixture = root / 'tmp/ProviderFixture/config/runtime.exs'
        fixture.parent.mkdir(parents=True)
        for text in ('# created', '# modified with longer text'):
            fixture.write_text(text + '\n')
            time.sleep(0.5)
        fixture.unlink()
        time.sleep(1)
        fixture_events = [e for e in events()[mark:] if e['method'] == 'sent:workspace/didChangeWatchedFiles']
        save('fixture_filter', {'notifications': fixture_events,
                               'new_builds': build_count() - initial_builds, 'hook': hook()})
        assert not fixture_events and build_count() == initial_builds
        assert results['fixture_filter']['hook']['output'] == {}
        # Positive controls ensure configuration and external templates remain watched.
        for relative in ('config/control.exs', 'lib/control.ex', 'priv/control.heex'):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# watched control\n')
            observed = poll(events, lambda es: any(e['method'] == 'sent:workspace/didChangeWatchedFiles'
                and any(c['uri'] == path.as_uri() for c in e['data']['changes']) for e in es[mark:]), 4)
            assert observed['matched'], relative + ' was incorrectly excluded'
        save('positive_watcher_controls', True)
        hook()
        assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 10)['matched']
        caller = root / 'lib/caller.ex'
        original = caller.read_text()
        time.sleep(1.2)
        caller.write_text(original.replace('V2Target.answer()', 'missing_revision()', 1))
        save('queried_file_error', hook())
        assert 'missing_revision/0' in json.dumps(results['queried_file_error'])
        save('failed_definition', nav('definition'))
        assert not results['failed_definition']['data'].get('error')
        # A late diagnostic publication can still be inside the quiet window.
        assert results['failed_definition']['data']['feedback']['status'] in {'failed', 'pending'}
        time.sleep(1.2)
        caller.write_text(original)
        save('queried_file_repair', hook())
        assert 'cleared' in json.dumps(results['queried_file_repair'])
        save('repaired_diagnostics', nav('diagnostics'))
        assert results['repaired_diagnostics']['data']['feedback']['status'] == 'current'
        assert not results['repaired_diagnostics']['data']['diagnostics']
        # Drop exactly one real save notification. The ordinary hook must retry
        # and deliver actual compiler feedback without another disk edit.
        rpc.exec_lua('''
          local c = vim.lsp.get_clients({name='elixirls'})[1]
          _G.v3_notify, _G.v3_save_attempts = c.notify, 0
          c.notify = function(self, method, ...)
            if method == 'textDocument/didSave' then
              _G.v3_save_attempts = _G.v3_save_attempts + 1
              if _G.v3_save_attempts == 1 then return false end
            end
            return _G.v3_notify(self, method, ...)
          end
        ''')
        caller.write_text(original.replace('V2Target.answer()', 'missing_retry()', 1))
        save('retried_real_save', hook())
        assert 'missing_retry/0' in json.dumps(results['retried_real_save'])
        attempts = rpc.exec_lua("vim.lsp.get_clients({name='elixirls'})[1].notify=_G.v3_notify; return _G.v3_save_attempts")
        save('real_save_attempts', attempts)
        assert attempts == 2
        caller.write_text(original)
        assert 'cleared' in json.dumps(hook())
        save('events', events())
        save('completed', True)
    finally:
        if rpc:
            rpc.close()
        if client:
            client.cleanup()


if __name__ == '__main__':
    main()
