#!/usr/bin/env python3
"""Real MCP/save lifecycle regression, plus isolated ordering/delivery boundaries."""
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
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    output.mkdir(parents=True)
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    root, beta, _, _ = prepare(output)
    results = {}
    client = rpc = None

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:700], flush=True)

    def hook():
        started = time.monotonic()
        proc = subprocess.run([sys.executable, str(Path(__file__).with_name('neovim_hook.py')),
            '--vendor', str(vendor), '--registry', str(client.registry), '--workspace', str(root),
            '--audit', str(output / 'audit.jsonl')],
            input=json.dumps({'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch'}),
            text=True, capture_output=True, check=True, timeout=6)
        return {'seconds': time.monotonic() - started, 'output': json.loads(proc.stdout)}

    def nav(operation, path='lib/caller.ex'):
        return client.call('lsp', operation=operation, uri=str(root / path), line=2, character=29)

    try:
        client = LaunchedMCP(vendor, root, output, 'revision')
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        rpc = pynvim.attach('socket', path=entry['socket'])
        assert poll(lambda: nav('hover'), lambda v: 'ALPHA documentation' in json.dumps(v), 10)['matched']
        caller = root / 'lib/caller.ex'
        original = caller.read_text()
        time.sleep(1.2)  # Let the native watcher establish its initial file stat.
        caller.write_text(original.replace('V2Target.answer()', 'missing_revision()', 1))
        save('queried_file_error', hook())
        assert 'missing_revision/0' in json.dumps(results['queried_file_error'])
        time.sleep(1.2)
        caller.write_text(original)
        save('queried_file_repair', hook())
        assert 'cleared' in json.dumps(results['queried_file_repair'])
        save('diagnostics_after_repair', nav('diagnostics'))
        assert not results['diagnostics_after_repair']['data'].get('error')
        assert not results['diagnostics_after_repair']['data']['diagnostics']
        save('save_notifications', rpc.exec_lua("return vim.tbl_filter(function(e) return e.method == 'sent:textDocument/didSave' end, _G.v2_events)"))
        assert len(results['save_notifications']) >= 2
        # Exercise actual installed Lua with controlled state; these are not live
        # compiler ordering claims. No test edits the adapter's implementation.
        save('logic_boundaries', rpc.exec_lua('''
          local source = vim.api.nvim_get_runtime_file('lua/neovim_sync.lua', false)[1]
          local function fresh()
            local m = dofile(source)
            m.root = vim.fn.getcwd()
            m.scan = function() end
            return m
          end
          local m = fresh()
          m.generation = 1
          m.collect(0)
          assert(m.last_output == '' and not m.reported_pending)
          local first = m.collect(0, 'PostToolUse')
          assert(first.message ~= '' and first.status == 'pending')
          assert(m.collect(0, 'PostToolUse').message == '')
          m.generation = 2
          local second = m.collect(0, 'PostToolUse')
          assert(second.message ~= '' and second.status == 'pending')
          m.scan = function() error('injected scan failure') end
          assert(not pcall(m.collect, 0, 'Stop') and m.stop_pending)

          local delayed = fresh()
          delayed.generation, delayed.completed = 1, 1
          delayed.scan = function()
            delayed.generation = 2
          end
          delayed.observe('window/logMessage', {message='Starting build with MIX_ENV: test'})
          delayed.scan = function() end
          delayed.observe('telemetry/event', {name='build',properties={['elixir_ls.build_result']='mix_compile_ok'}})
          delayed.activity = 0
          assert(delayed.ready(), 'completed build observation did not resume service')

          -- A slow initial scan must consume the wait allowance, not extend it.
          local bounded = fresh()
          bounded.generation = 1
          bounded.scan = function() vim.wait(160) end
          local start = vim.uv.hrtime()
          bounded.collect(200)
          local elapsed = (vim.uv.hrtime() - start)/1e6
          assert(elapsed < 280, 'scan was added to the wait budget: '..elapsed)
          return {private_read=true, first_edit=true, next_edit=true,
            failed_stop_preserved=true, completed_observation_resumes=true, scan_budget_ms=elapsed}
        '''))
        # Public MCP must preserve useful results and qualify cache reads.
        rpc.exec_lua("local m=require('neovim_sync'); m.completed=-1")
        save('pending_hover', nav('hover'))
        save('pending_diagnostics', nav('diagnostics'))
        assert results['pending_hover']['data']['feedback']['status'] == 'pending'
        assert 'ALPHA documentation' in json.dumps(results['pending_hover']['data']['items'])
        assert results['pending_diagnostics']['data']['feedback']['status'] == 'pending'
        assert 'diagnostics' in results['pending_diagnostics']['data']
        save('completed', True)
    finally:
        if rpc:
            rpc.close()
        if client:
            client.cleanup()


if __name__ == '__main__':
    main()
