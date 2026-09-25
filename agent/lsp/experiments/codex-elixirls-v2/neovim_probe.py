#!/usr/bin/env python3
"""Exercise unmodified vv-mcp and managed headless Neovim via actual MCP.

RPC is used for observation and explicitly labelled recovery controls only.
--sync-reads enables the adapter's existing disk-sync helper for read operations;
no watcher implementation or readiness workaround is added by the probe.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time

from probe import MCP, alive, prepare, process_table
from inversion_probe import target_text


def nvim_environment(vendor, output, name, sync_reads=False, feedback=False, automatic=False):
    state = output / f'{name}-environment'
    config = state / 'config/nvim'
    config.mkdir(parents=True)
    shutil.copy(Path(__file__).with_name('neovim_init.lua'), config / 'init.lua')
    (config / 'lua').mkdir()
    shutil.copy(Path(__file__).with_name('neovim_feedback.lua'), config / 'lua/neovim_feedback.lua')
    shutil.copy(Path(__file__).with_name('neovim_sync.lua'), config / 'lua/neovim_sync.lua')
    env = {f'XDG_{kind.upper()}_HOME': str(state / kind)
           for kind in ('config', 'data', 'state', 'cache')}
    env.update({
        'PATH': str(vendor / 'nvim-macos-arm64/bin') + os.pathsep + os.environ['PATH'],
        'NVIM_LOG_FILE': str(state / 'nvim.log'),
        'VV_MCP_REGISTRY': str(state / 'registry'),
        'V2_VV_PLUGIN': str(next(vendor.glob('beixiyo-vv-mcp.nvim-*'))),
        'V2_VV_UTILS': str(next(vendor.glob('beixiyo-vv-utils.nvim-*'))),
        'V2_VV_BINARY': str(vendor / 'vv-mcp'),
        'VV_MCP_MANAGED_IDLE_TIMEOUT_MS': '300000',
        'V2_SYNC_READS': '1' if sync_reads else '0',
        'V2_FEEDBACK': '1' if feedback else '0',
        'V2_AUTOMATIC': '1' if automatic else '0',
    })
    return env


class NvimMCP(MCP):
    def __init__(self, vendor, root, output, name, sync_reads=False, feedback=False, automatic=False):
        self.root, self.name, self.counter = root, name, 0
        self.responses = queue.Queue()
        self.log = (output / f'{name}.stderr.log').open('w')
        self.transcript = (output / f'{name}.jsonl').open('w')
        self.owned = {}
        env = os.environ | nvim_environment(vendor, output, name, sync_reads, feedback, automatic)
        self.registry = Path(env['VV_MCP_REGISTRY'])
        self.proc = subprocess.Popen(
            [str(vendor / 'vv-mcp')], cwd=root, env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1,
            start_new_session=True,
        )
        threading.Thread(target=self._read, daemon=True).start()
        self.initialize = self.request('initialize', {
            'protocolVersion': '2024-11-05', 'capabilities': {},
            'clientInfo': {'name': 'tips-neovim-probe', 'version': '1'},
        })
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.tools = self.request('tools/list', {})
        self.nvim = None

    def nav(self, operation, file='lib/caller.ex', **extra):
        return self.call('lsp', operation=operation, uri=str(self.root / file),
                         line=2, character=29, timeoutMs=10000, **extra)

    def rpc(self):
        if self.nvim is None:
            import pynvim
            entries = [json.loads(p.read_text()) for p in self.registry.glob('*.json')]
            if len(entries) != 1:
                raise RuntimeError(f'Expected one managed instance, got {entries}')
            self.instance = entries[0]
            self.nvim = pynvim.attach('socket', path=self.instance['socket'])
        return self.nvim

    def events(self):
        return self.rpc().exec_lua('return _G.v2_events')

    def state(self):
        return self.rpc().exec_lua('''
          local buffers = {}
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
              table.insert(buffers, {
                path = vim.api.nvim_buf_get_name(b), modified = vim.bo[b].modified,
                text = vim.api.nvim_buf_get_lines(b, 0, -1, false),
              })
            end
          end
          local clients = {}
          for _, c in ipairs(vim.lsp.get_clients()) do
            table.insert(clients, { name = c.name, root = c.root_dir,
              capabilities = c.capabilities, server_capabilities = c.server_capabilities })
          end
          return {buffers = buffers, clients = clients, autoread = vim.o.autoread}
        ''')


def poll(fn, predicate, seconds=8):
    start = time.monotonic()
    samples = []
    while True:
        value = fn()
        samples.append({'seconds': round(time.monotonic() - start, 3), 'value': value})
        if predicate(value) or time.monotonic() - start >= seconds:
            return {'matched': bool(predicate(value)), 'samples': samples}
        time.sleep(0.25)


def main():
    # These checks read the opt-in LSP trace; the launched Neovim inherits it.
    os.environ['TIPS_LSP_TRACE'] = '1'
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sync-reads', action='store_true')
    args = parser.parse_args()
    vendor, output = args.vendor.resolve(), args.output.resolve()
    sys.path.insert(0, str(vendor / 'python'))
    process_table()
    output.mkdir(parents=True)
    results, clients = {}, []

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:450], flush=True)

    def contains(marker):
        return lambda value: marker in json.dumps(value)

    try:
        alpha, beta, a_sha, b_sha = prepare(output)
        save('fixture_commits', {'alpha': a_sha, 'beta': b_sha})
        for root in (alpha, beta):
            client = NvimMCP(vendor, root, output, root.name, args.sync_reads)
            clients.append(client)
            save(f'{root.name}_tools', client.tools)
            first = time.monotonic()
            hover = client.nav('hover')
            save(f'{root.name}_first_hover', {'seconds': round(time.monotonic()-first, 3), 'value': hover})
            baseline = poll(lambda: client.nav('hover'), contains(root.name.upper()), 30)
            save(f'{root.name}_baseline', baseline)
            assert baseline['matched'], 'No baseline hover'
            save(f'{root.name}_definition', client.nav('definition'))
            save(f'{root.name}_references', client.nav('references', includeDeclaration=False))
            save(f'{root.name}_initial_state', client.state())
            client.remember()
        a, b = clients
        target = alpha / 'lib/target.ex'
        original_target = target.read_text()
        save('before_unopened_edit', a.state())
        target.write_text(original_target.replace('ALPHA documentation', 'UNOPENED_NEW documentation'))
        save('unopened_edit', poll(lambda: a.nav('hover'), contains('UNOPENED_NEW')))
        save('beta_after_alpha_edit', b.nav('hover'))

        replacement = target.with_suffix('.replacement')
        replacement.write_text(original_target.replace('ALPHA documentation', 'ATOMIC_NEW documentation'))
        replacement.replace(target)
        save('atomic_replacement', poll(lambda: a.nav('hover'), contains('ATOMIC_NEW')))

        extra = alpha / 'lib/extra.ex'
        extra.write_text('defmodule V2Extra do\n  def call, do: V2Target.answer()\nend\n')
        save('created_file_references', poll(lambda: a.nav('references', includeDeclaration=False), contains('extra.ex')))
        extra.unlink()
        save('deleted_file_references', poll(lambda: a.nav('references', includeDeclaration=False),
                                           lambda value: 'extra.ex' not in json.dumps(value)))

        caller = alpha / 'lib/caller.ex'
        original_caller = caller.read_text()
        caller.write_text(original_caller.replace('V2Target.answer()', 'V2Target.missing()', 1))
        save('open_file_external_error', poll(lambda: a.nav('diagnostics'), contains('undefined')))
        save('open_file_state_after_error', a.state())
        save('open_file_hover_after_error', a.nav('hover'))
        save('open_file_repeated_hover', poll(lambda: a.nav('hover'),
             lambda v: not v['isError'] and 'V2Target.answer()' not in json.dumps(v)))
        a.rpc().command('checktime')
        save('checktime_control', poll(lambda: a.nav('diagnostics'), contains('undefined'), 4))
        save('after_checktime_state', a.state())
        if not results['checktime_control']['matched']:
            a.rpc().command('write')
            save('editor_save_control', poll(lambda: a.nav('diagnostics'), contains('undefined')))

        caller.write_text(original_caller)
        save('open_file_external_repair', poll(lambda: a.nav('diagnostics'),
                                              lambda v: 'undefined' not in json.dumps(v)))
        save('open_file_state_after_repair', a.state())
        save('open_file_repaired_hover', poll(lambda: a.nav('hover'), contains('V2Target.answer()')))
        # Explicit control restores the fixture before testing other behaviors.
        a.rpc().command('checktime')
        a.rpc().command('write')
        save('repair_control', poll(lambda: a.nav('diagnostics'),
                                    lambda v: 'undefined' not in json.dumps(v)))

        # Inversion: a second equal-size save while the first compiles.
        mark = len(a.events())
        target.write_text(target_text('NV_OVERLAP_A', delay=1500))
        started = poll(lambda: a.events()[mark:], contains('INVERSION_NV_OVERLAP_A_STARTED'))
        save('overlap_started', started)
        assert started['matched'], 'Slow compile did not start'
        target.write_text(target_text('NV_OVERLAP_B', delay=1500))
        def builds():
            return [e for e in a.events()[mark:] if e['method'] == 'telemetry/event'
                    and e['data'].get('name') == 'build']
        save('overlap_builds', poll(builds, lambda v: len(v) >= 2))
        save('overlap_repeated_hover', poll(lambda: a.nav('hover'), contains('NV_OVERLAP_B'), 4))
        target.write_text(original_target.replace('ALPHA documentation', 'AFTER_OVERLAP documentation'))
        save('overlap_repair', poll(lambda: a.nav('hover'), contains('AFTER_OVERLAP')))

        # Checkout changes both unopened target and the open caller in beta.
        subprocess.run(['git', 'checkout', '--detach', a_sha], cwd=beta,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        save('checkout_hover', poll(lambda: b.nav('hover'), contains('ALPHA')))
        save('checkout_references', b.nav('references', includeDeclaration=False))
        save('checkout_buffer_state', b.state())
        save('alpha_events', a.events())
        save('beta_events', b.events())
        save('separate_build_directories', {
            'alpha': (alpha / '.elixir_ls/build').is_dir(),
            'beta': (beta / '.elixir_ls/build').is_dir(),
        })

        for client in clients:
            client.remember()
            client.proc.stdin.close()
            try:
                client.proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                pass
            shutdown = poll(lambda: alive(client.owned), lambda v: not v, 6)
            save(f'{client.name}_eof_cleanup', shutdown)
            if client is a:
                save('beta_survives_alpha_exit', b.nav('hover'))
        save('completed', True)
    finally:
        for client in clients:
            client.cleanup()


if __name__ == '__main__':
    main()
