#!/usr/bin/env python3
"""Reviewer acceptance harness: first-touch diagnostics readiness barrier (any bundle).

Contract (Astra, 2026-09-25): project build completion does not prove that a newly opened document
has published diagnostics. A document is ready only after a publication whose `version` matches the
version sent for it (didOpen/didChange); a new version or a reopen invalidates that. Missing or
mismatched versions never mean ready. Unmatched diagnostics stay as qualified results. Any wait is
bounded by the request budget.

Black-box through real stdio MCP on a disposable fixture. At the network boundary, this disposable
Neovim's per-client publishDiagnostics handler is wrapped to record every publication and to delay
or drop publications for named fixture files; a wrapper around the client's rpc.notify records sent versions. Nothing
else in the bundle is touched.

Verdict per case (`FAIL` = contract broken):
  * error file: a `current` answer without that file's error is a false clean;
  * clean file: `current` before a delivered publication with the sent version is a false ready;
  * bounded: a call taking longer than the budget plus 0.5 s;
  * useful: warm or build diagnostics that exist must be returned (any status).
Measurements only (no verdict): the first-read hover status (150 ms quiet window) and timings.

Traps measured on r21 (session evidence, not in the repo): an on-disk edit to an open file makes
Neovim send didClose + didOpen with version 0 again, and ElixirLS's build publications carry the
build-trigger version (0) with build-only diagnostics before the parse publication. Cases R6c, R7
and R8 make these deterministic: `hold_after_error` holds a file's first publication that carries
diagnostics and every later one (as if its parse were slower); `replay` re-delivers the file's last
publication right after its next didOpen (a simulated in-flight stale message, not observed naturally).
Checker limit: for clean files, "matched" means version-equal; C1 and R6a have no build in between.

Run: python3 first_touch_acceptance.py --bundle <installed bundle> --output <new directory>
It exits 0 only when no case or V1 failed, EOF cleanup worked and no process survived.
It imports bundle_probe, neovim_probe, probe and inversion_probe from this directory.
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import alive

BUDGET_MS = 3000
DELAY_MS = 4500
BAD = 'defmodule Fr.{name}Test do\n  use ExUnit.Case\n  def broken(, do: 1\nend\n'
GOOD = 'defmodule Fr.{name}Test do\n  use ExUnit.Case\nend\n'
BOUNDARY = r"""
local rules = ...
local client = vim.lsp.get_clients({ name = 'elixirls' })[1]
local function now() return vim.uv.hrtime() / 1e9 end
_G.review_log = {}
_G.review_last = _G.review_last or {}
if not _G.review_handler then
  _G.review_handler = client.handlers['textDocument/publishDiagnostics']
  client.handlers['textDocument/publishDiagnostics'] = function(err, data, ctx, config)
    local file = data.uri:match('[^/]+$')
    local rule = _G.review_rules[file]
    local row = { t = now(), kind = 'published', file = file, version = data.version or vim.NIL,
      diagnostics = #data.diagnostics }
    if rule == 'drop' then row.kind = 'dropped'; table.insert(_G.review_log, row); return end
    local hold = type(rule) == 'number' and rule or nil
    if type(rule) == 'table' and rule.hold_after_error and (rule.holding or #data.diagnostics > 0) then
      rule.holding, hold = true, rule.hold_after_error
    end
    if hold then
      row.kind = 'held'
      table.insert(_G.review_log, row)
      vim.defer_fn(function()
        table.insert(_G.review_log, { t = now(), kind = 'delivered-late', file = file,
          version = data.version or vim.NIL, diagnostics = #data.diagnostics })
        _G.review_handler(err, data, ctx, config)
      end, hold)
      return
    end
    table.insert(_G.review_log, row)
    _G.review_last[file] = { err = err, data = data, ctx = ctx, config = config }
    return _G.review_handler(err, data, ctx, config)
  end
  -- Sends are recorded inside rpc.notify (outermost wrapper): synchronous, every notification,
  -- Neovim's version before any inner rewrite and the version actually sent after it.
  -- (LspNotify is scheduled and skipped for detached buffers, client.lua:839.)
  local inner = client.rpc.notify
  client.rpc.notify = function(method, params)
    local doc = type(params) == 'table' and params.textDocument or nil
    local before = doc and doc.version
    local result = inner(method, params)
    if doc and method:match('^textDocument/did') then
      local file = doc.uri:match('[^/]+$')
      table.insert(_G.review_log, { t = now(), kind = 'sent', method = method:sub(14), file = file,
        neovim_version = before or vim.NIL, version = doc.version or vim.NIL })
      local rule, last = _G.review_rules[file], _G.review_last[file]
      if method == 'textDocument/didOpen' and type(rule) == 'table' and rule.replay and last
          and not rule.replayed then
        rule.replayed = true
        vim.schedule(function()
          table.insert(_G.review_log, { t = now(), kind = 'replayed', file = file,
            version = last.data.version or vim.NIL, diagnostics = #last.data.diagnostics })
          _G.review_handler(last.err, last.data, last.ctx, last.config)
        end)
      end
    end
    return result
  end
end
_G.review_rules = rules
return client.handlers['textDocument/publishDiagnostics'] ~= _G.review_handler
"""
TAKE = 'local e = _G.review_log; _G.review_log = {}; return e'
RULE = 'local file, rule = ...; _G.review_rules[file] = rule; return true'
STATE = """local s = require('neovim_sync'); local st = s.status()
return { status = st.status, generation = s.generation, completed = s.completed }"""


def fixture(root):
    for directory in ('lib', 'test/support'):
        (root / directory).mkdir(parents=True)
    (root / 'mix.exs').write_text(
        'defmodule Fr.MixProject do\n  use Mix.Project\n'
        '  def project, do: [app: :fr, version: "0.1.0", elixirc_paths: elixirc_paths(Mix.env())]\n'
        '  defp elixirc_paths(:test), do: ["lib", "test/support"]\n'
        '  defp elixirc_paths(_), do: ["lib"]\nend\n')
    for name in ('alpha', 'gamma'):
        (root / f'lib/{name}.ex').write_text(
            f'defmodule Fr.{name.capitalize()} do\n  @doc "Docs."\n  def value(x), do: Fr.Shared.twice(x)\nend\n')
    (root / 'lib/shared.ex').write_text('defmodule Fr.Shared do\n  @doc "Doubles."\n  def twice(x), do: x * 2\nend\n')
    (root / 'lib/page.html.heex').write_text('<div class="x"><%= @value %></div>\n')
    # Attached (eelixir, surface) but not parsed by ElixirLS 0.31.1 should_parse?: must not stay pending.
    (root / 'lib/legacy.html.leex').write_text('<div class="x"><%= @value %></div>\n')
    (root / 'lib/card.sface').write_text('<div class="x">{@value}</div>\n')
    (root / 'lib/warn.ex').write_text('defmodule Fr.Warn do\n  def unused(x), do: 1\nend\n')
    (root / 'test/support/support_helper.ex').write_text('defmodule Fr.SupportHelper do\n  def unused(y), do: 1\nend\n')
    for name in ('bad', 'twice', 'worse', 'late', 'lost', 'race2'):
        (root / f'test/{name}_test.exs').write_text(BAD.format(name=name.capitalize()))
    for name in ('good', 'edit', 'reopen', 'replay', 'twoedits', 'gone', 'conflict', 'life'):
        (root / f'test/{name}_test.exs').write_text(GOOD.format(name=name.capitalize()))
    subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
    subprocess.run(['git', 'add', '.'], cwd=root, check=True)
    subprocess.run(['git', '-c', 'user.email=r@x', '-c', 'user.name=r', 'commit', '-qm', 'fixture'],
                   cwd=root, check=True)


class Harness:
    def __init__(self, bundle, output):
        self.root = output / 'fr'
        fixture(self.root)
        self.bundle = bundle
        self.client = BundleMCP(bundle, self.root, output, 'acceptance')
        self.cases, self.log = [], []
        self.error_files = {'bad_test.exs', 'twice_test.exs', 'worse_test.exs', 'late_test.exs', 'lost_test.exs'}

    def lua(self, code, *args):
        return self.client.rpc().exec_lua(code, *args)

    def ready(self):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            try:
                state = self.lua(STATE)
                if state['status'] == 'current' and state['completed'] == state['generation']:
                    return state
            except Exception:  # noqa: BLE001  registry not written yet
                self.client.nvim = None
            time.sleep(0.5)
        raise SystemExit('never became current')

    def drain(self):
        self.log.extend(self.lua(TAKE))

    def call(self, operation, file, **extra):
        uri = str(self.root / file)
        started = time.monotonic()
        t0 = self.lua('return vim.uv.hrtime() / 1e9')
        reply = self.client.call('lsp', operation=operation, uri=uri, **extra)
        elapsed = round((time.monotonic() - started) * 1000, 1)
        self.drain()
        data = reply['data'] if isinstance(reply.get('data'), dict) else {}
        feedback = data.get('feedback') or {}
        entries = data.get('diagnostics', {}) if operation.endswith('diagnostics') else {}
        by_file = {Path(path).name: items for path, items in entries.items()} if isinstance(entries, dict) else {}
        return {'t': t0, 'operation': operation, 'file': file, 'status': feedback.get('status'),
                'call_ms': elapsed, 'is_error': reply.get('isError'),
                'diagnostics': {name: len(items) for name, items in by_file.items()},
                'error_code': (data.get('error') or {}).get('code') if isinstance(data.get('error'), dict) else None,
                'items': len(data.get('items', [])) if 'items' in data else None}

    def matched_publication_before(self, file, t):
        """Was a publication with the latest sent version delivered for `file` before time t?"""
        sent = [e for e in self.log if e['kind'] == 'sent' and e['file'] == file and e['t'] <= t
                and e['method'] in ('didOpen', 'didChange')]
        if not sent:
            return False
        version = sent[-1]['version']
        return any(e['kind'] in ('published', 'delivered-late') and e['file'] == file
                   and e['version'] == version and sent[-1]['t'] <= e['t'] <= t for e in self.log)

    def verdict(self, sample, has_error_on_disk, parsed=True):
        name = Path(sample['file']).name
        problems = []
        if sample['call_ms'] > BUDGET_MS + 500:
            problems.append('unbounded')
        if sample['status'] == 'current' and sample['operation'].endswith('diagnostics'):
            if has_error_on_disk and not sample['diagnostics'].get(name):
                problems.append('false clean')
            # A document ElixirLS never parses gets no versioned publication to wait for.
            if parsed and not has_error_on_disk and not self.matched_publication_before(
                    name, sample['t'] + sample['call_ms'] / 1000):
                problems.append('false ready')
        return problems

    def case(self, label, samples, has_error_on_disk, expect_useful=None, measure_only=False,
             ready_by_end=False, parsed=True):
        rows, failures = [], []
        # Ready = `current` at least once in the second half (builds may cause a brief pending).
        if ready_by_end and not any(x['status'] == 'current' for x in samples[len(samples) // 2:]):
            failures.append('never ready in the second half (permanent pending?)')
        for sample in samples:
            problems = [] if measure_only else self.verdict(sample, has_error_on_disk, parsed)
            name = Path(sample['file']).name
            if expect_useful and not sample['diagnostics'].get(name):
                problems.append('lost useful diagnostics')
            failures += problems
            rows.append({k: v for k, v in sample.items() if k != 't'} | {'problems': problems})
        result = 'MEASURED' if measure_only else ('FAIL' if failures else 'PASS')
        if failures and not any(r['problems'] for r in rows):
            rows[-1]['problems'] = failures
        self.cases.append({'case': label, 'result': result, 'samples': rows})
        print(f'{result:<8} {label}  ' + '; '.join(
            f"{r['status']}/{r['diagnostics'] or r['items'] or r['error_code'] or '-'}/{r['call_ms']}ms"
            + (f"!{','.join(r['problems'])}" if r['problems'] else '') for r in rows), flush=True)

    def hook(self, label, event='PostToolUse'):
        """One hook exactly as Codex runs it; measured, not judged."""
        before = self.lua(STATE)
        started = time.monotonic()
        run = subprocess.run([sys.executable, str(self.bundle / 'bundle.py'), 'hook', '--workspace', str(self.root),
                              '--state', str(self.client.state_dir), '--budget-ms', '5000'],
                             input=json.dumps({'hook_event_name': event, 'tool_name': 'apply_patch',
                                               'stop_hook_active': False}),
                             capture_output=True, text=True, timeout=30)
        row = {'case': label, 'result': 'MEASURED', 'seconds': round(time.monotonic() - started, 2),
               'status_before': before, 'output': run.stdout.strip()[:600], 'exit': run.returncode}
        self.cases.append(row)
        print(f"MEASURED {label}  {row['seconds']} s  {row['output'][:260]}", flush=True)

    def polled(self, operation, file, seconds, gap=0.05):
        samples, end = [], time.monotonic() + seconds
        while time.monotonic() < end:
            samples.append(self.call(operation, file))
            time.sleep(gap)
        return samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    h = Harness(bundle, output)
    results = {'bundle': str(bundle), 'budget_ms': BUDGET_MS}
    try:
        results['ready'] = h.ready()
        time.sleep(2)
        assert h.lua(BOUNDARY, {'late_test.exs': DELAY_MS, 'lost_test.exs': 'drop'}), 'boundary not installed'

        h.case('C1 clean first touch, polled 1 s', h.polled('diagnostics', 'test/good_test.exs', 1.0), False,
               ready_by_end=True)
        h.case('R2 error first touch, polled 1 s', h.polled('diagnostics', 'test/bad_test.exs', 1.0), True,
               ready_by_end=True)
        h.case('R3 two immediate repeats', [h.call('diagnostics', 'test/twice_test.exs'),
                                            h.call('diagnostics', 'test/twice_test.exs')], True)
        race = [h.call('diagnostics', 'test/worse_test.exs')]
        h.call('hover', 'lib/alpha.ex', line=3, character=33)
        race += h.polled('diagnostics', 'test/worse_test.exs', 0.6)
        h.case('R1 forced-parse null-version publication (hover on another new file)', race, True)
        h.hook('H1 PostToolUse hook, every open document published')
        late = h.polled('diagnostics', 'test/late_test.exs', 1.0)
        time.sleep(DELAY_MS / 1000 + 0.5)
        late.append(h.call('diagnostics', 'test/late_test.exs'))
        h.case(f'R4 publication delayed {DELAY_MS} ms (> budget), then delivered', late, True, ready_by_end=True)
        h.case('R5 publication dropped', h.polled('diagnostics', 'test/lost_test.exs', 1.0, gap=0.3), True)
        ws = h.call('workspace_diagnostics', 'test/lost_test.exs')
        ws['file'] = 'test/lost_test.exs'
        h.case('WS workspace diagnostics while lost_test.exs awaits', [ws], True)
        h.hook('H2 PostToolUse hook while lost_test.exs never gets a publication')
        h.case('W1 warm error file while lost_test.exs awaits (URIs independent)',
               [h.call('diagnostics', 'test/bad_test.exs')], True, expect_useful=True, ready_by_end=True)
        h.case('W2 lib build warning, first touch', [h.call('diagnostics', 'lib/warn.ex')], True, expect_useful=True)
        h.case('W3 test/support build warning, first touch',
               [h.call('diagnostics', 'test/support/support_helper.ex')], True, expect_useful=True)

        first = h.call('diagnostics', 'test/edit_test.exs')
        time.sleep(1.5)
        settled = h.call('diagnostics', 'test/edit_test.exs')
        h.case('R6a clean file before edit', [first, settled], False, ready_by_end=True)
        (h.root / 'test/edit_test.exs').write_text(BAD.format(name='Edit'))
        h.case('R6b after an on-disk edit to an open file, polled 2 s',
               h.polled('diagnostics', 'test/edit_test.exs', 2.0), True, ready_by_end=True)
        h.call('diagnostics', 'test/reopen_test.exs')
        time.sleep(1.5)
        h.lua(RULE, 'reopen_test.exs', {'hold_after_error': 1500})
        (h.root / 'test/reopen_test.exs').write_text(BAD.format(name='Reopen'))
        h.case('R6c edit + reopen (version 0 again); parse publication 1.5 s slower, polled 2.5 s',
               h.polled('diagnostics', 'test/reopen_test.exs', 2.5), True, ready_by_end=True)
        h.lua(RULE, 'race2_test.exs', {'hold_after_error': 1500})
        race2 = [h.call('diagnostics', 'test/race2_test.exs')]
        shared = h.root / 'lib/shared.ex'
        shared.write_text(shared.read_text() + '# touched\n')
        race2 += h.polled('diagnostics', 'test/race2_test.exs', 2.5)
        h.case('R7 first touch, then a build from another edit; parse publication 1.5 s slower', race2, True,
               ready_by_end=True)
        h.call('diagnostics', 'test/replay_test.exs')
        time.sleep(1.5)
        h.lua(RULE, 'replay_test.exs', {'replay': True, 'hold_after_error': 1500})
        (h.root / 'test/replay_test.exs').write_text(BAD.format(name='Replay'))
        h.case('R8 edit + reopen with the old version-0 publication re-delivered (simulated in-flight)',
               h.polled('diagnostics', 'test/replay_test.exs', 2.5), True, ready_by_end=True)

        h.call('diagnostics', 'test/twoedits_test.exs')
        time.sleep(1.5)
        twoedits = h.root / 'test/twoedits_test.exs'
        twoedits.write_text(BAD.format(name='Twoedits'))
        repeated = [h.call('diagnostics', 'test/twoedits_test.exs')]
        twoedits.write_text(BAD.format(name='Twoedits').replace('def broken(', 'def broken2('))
        repeated += h.polled('diagnostics', 'test/twoedits_test.exs', 2.0)
        h.case('R9 repeated reload (two on-disk edits back to back)', repeated, True, ready_by_end=True)

        h.call('diagnostics', 'test/gone_test.exs')
        time.sleep(1.5)
        (h.root / 'test/gone_test.exs').unlink()
        h.call('diagnostics', 'test/good_test.exs')  # scan deletes the buffer of the deleted file
        time.sleep(0.5)
        h.lua(RULE, 'gone_test.exs', {'replay': True, 'hold_after_error': 1500})
        (h.root / 'test/gone_test.exs').write_text(BAD.format(name='Gone'))
        h.case('R10 delete + recreate (new buffer), old publication re-delivered, slow parse',
               h.polled('diagnostics', 'test/gone_test.exs', 2.5), True, ready_by_end=True)

        h.call('diagnostics', 'test/conflict_test.exs')
        time.sleep(1.5)
        buffer = h.lua("return vim.fn.bufnr(...)", str(h.root / 'test/conflict_test.exs'))
        h.lua("vim.api.nvim_buf_set_lines(..., -1, -1, false, {'# unsaved'}) return true", buffer)
        (h.root / 'test/conflict_test.exs').write_text(BAD.format(name='Conflict'))
        conflict = [h.call('diagnostics', 'test/conflict_test.exs')]
        h.lua(RULE, 'conflict_test.exs', {'replay': True, 'hold_after_error': 1500})
        h.lua("vim.api.nvim_buf_call(..., function() vim.cmd('edit!') end) return true", buffer)
        conflict += h.polled('diagnostics', 'test/conflict_test.exs', 2.5)
        h.case('R11 unsaved-change conflict, then :edit! reload (version from on_lines), slow parse',
               conflict, True, ready_by_end=True)

        life, path = [], h.root / 'test/life_test.exs'
        by_name = "return vim.fn.bufnr(...)"
        append = "local b, line = ...; vim.api.nvim_buf_set_lines(b, -1, -1, false, {line}); return true"
        life.append(h.call('diagnostics', 'test/life_test.exs'))                      # didOpen
        time.sleep(1.5)
        h.lua(append, h.lua(by_name, str(path)), '# in-editor change')              # didChange
        time.sleep(1.0)
        life += h.polled('diagnostics', 'test/life_test.exs', 0.5)
        h.lua("vim.api.nvim_buf_call(..., function() vim.cmd('edit!') end) return true",
              h.lua(by_name, str(path)))                                            # reload
        time.sleep(1.5)
        life += h.polled('diagnostics', 'test/life_test.exs', 0.5)
        path.unlink()
        h.call('diagnostics', 'test/good_test.exs')                                  # scan deletes buffer
        time.sleep(0.5)
        path.write_text(GOOD.format(name='Life'))
        life += h.polled('diagnostics', 'test/life_test.exs', 1.5)                  # recreate: didOpen
        h.lua(append, h.lua(by_name, str(path)), '  def broken(, do: 1')             # didChange, error
        h.case('R14 lifecycle didOpen, didChange, reload, delete/recreate (clean so far)', life, False,
               ready_by_end=True)
        h.case('R14b then an in-editor change with a syntax error (didChange after recreate)',
               h.polled('diagnostics', 'test/life_test.exs', 2.0), True, ready_by_end=True)

        h.case('R12 .heex first touch must not stay pending',
               h.polled('diagnostics', 'lib/page.html.heex', 1.5), False, ready_by_end=True)
        for name in ('lib/legacy.html.leex', 'lib/card.sface'):
            samples = h.polled('diagnostics', name, 1.5)
            filetype = h.lua("local b = vim.fn.bufnr(...); return b > 0 and vim.bo[b].filetype or ''", str(h.root / name))
            attached = h.lua("local b = vim.fn.bufnr(...); return b > 0 and #vim.lsp.get_clients({ bufnr = b }) or 0",
                             str(h.root / name))
            print(f'MEASURED {name}: filetype {filetype!r}, clients {attached}', flush=True)
            h.case(f'R15 {name} (attached, not parsed) first touch must not stay pending', samples, False,
                   ready_by_end=True, parsed=False)
        h.case('Q first-read hover on never-loaded gamma.ex (quiet window)',
               [h.call('hover', 'lib/gamma.ex', line=3, character=33)], False, measure_only=True)
        (h.root / 'lib/warn.ex').write_text('defmodule Fr.Warn do\n  def unused(x, do: 1\nend\n')
        h.case('R13 open lib file edited to a syntax error (parser/build precedence), polled 3 s',
               h.polled('diagnostics', 'lib/warn.ex', 3.0, gap=0.2), True)

        # Downstream: hooks after an edit while one open document never gets its publication
        # (a lost publication or a crashed parse), then after that document is closed.
        alpha = h.root / 'lib/alpha.ex'
        (h.root / 'lib/warn.ex').write_text('defmodule Fr.Warn do\n  def unused(x), do: 1\nend\n')
        alpha.write_text(alpha.read_text() + '# edited\n')
        h.hook('H3 PostToolUse hook after an edit while lost_test.exs never gets a publication')
        h.hook('H4 Stop hook after H3', event='Stop')
        h.lua("vim.cmd('bwipeout! ' .. vim.fn.bufnr(...)) return true", str(h.root / 'test/lost_test.exs'))
        alpha.write_text(alpha.read_text() + '# edited again\n')
        h.hook('H5 PostToolUse hook after an edit, lost_test.exs closed')
        h.hook('H6 Stop hook after H5', event='Stop')

        h.client.remember()
        h.client.proc.stdin.close()
        h.client.proc.wait(timeout=10)
        results['eof_cleanup'] = poll(lambda: alive(h.client.owned), lambda p: not p, 6)['matched']
    finally:
        h.client.cleanup()
        results['survivors_after_cleanup'] = sorted(alive(h.client.owned))
        base = h.log[0]['t'] if h.log else 0
        results['boundary_log'] = [{**e, 't': round((e['t'] - base) * 1000, 1)} for e in h.log]
        results['cases'] = h.cases
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    sent = {}
    for e in h.log:
        if e['kind'] == 'sent' and e['method'] in ('didOpen', 'didChange'):
            sent.setdefault(e['file'], []).append(e['version'])
    reused = {f: v for f, v in sent.items() if any(b is None or a is None or b <= a for a, b in zip(v, v[1:]))}
    results['sent_versions'] = sent
    results['V1_session_monotonic_versions'] = 'PASS' if not reused else {'FAIL': reused}
    print('V1 per-URI didOpen/didChange versions strictly increasing:',
          'PASS' if not reused else f'FAIL {json.dumps(reused)[:400]}')
    failed = [c['case'] for c in h.cases if c['result'] == 'FAIL'] + ([] if not reused else ['V1'])
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    summary = {'failed': failed, 'eof_cleanup': results.get('eof_cleanup'),
               'survivors_after_cleanup': results.get('survivors_after_cleanup')}
    print(json.dumps(summary, indent=1))
    if summary != {'failed': [], 'eof_cleanup': True, 'survivors_after_cleanup': []}:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
