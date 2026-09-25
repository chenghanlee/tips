#!/usr/bin/env python3
"""Real MCP/hook reconciliation when native file notifications are unavailable."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from neovim_hook_inversion_probe import LaunchedMCP
from neovim_probe import poll
from probe import prepare


def main():
    # These checks read the opt-in LSP trace; the launched Neovim inherits it.
    os.environ['TIPS_LSP_TRACE'] = '1'
    p = argparse.ArgumentParser()
    p.add_argument('--vendor', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--server-source', type=Path)
    p.add_argument('--toolchain', type=Path)
    p.add_argument('--bundle', type=Path)
    p.add_argument('--slow-budget', action='store_true')
    args = p.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    if args.bundle:
        args.bundle = args.bundle.resolve()
        os.environ.update({'PATH': str(args.bundle / 'toolchain/bin') + os.pathsep + os.environ['PATH'],
                           'ERL_FLAGS': '+S 4:4'})
    else:
        os.environ.update({'ELS_LOCAL': '1', 'ELS_INSTALL_PREFIX': str(args.server_source.resolve() / 'scripts'),
            'MIX_INSTALL_DIR': str(args.server_source.resolve().parent / 'install-cache'),
            'HEX_HOME': str(args.server_source.resolve().parent / 'hex-home'),
            'PATH': str(args.toolchain.resolve() / 'bin') + os.pathsep + os.environ['PATH'], 'ERL_FLAGS': '+S 4:4'})
    sys.path.insert(0, str(vendor / 'python'))
    import pynvim
    root, _, _, _ = prepare(output)
    target = root / 'lib/target.ex'
    target.write_text('''defmodule V2Target do
  @external_resource Path.expand("value.heex", __DIR__)
  @value (case File.read(@external_resource) do
    {:ok, text} -> text
    {:error, :enoent} -> "missing"
  end)
  IO.puts("RESOURCE_READ_#{@value}")
  Process.sleep(800)
  def answer, do: @value
end
''')
    resource = root / 'lib/value.heex'
    resource.write_text('aa')
    (root / 'lib/caller.ex').write_text('''defmodule V2Caller do
  @value V2Target.answer()
  def call_1, do: @value
end
''')
    (root / 'acceptance.exs').write_text('''ExUnit.start()
defmodule ReconcileTest do
  use ExUnit.Case, async: true
  test "resource owner matches saved state" do
    assert V2Target.answer() == System.fetch_env!("EXPECTED")
  end
  test "compile-time caller matches saved state" do
    assert V2Caller.call_1() == System.fetch_env!("EXPECTED")
  end
end
''')
    env = os.environ | {'MIX_ENV': 'test', 'MIX_BUILD_PATH': str(root / '.elixir_ls/build/test')}
    formatted = subprocess.run(['unbuffer', 'mix', 'format', 'lib/target.ex', 'lib/caller.ex', 'acceptance.exs'],
        cwd=root, env=env, capture_output=True, text=True, timeout=30)
    assert formatted.returncode == 0, formatted.stdout + formatted.stderr
    results, client, rpc = {}, None, None
    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:500], flush=True)
    def hook():
        start = time.monotonic()
        hook_path = args.bundle / 'adapter/neovim_hook.py' if args.bundle else Path(__file__).with_name('neovim_hook.py')
        r = subprocess.run([sys.executable, str(hook_path),
            '--vendor', str(vendor), '--registry', str(client.registry), '--workspace', str(root)],
            input=json.dumps({'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch'}),
            capture_output=True, text=True, timeout=6)
        assert r.returncode == 0, r.stderr
        return {'seconds': time.monotonic() - start, 'feedback': json.loads(r.stdout)}
    def accept(label, expected):
        r = subprocess.run(['unbuffer', 'mix', 'run', '--no-start', '--no-compile', 'acceptance.exs'],
            cwd=root, env=env | {'EXPECTED': expected}, capture_output=True, text=True, timeout=30)
        (output / (label + '.log')).write_text(r.stdout + r.stderr)
        save(label, {'exit': r.returncode, 'expected': expected})
        return r.returncode == 0
    try:
        if args.bundle:
            from bundle_probe import BundleMCP
            client = BundleMCP(args.bundle, root, output, 'reconcile')
        else:
            client = LaunchedMCP(vendor, root, output, 'reconcile')
        entry, = [json.loads(p.read_text()) for p in client.registry.glob('*.json')]
        rpc = pynvim.attach('socket', path=entry['socket'])
        assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 15)['matched']
        assert accept('baseline', 'aa')
        rpc.exec_lua('''
          local c = vim.lsp.get_clients({name='elixirls'})[1]
          require('vim.lsp._watchfiles').cancel(c.id)
          _G.saved_notify, _G.watch_attempts = c.notify, 0
          c.notify = function(self, method, ...)
            if method == 'workspace/didChangeWatchedFiles' then
              _G.watch_attempts = _G.watch_attempts + 1
              if _G.watch_attempts == 1 then return false end
            end
            return _G.saved_notify(self, method, ...)
          end
        ''')
        loaded = rpc.exec_lua('return vim.api.nvim_buf_is_loaded(vim.fn.bufnr(...))', str(resource))
        assert not loaded, 'Resource unexpectedly opened'
        old = resource.stat()
        resource.write_text('bb')
        os.utime(resource, ns=(old.st_atime_ns, old.st_mtime_ns))
        save('unopened_preserved_hook', hook())
        assert accept('unopened_preserved_acceptance', 'bb')
        attempts = rpc.exec_lua('return _G.watch_attempts')
        save('retry_attempts', attempts)
        assert attempts == 2
        resource.unlink()
        save('delete_hook', hook())
        assert accept('delete_acceptance', 'missing')
        resource.write_text('cc')
        save('recreate_hook', hook())
        assert accept('recreate_acceptance', 'cc')
        # Another write after an earlier event was accepted while its build runs.
        resource.write_text('dd')
        rpc.exec_lua("require('neovim_sync').scan()")
        seen = poll(lambda: rpc.exec_lua('return _G.v2_events'), lambda es: any(
            'RESOURCE_READ_dd' in e.get('data', {}).get('message', '') for e in es), 5)
        assert seen['matched']
        resource.write_text('ee')
        save('edit_during_build_hook', hook())
        assert accept('edit_during_build_acceptance', 'ee')
        if args.slow_budget:
            target.write_text(target.read_text().replace('Process.sleep(800)', 'Process.sleep(8000)'))
            resource.write_text('ff')
            save('slow_hook', hook())
            assert results['slow_hook']['seconds'] < 5.05
            assert 'pending' in json.dumps(results['slow_hook']).lower()
            save('unchanged_hook', hook())
            assert results['unchanged_hook']['seconds'] < 0.7
            assert poll(lambda: rpc.exec_lua("return require('neovim_sync').ready()"), bool, 25)['matched']
            save('later_hook', hook())
            assert accept('slow_acceptance', 'ff')
        save('events', rpc.exec_lua('return _G.v2_events'))
        save('completed', True)
    finally:
        if rpc: rpc.close()
        if client: client.cleanup()


if __name__ == '__main__':
    main()
