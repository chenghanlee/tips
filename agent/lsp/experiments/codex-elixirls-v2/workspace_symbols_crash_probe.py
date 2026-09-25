#!/usr/bin/env python3
"""Installed beta: the symbol index survives modules that a build removes while it reads them.

Regression for the missing-module guard in elixirls-workspace-symbols-full-index.patch.
The probe generates a Mix project of 800 modules x 48 documented functions, so the
startup index runs long enough (1.8 s in one run) to overlap the next build.
When the log shows the startup "Indexing...", it renames one module, deletes one, and
renames a function in a third. Each is the last module of one of the first three index
chunks in ebin order (the bundle runs ElixirLS with 4 schedulers, so the index reads 4
chunks). The build of those edits has to finish before the index reaches them.

Verdict in results.json and the exit code:
  0 passed: the build finished inside the index, ElixirLS stayed up, and
    workspace_symbols settled on the current symbols within 12 s.
  1 failed: ElixirLS crashed, or the symbols were still stale after 12 s.
    Without the guard the index task raises UndefinedFunctionError in
    module_info/1. ElixirLS then stops ("ElixirLS has crashed"), the owned
    Neovim exits, and the MCP session ends.
  3 inconclusive: the build finished after the index, so the race did not happen.
Timing-sensitive: a pass is one observed overlap, not deterministic coverage.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from bundle_probe import BundleMCP

LOG = r"""
local first = ...
local out = {}
for i = first, #_G.v2_events do
  local e = _G.v2_events[i]
  local m = e.method == 'window/logMessage' and type(e.data) == 'table' and e.data.message or ''
  if m:find('WorkspaceSymbols', 1, true) or m:find('Compile took', 1, true)
      or m:find('terminating', 1, true) then
    out[#out + 1] = { t = e.time, text = m:sub(1, 300) }
  end
end
return { rows = out, last = #_G.v2_events }
"""
CLIENTS = ("local out = {} for _, c in ipairs(vim.lsp.get_clients()) do "
           "out[#out + 1] = c.name .. ':' .. tostring(c:is_stopped()) end return out")
CRASH = ('UndefinedFunctionError', 'has crashed', 'Owned Neovim exited')


def generate(root, modules, functions):
    (root / 'lib/gen').mkdir(parents=True)
    (root / 'mix.exs').write_text('defmodule Ws.MixProject do\n  use Mix.Project\n\n'
                                  '  def project, do: [app: :ws, version: "0.1.0"]\nend\n')
    (root / '.gitignore').write_text('/_build/\n/.elixir_ls/\n/deps/\n')
    for m in range(1, modules + 1):
        body = [f'defmodule Gen.M{m:03d} do', '  @moduledoc "Generated module."', '']
        for f in range(1, functions + 1):
            body += [f'  @doc "Function {f}."', f'  @spec f{f}(integer()) :: integer()',
                     f'  def f{f}(x), do: x + {f}', '']
        (root / f'lib/gen/m{m:03d}.ex').write_text('\n'.join(body + ['end\n']))
    for command in (['git', 'init', '-q'], ['git', 'add', '.'],
                    ['git', '-c', 'user.name=probe', '-c', 'user.email=probe@localhost',
                     'commit', '-qm', 'fixture']):
        subprocess.run(command, cwd=root, check=True)


def exercise(client, root, save):
    log, cursor = [], [1]

    def read_log():
        got = client.rpc().exec_lua(LOG, cursor[0])
        cursor[0] = int(got['last']) + 1
        log.extend(got['rows'])

    def first(text, after=0.0):
        return next((row['t'] for row in log if text in row['text'] and row['t'] > after), None)

    def names(query):
        result = client.call('lsp', operation='workspace_symbols', uri=str(root / 'lib/gen/m001.ex'),
                             query=query, timeoutMs=10000)['data']
        found = {i.get('name') for items in (result.get('symbols') or {}).values() for i in items}
        return str((result.get('feedback') or {}).get('status')), found

    def source(module):
        return root / f'lib/gen/{module.split(".")[-1].lower()}.ex'

    deadline = time.monotonic() + 900
    while first('Indexing...') is None:  # The first build compiles every module.
        if time.monotonic() > deadline:
            raise RuntimeError('no startup index within 900 s')
        try:
            read_log()
        except Exception:  # noqa: BLE001  The managed Neovim is not registered yet.
            client.nvim = None
        time.sleep(0.005)
    start = first('Indexing...') or 0.0
    ebin = next((root / '.elixir_ls/build').glob('*/lib/ws/ebin'))
    beams = [n for n in os.listdir(ebin) if n.startswith('Elixir.Gen.M') and n.endswith('.beam')]
    size = max(len(beams) // 4, 1)
    renamed, deleted, changed = (beams[size * k + size - 1][len('Elixir.'):-len('.beam')]
                                 for k in range(3))
    text = source(renamed).read_text()
    source(renamed).write_text(
        text.replace(f'defmodule {renamed} do', f'defmodule {renamed}Renamed do'))
    source(deleted).unlink()
    text = source(changed).read_text()
    source(changed).write_text(
        text.replace('def f1(', 'def changed1(').replace('@spec f1(', '@spec changed1('))
    client.rpc().exec_lua("require('neovim_sync').scan()")  # As the PostToolUse hook does.
    edited = time.monotonic()
    save('edits', {'renamed': renamed, 'deleted': deleted, 'changed': changed, 'chunk_size': size})
    queries = (renamed + 'Renamed', renamed, deleted, changed + '.changed1', changed + '.f1')
    samples = []
    while time.monotonic() - edited < 12:
        row: dict = {'s': round(time.monotonic() - edited, 2)}
        try:
            read_log()
            row['clients'] = client.rpc().exec_lua(CLIENTS)
            got = {query: names(query) for query in queries}
            row['statuses'] = sorted({status for status, _ in got.values()})
            row['ok'] = (row['statuses'] == ['current']
                         and renamed + 'Renamed' in got[renamed + 'Renamed'][1]
                         and renamed not in got[renamed][1] and deleted not in got[deleted][1]
                         and changed + '.changed1/1' in got[changed + '.changed1'][1]
                         and changed + '.f1/1' not in got[changed + '.f1'][1])
        except Exception as error:  # noqa: BLE001  Record what the client sees after a crash.
            row['exception'] = repr(error)[:200]
        samples.append(row)
        if sum('exception' in r for r in samples) >= 2:
            break
        time.sleep(1)
    save('samples', samples)
    built, indexed = first('Compile took', start), first('symbols added to index', start)
    save('timeline_s', {'build_end': built and round(built - start, 3),
                        'first_index_end': indexed and round(indexed - start, 3)})
    save('index_log', [row['text'][:120] for row in log if 'WorkspaceSymbols' in row['text']][-6:])
    lsp_log = client.state_dir / 'state/nvim/lsp.log'
    text = lsp_log.read_text(errors='replace') if lsp_log.exists() else ''
    text += Path(client.log.name).read_text()
    crash = [line[:300] for line in text.splitlines() if any(c in line for c in CRASH)]
    save('crash_lines', crash[:6])
    stopped = any('exception' in r or 'true' in str(r.get('clients')) for r in samples)
    if crash or stopped:
        return 'failed'
    if built is None or (indexed is not None and built > indexed):
        return 'inconclusive'
    return 'passed' if samples and samples[-1].get('ok') is True else 'failed'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--modules', type=int, default=800)
    parser.add_argument('--functions', type=int, default=48)
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    os.environ['TIPS_LSP_TRACE'] = '1'  # The managed Neovim records server messages.
    root = output / 'ws'
    generate(root, args.modules, args.functions)
    results, client = {'verdict': 'failed'}, None

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:600], flush=True)

    try:
        client = BundleMCP(bundle, root, output, 'ws')
        save('verdict', exercise(client, root, save))
    finally:
        if client:
            client.remember()
            client.cleanup()
    sys.exit({'passed': 0, 'inconclusive': 3}.get(results['verdict'], 1))


if __name__ == '__main__':
    main()
