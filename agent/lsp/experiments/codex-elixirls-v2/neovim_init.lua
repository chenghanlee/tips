-- Isolated headless experiment: standard Neovim LSP + a small vv-mcp formatter patch.
-- First, before vim.lsp loads: stop owned compiler descendants before exit.
require('neovim_owner').setup()
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = 'NONE'
vim.opt.autoread = true
local trace = vim.env.TIPS_LSP_TRACE == '1'
vim.lsp.set_log_level(trace and 'debug' or 'warn')
local root = assert(vim.uv.fs_realpath(vim.fn.getcwd()))
-- Pinned Neovim 0.12.5 private configuration hook. Keep the native watcher;
-- exclude only this worktree's disposable fixtures, not arbitrary ignored files.
local watchfiles = require('vim.lsp._watchfiles')
local P = vim.lpeg.P
watchfiles._poll_exclude_pattern = watchfiles._poll_exclude_pattern
  + P(root .. '/tmp') * (P('/') + -P(1))

vim.opt.rtp:prepend(vim.env.V2_VV_UTILS)
vim.opt.rtp:prepend(vim.env.V2_VV_PLUGIN)

_G.v2_events = {}
local feedback = vim.env.V2_FEEDBACK == '1' and require('neovim_feedback') or nil
local automatic = (vim.env.V2_AUTOMATIC == '1' or feedback) and require('neovim_sync') or nil
if automatic then automatic.setup() end
-- Opt-in trace (TIPS_LSP_TRACE=1): received events here, sent ones in the cmd wrapper below.
local function trace_event(method, data)
  if trace then
    table.insert(_G.v2_events, { method = method, data = data, time = vim.uv.hrtime() / 1e9 })
  end
end
local function record(method, data)
  trace_event(method, data)
  if automatic then automatic.observe(method, data) end
end

local elixir_ls = vim.env.V2_ELIXIR_LS or '/opt/homebrew/bin/elixir-ls'
vim.lsp.config('elixirls', {
  -- Neovim 0.12.5 reuses document versions: a reload reopens at the old version, `:edit!`
  -- reopens at 0, and a recreated buffer counts from 0 again. ElixirLS takes a version to
  -- name one text and ignores a version not above the one it holds. So number every
  -- didOpen/didChange per URI for this connection; a new connection starts again at 1.
  cmd = function(dispatchers, config)
    local rpc = vim.lsp.rpc.start({ elixir_ls }, dispatchers,
      { cwd = config.cmd_cwd, env = config.cmd_env, detached = config.detached })
    local notify, revisions = rpc.notify, {}
    rpc.notify = function(method, params)
      local document = type(params) == 'table' and params.textDocument or nil
      local buffer_version = document and document.version
      if method == 'textDocument/didOpen' or method == 'textDocument/didChange' then
        revisions[document.uri] = (revisions[document.uri] or 0) + 1
        document.version = revisions[document.uri]
      end
      if automatic and document then automatic.sent(method, document, buffer_version) end
      trace_event('sent:' .. method, params)
      return notify(method, params)
    end
    return rpc
  end,
  -- The launcher owns this process group, including a compiler that is still busy.
  detached = false,
  filetypes = { 'elixir', 'eelixir', 'heex', 'surface' },
  root_dir = root,
  on_exit = function(code, signal)
    if automatic then automatic.exited = { code = code, signal = signal } end
    -- Briefly expose the terminal state, then let the launcher's existing child
    -- monitor close MCP and reap the owned process group. No restart supervisor.
    -- During exit, neovim_owner.lua stopped it on purpose; do not quit twice.
    if vim.v.exiting == vim.NIL then vim.defer_fn(function() vim.cmd('cquit 1') end, 500) end
  end,
  settings = {
    -- A root mix.lock change (deps.get/update, a hand edit) starts a new build.
    elixirLS = { dialyzerEnabled = false, suggestSpecs = false, fetchDeps = false,
      additionalWatchedExtensions = { '.lock' } },
  },
  handlers = {
    ['telemetry/event'] = function(_, data)
      record('telemetry/event', data)
    end,
    ['window/logMessage'] = function(err, data, ctx, config)
      record('window/logMessage', data)
      vim.lsp.handlers['window/logMessage'](err, data, ctx, config)
    end,
    ['textDocument/publishDiagnostics'] = function(err, data, ctx, config)
      record('textDocument/publishDiagnostics', data)
      vim.lsp.handlers['textDocument/publishDiagnostics'](err, data, ctx, config)
    end,
  },
})
vim.lsp.enable('elixirls')

require('vv-mcp').setup({
  server = { path = vim.env.V2_VV_BINARY, auto_install = false },
})

-- Experimental use of the adapter's existing disk-sync helper. This operation
-- table is internal, not a documented configuration option or upstream fix.
if vim.env.V2_SYNC_READS == '1' then
  local operations = require('vv-mcp.lsp.operations')
  -- Diagnostics read the cache even when an unsaved buffer prevents disk reload.
  -- The feedback wrapper supplies conflict/freshness status for that cache.
  for _, name in ipairs({ 'hover', 'definition', 'references' }) do
    operations.get(name).sync_from_disk = true
  end
end

if feedback then feedback.install() end
