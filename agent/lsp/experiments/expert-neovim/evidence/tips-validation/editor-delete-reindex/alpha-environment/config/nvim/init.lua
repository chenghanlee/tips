-- Experiment only: installed Homebrew Expert, standard Neovim LSP, published vv-mcp.
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = 'NONE'
vim.opt.autoread = true
vim.lsp.set_log_level('debug')
vim.opt.rtp:prepend(vim.env.EXPERT_VV_UTILS)
vim.opt.rtp:prepend(vim.env.EXPERT_VV_PLUGIN)

_G.expert_events = {}
local function record(method, data)
  table.insert(_G.expert_events, { method = method, data = data, time = vim.uv.hrtime() / 1e9 })
end
vim.api.nvim_create_autocmd('LspNotify', {
  callback = function(args) record('sent:' .. args.data.method, args.data.params) end,
})
local handlers = {}
for _, method in ipairs({ '$/progress', 'window/logMessage', 'window/showMessage',
  'textDocument/publishDiagnostics', 'client/registerCapability' }) do
  handlers[method] = function(err, data, ctx, config)
    record(method, data)
    if vim.lsp.handlers[method] then
      return vim.lsp.handlers[method](err, data, ctx, config)
    end
  end
end
vim.lsp.config('expert', {
  cmd = { '/opt/homebrew/bin/expert', '--stdio' },
  root_markers = { 'mix.exs', '.git' },
  filetypes = { 'elixir', 'eelixir', 'heex' },
  handlers = handlers,
})
vim.lsp.enable('expert')
require('vv-mcp').setup({ server = { path = vim.env.EXPERT_VV_BINARY, auto_install = false } })
if vim.env.EXPERT_AUTO_SYNC == '1' then require('sync').setup() end
