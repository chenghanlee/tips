-- MCP and hooks use the same observation; neither consumes the other's output.
local M = {}
local sync = require('neovim_sync')

-- The loaded buffer vv-mcp answered for, found the way vv-mcp finds it (context.lua).
-- nil (workspace operations, or no buffer) makes readiness cover every open document.
local function document_uri(params)
  if params.operation:sub(1, 10) == 'workspace_' or type(params.uri) ~= 'string' then return nil end
  local target = vim.fn.resolve(require('vv-mcp.lsp.normalize').input_path(params.uri))
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.api.nvim_buf_is_loaded(bufnr) and name ~= ''
        and vim.fn.resolve(vim.fs.normalize(name)) == target then
      return vim.uri_from_bufnr(bufnr)
    end
  end
end

local function unavailable(state)
  local retryable = state.retryable ~= false and state.status ~= 'conflict'
  return { error = {
    code = 'elixirls_' .. state.status,
    message = state.message, feedback = state,
    retryable = retryable, retryAfterMs = retryable and 1000 or nil,
  } }
end

function M.install()
  local lsp = require('vv-mcp.lsp')
  local request = lsp.request
  lsp.request = function(params)
    local semantic = vim.tbl_contains({ 'hover', 'definition', 'references' }, params.operation)
    local diagnostics = params.operation == 'diagnostics' or params.operation == 'workspace_diagnostics'
    local symbols = params.operation == 'document_symbols' or params.operation == 'workspace_symbols'
    if not semantic and not diagnostics and not symbols then return request(params) end
    sync.scan()
    local before = sync.status()
    if before.status == 'exited' then return unavailable(before) end
    if semantic and (before.status == 'conflict' or before.status == 'starting'
        or before.status == 'sync_error') then return unavailable(before) end
    local builds = sync.builds
    local result = request(params)
    sync.scan()
    local answer, uri = semantic or params.operation == 'document_symbols', document_uri(params)
    local after = sync.status(uri, answer)
    -- vv-mcp keeps each client's error (request_sync's 'timeout' or the server's error response):
    -- that client gave no answer, which is not an empty one.
    local results = result.results or {}
    local failed = vim.iter(results):filter(function(item) return item.error ~= nil end)
      :map(function(item) return item.client .. ': ' .. item.error end):totable()
    -- exited and conflict are terminal (retryable false): no later status may hide them. A server
    -- exit during a request arrives here as a timeout, since Neovim never fails pending callbacks.
    local terminal = after.retryable == false
    if not terminal and after.generation ~= before.generation then
      after.status = 'superseded'
      after.message = 'Files changed during this request. Returned results may be stale; retry the query.'
    elseif not terminal and #failed > 0 and #failed == #results then
      after.status = 'unanswered'
      after.message = 'No answer (' .. table.concat(failed, '; ') .. '). This is not an empty result; '
        .. 'retry the query.'
    else
      -- Answers skip the quiet window. A build that ended during the request may have changed what
      -- the answer read, even with the same generation (ignored paths), so it is not current.
      if answer and after.status == 'current' and sync.builds ~= builds then
        after.status = 'pending'
        after.message = 'Compilation finished while this request ran; the answer may predate it. '
          .. 'Retry the query.'
      end
      if after.status ~= 'current' then
        after.message = after.message
          .. ' Returned results may be incomplete or stale; an empty result does not establish absence.'
      elseif params.operation == 'document_symbols' and ((sync.documents[uri] or {}).errors or 0) > 0 then
        -- ElixirLS gives unparsable text a dummy AST, so symbols are then empty, not absent. `current`
        -- means this document's version-matched diagnostics were published; they have an error.
        after.message = after.message .. ' This file has errors in its current diagnostics, so its '
          .. 'symbols may be incomplete; an empty result does not establish absence.'
      end
      if #failed > 0 then
        after.message = after.message .. ' No answer from ' .. table.concat(failed, '; ')
          .. '; results may be incomplete.'
      end
    end
    -- The small vv-mcp formatter patch carries this alongside compact results.
    -- Compilation failure or pending work must not hide useful server answers.
    result.feedback = after
    return result
  end
end

return M
