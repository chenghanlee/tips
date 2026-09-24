-- Isolated headless experiment: standard Neovim LSP + a small vv-mcp formatter patch.
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = 'NONE'
vim.opt.autoread = true
vim.lsp.set_log_level('debug')
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
local function record(method, data, ctx)
  table.insert(_G.v2_events, { method = method, data = data, time = vim.uv.hrtime() / 1e9 })
  if automatic then automatic.observe(method, data) end
end

vim.api.nvim_create_autocmd('LspNotify', {
  callback = function(args)
    record('sent:' .. args.data.method, args.data.params)
  end,
})

vim.lsp.config('elixirls', {
  cmd = { vim.env.V2_ELIXIR_LS or '/opt/homebrew/bin/elixir-ls' },
  -- The launcher owns this process group, including a compiler that is still busy.
  detached = false,
  filetypes = { 'elixir', 'eelixir', 'heex', 'surface' },
  root_dir = root,
  settings = {
    elixirLS = { dialyzerEnabled = false, suggestSpecs = false, fetchDeps = false },
  },
  handlers = {
    ['telemetry/event'] = function(_, data, ctx)
      record('telemetry/event', data, ctx)
    end,
    ['window/logMessage'] = function(err, data, ctx, config)
      record('window/logMessage', data, ctx)
      vim.lsp.handlers['window/logMessage'](err, data, ctx, config)
    end,
    ['textDocument/publishDiagnostics'] = function(err, data, ctx, config)
      record('textDocument/publishDiagnostics', data, ctx)
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
  for _, name in ipairs({ 'hover', 'definition', 'references', 'diagnostics' }) do
    operations.get(name).sync_from_disk = true
  end
end

if feedback then feedback.install() end
