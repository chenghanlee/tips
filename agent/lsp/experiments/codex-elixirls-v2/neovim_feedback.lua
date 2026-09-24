-- MCP and hooks use the same observation; neither consumes the other's output.
local M = {}
local sync = require('neovim_sync')

local function unavailable(state)
  local retryable = state.status ~= 'conflict'
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
    if semantic and (before.status == 'conflict' or before.status == 'unavailable'
        or before.status == 'sync_error') then return unavailable(before) end
    local result = request(params)
    sync.scan()
    local after = sync.status()
    if after.generation ~= before.generation then
      after.status = 'superseded'
      after.message = 'Files changed during this request. Returned results may be stale; retry the query.'
    elseif after.status ~= 'current' then
      after.message = after.message .. ' Returned results may be incomplete or stale; an empty result does not establish absence.'
    end
    -- The small vv-mcp formatter patch carries this alongside compact results.
    -- Compilation failure or pending work must not hide useful server answers.
    result.feedback = after
    return result
  end
end

return M
