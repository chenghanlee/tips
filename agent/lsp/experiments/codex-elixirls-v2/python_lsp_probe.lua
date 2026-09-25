-- One-shot Python LSP verification; no edits or watch registration.
local root = assert(vim.env.CORE_CHECK_ROOT)
local core = root .. '/experiments/codex-elixirls-v2'
local files = { 'bundle.py', 'build_bundle.py', 'neovim_launcher.py', 'neovim_hook.py' }
local buffers = {}
for _, name in ipairs(files) do
  local b = vim.fn.bufadd(core .. '/' .. name)
  vim.fn.bufload(b)
  vim.bo[b].filetype = 'python'
  buffers[name] = b
end
vim.api.nvim_set_current_buf(buffers['build_bundle.py'])
local id = assert(vim.lsp.start({
  name = 'pyright-core-check', cmd = { '/opt/homebrew/bin/pyright-langserver', '--stdio' },
  root_dir = root,
  capabilities = { workspace = { didChangeWatchedFiles = { dynamicRegistration = false } } },
  settings = { python = { analysis = { typeCheckingMode = 'strict', diagnosticMode = 'openFilesOnly' } } },

}))
for _, b in pairs(buffers) do vim.lsp.buf_attach_client(b, id) end
assert(vim.wait(10000, function() return vim.lsp.get_client_by_id(id).initialized end, 50))
local client = assert(vim.lsp.get_client_by_id(id))
local report = { diagnostics = {}, navigation = {} }
for name, b in pairs(buffers) do
  local response = assert(client:request_sync('textDocument/diagnostic', {
    textDocument = { uri = vim.uri_from_bufnr(b) },
  }, 15000, b))
  assert(not response.err and response.result and response.result.kind == 'full', vim.inspect(response))
  report.diagnostics[name] = response.result.items
  assert(#response.result.items == 0, vim.inspect(response.result.items))
end
local b = buffers['build_bundle.py']
local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local row, col
for i, line in ipairs(lines) do
  local match = line:find('build.check_rust()', 1, true)
  if match then row, col = i - 1, match + 5; break end
end
assert(row and col)
local params = { textDocument = { uri = vim.uri_from_bufnr(b) }, position = { line = row, character = col } }
for _, method in ipairs({ 'hover', 'definition', 'references' }) do
  params.context = method == 'references' and { includeDeclaration = true } or nil
  local responses = vim.lsp.buf_request_sync(b, 'textDocument/' .. method, params, 5000)
  local reply = assert(responses and responses[id])
  assert(not reply.err and reply.result and not vim.tbl_isempty(reply.result), vim.inspect(reply))
  report.navigation[method] = reply.result
end
vim.fn.writefile({ vim.json.encode(report) }, assert(vim.env.CORE_CHECK_OUTPUT))
client:stop()
vim.wait(2000, function() local c = vim.lsp.get_client_by_id(id); return not c or c:is_stopped() end)
vim.cmd('qa!')
