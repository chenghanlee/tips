#!/usr/bin/env python3
"""Test honest startup hints and editor save-to-diagnostic latency locally.

Read tools use real MCP. Edits use Neovim's official RPC because vv-mcp 0.3.4
does not expose arbitrary buffer editing. This is not a Codex editing rollout.
"""

import argparse
import json
from pathlib import Path
import sys

from inversion_probe import target_text
from neovim_probe import NvimMCP, poll
from probe import alive, prepare, process_table


EDIT_SAVE = '''
local path, lines, want_error, timeout = ...
local b = vim.fn.bufadd(path)
vim.fn.bufload(b)
local mark = #_G.v2_events
local start = vim.uv.hrtime() / 1e9
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
vim.api.nvim_buf_call(b, function() vim.cmd('write') end)
local saved = vim.uv.hrtime() / 1e9
local observed
local matched = vim.wait(timeout, function()
  for i = mark + 1, #_G.v2_events do
    local e = _G.v2_events[i]
    if e.method == 'textDocument/publishDiagnostics' and e.data.uri == vim.uri_from_fname(path) then
      local has_error = false
      for _, d in ipairs(e.data.diagnostics or {}) do
        if d.severity == 1 then has_error = true end
      end
      if has_error == want_error then observed = e; return true end
    end
  end
  return false
end, 10)
return {
  matched = matched, elapsed_ms = (vim.uv.hrtime() / 1e9 - start) * 1000,
  save_ms = (saved - start) * 1000,
  diagnostic_after_save_ms = observed and (observed.time - saved) * 1000 or nil,
  publication = observed,
  modified = vim.bo[b].modified,
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    sys.path.insert(0, str(vendor / 'python'))
    process_table()
    output.mkdir(parents=True)
    results = {}

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:600], flush=True)

    def has(text):
        return lambda value: text in json.dumps(value)

    alpha, _, _, _ = prepare(output)
    target, caller = alpha / 'lib/target.ex', alpha / 'lib/caller.ex'
    original_target, original_caller = target.read_text(), caller.read_text()
    target.write_text(target_text('FEEDBACK_STARTUP', delay=3000))
    client = NvimMCP(vendor, alpha, output, 'feedback', sync_reads=True, feedback=True)
    try:
        first = client.nav('hover')
        save('startup_response', first)
        assert first['data'].get('feedback', first['data'].get('error', {}).get('feedback', {})).get('status') in {'pending', 'unavailable'}, 'Expected qualified startup hint'
        ready = poll(lambda: client.nav('hover'),
                     has('FEEDBACK_STARTUP documentation'), 15)
        save('startup_eventual_hover', ready)
        assert ready['matched']

        save('restore_target', client.rpc().exec_lua(
            EDIT_SAVE, str(target), original_target.splitlines(), False, 2000))
        restored = poll(lambda: client.nav('hover'), has('ALPHA documentation'))
        assert restored['matched']
        save('valid_empty_hover', client.call('lsp', operation='hover', uri=str(caller),
                                             line=2, character=1, timeoutMs=10000))
        assert results['valid_empty_hover']['data']['items'] == []

        for i in range(3):
            bad = original_caller.replace('V2Target.answer()', 'missing_local()', 1)
            mark = len(client.events())
            error = client.rpc().exec_lua(EDIT_SAVE, str(caller), bad.splitlines(), True, 1000)
            save(f'edit_save_error_{i}', error)
            assert error['matched'], 'No error publication within the one-second observation budget'
            assert caller.read_text().splitlines() == bad.splitlines()
            assert not error['modified']
            failed = poll(lambda: client.nav('diagnostics'),
                          lambda v: 'missing_local/0' in json.dumps(v) and not v['data'].get('error'), 5)
            save(f'failed_build_response_{i}', failed)
            assert failed['matched']
            save(f'error_diagnostics_{i}', client.nav('diagnostics'))
            repair = client.rpc().exec_lua(EDIT_SAVE, str(caller), original_caller.splitlines(), False, 1000)
            save(f'edit_save_repair_{i}', repair)
            assert repair['matched']
            repaired = poll(lambda: client.nav('hover'), has('ALPHA documentation'), 5)
            save(f'repaired_hover_{i}', repaired)
            assert repaired['matched']
            save(f'edit_cycle_events_{i}', client.events()[mark:])

        # A slow valid build exceeds the desired feedback budget; it must say busy.
        slow = target_text('FEEDBACK_SLOW', delay=3000)
        save('slow_edit_save', client.rpc().exec_lua(EDIT_SAVE, str(target), slow.splitlines(), True, 1000))
        save('slow_build_response', client.nav('hover'))
        assert results['slow_build_response']['data']['feedback']['status'] == 'pending'
        done = poll(lambda: client.nav('hover'), has('FEEDBACK_SLOW documentation'), 10)
        save('slow_eventual_hover', done)
        assert done['matched']
        save('final_restore', client.rpc().exec_lua(
            EDIT_SAVE, str(target), original_target.splitlines(), False, 2000))
        assert poll(lambda: client.nav('hover'), has('ALPHA documentation'))['matched']
        save('events', client.events())
        client.remember()
        client.proc.stdin.close()
        client.proc.wait(timeout=8)
        save('eof_cleanup', poll(lambda: alive(client.owned), lambda value: not value, 6))
        assert results['eof_cleanup']['matched']
        save('completed', True)
    finally:
        try:
            if client.proc.poll() is None:
                save('last_observed_events', client.events())
        finally:
            client.cleanup()


if __name__ == '__main__':
    main()
