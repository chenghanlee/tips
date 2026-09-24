-- Experimental adapter: reuse Neovim's registered file watcher and LSP client.
-- Keep installed Expert and published vv-mcp untouched. No filesystem writes.
local M = { pending = {}, applied = {}, conflicts = {}, failures = {}, reindexes = {} }

local function sync(client, uri, kind)
  local path = vim.uri_to_fname(uri)
  local relative = vim.fs.relpath(client.root_dir, path)
  if not relative or relative:match('^%.%.') then return end
  if relative:match('^(deps)/') or relative:match('^_build/')
      or relative:match('^%.expert/') or relative:match('^tmp/') then return end
  if not path:match('%.exs?$') then return end
  local b = vim.fn.bufnr(path)
  if b >= 0 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
    M.conflicts[path] = 'Unsaved Neovim changes; disk synchronization refused'
    return
  end
  M.conflicts[path] = nil
  if kind == 3 and not vim.uv.fs_stat(path) then
    if b >= 0 then vim.api.nvim_buf_delete(b, { force = false }) end
    -- Expert 0.1.10 consumes :deleted internally but gets numeric LSP events.
    -- Its advertised command is the supported recovery path; never mutate its index.
    M.applied[path] = { kind = kind, time = vim.uv.hrtime() / 1e9 }
    return true
  end
  if not vim.uv.fs_stat(path) then return end
  if vim.env.EXPERT_EDIT_SYNC == '1' then
    -- Represent the external edit as an actual buffer edit so Neovim owns the
    -- didChange version and flush ordering. A newly observed file starts in a
    -- normal empty buffer, is attached, then receives the saved disk contents.
    if b < 0 or not vim.api.nvim_buf_is_loaded(b) then
      if b >= 0 then vim.api.nvim_buf_delete(b, { force = false }) end
      b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(b, path)
      vim.bo[b].filetype = vim.filetype.match({ filename = path }) or 'elixir'
    end
    if not vim.lsp.buf_is_attached(b, client.id) then vim.lsp.buf_attach_client(b, client.id) end
    local lines = vim.fn.readfile(path, 'b')
    local eol = lines[#lines] == ''
    if eol then table.remove(lines) end
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].endofline = eol
    vim.bo[b].modified = false
  else
    if b < 0 then b = vim.fn.bufadd(path) end
    vim.fn.bufload(b)
    if not vim.lsp.buf_is_attached(b, client.id) then vim.lsp.buf_attach_client(b, client.id) end
    vim.api.nvim_buf_call(b, function() vim.cmd('silent checktime') end)
  end
  -- Native reload sends close/open. Save notifies that the external tool has
  -- already persisted this content; BufWritePost uses Neovim's capability handling.
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = b, modeline = false })
  M.applied[path] = { kind = kind, time = vim.uv.hrtime() / 1e9 }
  return true
end

function M.setup()
  vim.api.nvim_create_autocmd('LspNotify', {
    callback = function(args)
      if args.data.method ~= 'workspace/didChangeWatchedFiles' then return end
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= 'expert' then return end
      for _, change in ipairs(args.data.params.changes) do
        M.pending[change.uri] = { client = client, kind = change.type }
      end
      vim.schedule(function()
        local batch = M.pending
        M.pending = {}
        local reindex = {}
        for uri, change in pairs(batch) do
          local ok, changed = pcall(sync, change.client, uri, change.kind)
          if not ok then M.failures[uri] = tostring(changed)
          elseif changed and (vim.env.EXPERT_REINDEX_ON_CHANGE == '1'
              or (change.kind == 3 and vim.env.EXPERT_REINDEX_ON_DELETE == '1')) then
            reindex[change.client.id] = change.client
          end
        end
        for _, c in pairs(reindex) do
          c:request('workspace/executeCommand', { command = 'Reindex', arguments = {} },
            function(err, result)
              table.insert(M.reindexes, { error = err, result = result, time = vim.uv.hrtime() / 1e9 })
            end)
        end
      end)
    end,
  })
end

return M
