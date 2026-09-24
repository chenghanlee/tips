"""Reused published vv-mcp managed-instance path; RPC is for test observation."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time

from probe_support import MCP, alive

VENDOR = Path('/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/neovim-vendor')


def environment(output, name):
    state = output / f'{name}-environment'
    config = state / 'config/nvim'
    config.mkdir(parents=True)
    shutil.copy(Path(__file__).with_name('init.lua'), config / 'init.lua')
    (config / 'lua').mkdir()
    shutil.copy(Path(__file__).with_name('sync.lua'), config / 'lua/sync.lua')
    env = {f'XDG_{kind.upper()}_HOME': str(state / kind)
           for kind in ('config', 'data', 'state', 'cache')}
    env.update({
        'PATH': str(VENDOR / 'nvim-macos-arm64/bin') + os.pathsep + os.environ['PATH'],
        'NVIM_LOG_FILE': str(state / 'nvim.log'),
        'VV_MCP_REGISTRY': str(state / 'registry'),
        'EXPERT_VV_PLUGIN': str(next(VENDOR.glob('beixiyo-vv-mcp.nvim-*'))),
        'EXPERT_VV_UTILS': str(next(VENDOR.glob('beixiyo-vv-utils.nvim-*'))),
        'EXPERT_VV_BINARY': str(VENDOR / 'vv-mcp'),
        'VV_MCP_MANAGED_IDLE_TIMEOUT_MS': '300000',
        'ERL_FLAGS': '+S 4:4',
    })
    return env


class Session(MCP):
    def __init__(self, root, output, name, extra_env=None):
        self.root, self.name, self.counter = root, name, 0
        self.responses, self.owned = queue.Queue(), {}
        self.log = (output / f'{name}.stderr.log').open('w')
        self.transcript = (output / f'{name}.jsonl').open('w')
        env = os.environ | environment(output, name) | (extra_env or {})
        self.registry = Path(env['VV_MCP_REGISTRY'])
        self.proc = subprocess.Popen([str(VENDOR / 'vv-mcp')], cwd=root, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.log, text=True, bufsize=1, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.initialize = self.request('initialize', {
            'protocolVersion': '2024-11-05', 'capabilities': {},
            'clientInfo': {'name': 'tips-installed-expert-neovim', 'version': '1'},
        })
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.tools = self.request('tools/list', {})
        self.nvim = None

    def nav(self, operation, file='lib/caller.ex', line=2, character=29, **extra):
        return self.call('lsp', operation=operation, uri=str(self.root / file),
                         line=line, character=character, timeoutMs=10000, **extra)

    def rpc(self):
        if self.nvim is None:
            sys.path.insert(0, str(VENDOR / 'python'))
            import pynvim
            entries = [json.loads(p.read_text()) for p in self.registry.glob('*.json')]
            if len(entries) != 1:
                raise RuntimeError(f'Expected one Neovim instance: {entries}')
            self.instance = entries[0]
            self.nvim = pynvim.attach('socket', path=self.instance['socket'])
        return self.nvim

    def events(self):
        return self.rpc().exec_lua('return _G.expert_events')

    def state(self):
        return self.rpc().exec_lua('''
          local buffers, clients = {}, {}
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
              table.insert(buffers, {path = vim.api.nvim_buf_get_name(b),
                modified = vim.bo[b].modified, text = vim.api.nvim_buf_get_lines(b, 0, -1, false)})
            end
          end
          for _, c in ipairs(vim.lsp.get_clients()) do
            table.insert(clients, {name = c.name, root = c.root_dir, cmd = c.config.cmd,
              initialized = c.initialized, server_capabilities = c.server_capabilities})
          end
          return {buffers = buffers, clients = clients, autoread = vim.o.autoread}
        ''')

    def trace_engine_supervisor(self, output):
        # Expert's public debug command and OTP's built-in trace; no source patch.
        # Keep the runtime cookie out of artifacts and command arguments.
        response = self.rpc().exec_lua('''
          local c = vim.lsp.get_clients({name='expert'})[1]
          local level = vim.lsp.log.get_level()
          vim.lsp.log.set_level('OFF')
          local ok, reply = pcall(c.request_sync, c, 'workspace/executeCommand',
            {command='connectionDetails', arguments={}}, 5000)
          vim.lsp.log.set_level(level)
          if not ok then error('connectionDetails failed') end
          if not reply or not reply.result then error('No connectionDetails result') end
          return reply.result
        ''')
        trace_path = str(output / 'engine-supervisor.trace')
        env = os.environ | {
            'ERL_FLAGS': '+S 4:4', 'EXPERT_PARENT_PORT': str(response['port']),
            'ERL_LIBS': str(Path(response['epmdEbinPath']).parent.parent),
            'PROBE_PARENT_NODE': response['nodeName'],
            'PROBE_RUNTIME_COOKIE': response['cookie'], 'PROBE_TRACE_FILE': trace_path,
        }
        code = '''
          parent = System.fetch_env!("PROBE_PARENT_NODE") |> String.to_atom()
          Node.set_cookie(System.fetch_env!("PROBE_RUNTIME_COOKIE") |> String.to_atom())
          true = Node.connect(parent)
          engine = :erpc.call(parent, Node, :list, [])
            |> Enum.find(&String.starts_with?(Atom.to_string(&1), "expert-project-"))
          result = :erpc.call(parent, :erpc, :call,
            [engine, :sys, :log_to_file, [XPEngine.Supervisor, System.fetch_env!("PROBE_TRACE_FILE")]])
          IO.inspect(result, label: "supervisor_trace")
        '''
        command = ['elixir', '--erl',
                   f"-start_epmd false -epmd_module {response['epmdModule']} -connect_all false",
                   '--name', f'expert-observer-{os.getpid()}@127.0.0.1', '-e', code]
        with (output / 'trace-setup.log').open('w') as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=20)
        if result.returncode:
            raise RuntimeError('Supervisor trace setup failed; inspect trace-setup.log')
        return {'trace': trace_path, 'setup_exit_code': result.returncode}

    def close_stdin(self):
        self.remember()
        if self.nvim:
            self.nvim.close()
        self.proc.stdin.close()
        self.proc.wait(timeout=15)
        deadline = time.monotonic() + 10
        while alive(self.owned) and time.monotonic() < deadline:
            time.sleep(0.2)
        return {'exit_code': self.proc.returncode, 'owned': self.owned, 'remaining': alive(self.owned)}


def poll(fn, predicate, seconds=10):
    started, samples = time.monotonic(), []
    while True:
        value = fn()
        samples.append({'seconds': round(time.monotonic() - started, 3), 'value': value})
        if predicate(value) or time.monotonic() - started >= seconds:
            return {'matched': bool(predicate(value)), 'samples': samples}
        time.sleep(0.5)
