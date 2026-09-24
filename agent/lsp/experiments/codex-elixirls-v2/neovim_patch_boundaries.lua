-- Fault injection at real Neovim buffer/save boundaries. Run with -l and
-- V3_SOURCE (experiment directory), V3_OUTPUT (fresh disposable directory).
local source, output = vim.env.V3_SOURCE, vim.env.V3_OUTPUT
vim.opt.autoread, vim.opt.swapfile = true, false
package.path = source .. '/?.lua;' .. package.path
vim.fn.mkdir(output, 'p')
local results, failures = {}, 0
local original_call, original_clients = vim.api.nvim_buf_call, vim.lsp.get_clients
local function check(name, fn)
  local ok, value = pcall(fn)
  results[name] = { passed = ok, detail = ok and value or tostring(value) }
  if not ok then failures = failures + 1 end
  vim.api.nvim_buf_call, vim.lsp.get_clients = original_call, original_clients
  vim.cmd('silent! %bwipeout!')
  print(name .. ': ' .. tostring(ok) .. (ok and '' or ' ' .. tostring(value)))
end
local function fixture(name)
  local root = output .. '/' .. name
  vim.fn.mkdir(root .. '/lib', 'p')
  assert(vim.system({ 'git', 'init', '-q', root }):wait().code == 0)
  vim.fn.chdir(root)
  local path = root .. '/lib/target.ex'
  vim.fn.writefile({ '# baseline' }, path)
  vim.cmd.edit(path)
  local m = dofile(source .. '/neovim_sync.lua')
  m.setup()
  local saves = 0
  local client = { is_stopped = function() return false end,
    notify = function() saves = saves + 1; return true end }
  vim.lsp.get_clients = function() return { client } end
  return m, path, client, function() return saves end
end
check('reload_retries_without_new_edit', function()
  local m, path, _, saves = fixture('reload')
  local attempts = 0
  vim.api.nvim_buf_call = function(...)
    attempts = attempts + 1
    if attempts == 1 then error('one reload failure') end
    return original_call(...)
  end
  vim.fn.writefile({ '# changed disk content' }, path)
  pcall(m.scan)
  m.scan()
  assert(attempts == 2 and saves() == 1, 'failed reload was forgotten')
  assert(m.generation == 1, 'retry invented an edit')
  assert(vim.api.nvim_get_current_line() == '# changed disk content')
  return { attempts = attempts, saves = saves(), generation = m.generation }
end)
check('save_retries_without_new_edit', function()
  local m, path, client = fixture('save')
  local attempts = 0
  client.notify = function() attempts = attempts + 1; return attempts > 1 end
  vim.fn.writefile({ '# changed disk content' }, path)
  pcall(m.scan)
  m.scan()
  assert(attempts == 2, 'failed save was forgotten')
  assert(m.generation == 1)
  return { attempts = attempts }
end)
check('opened_deletion_retries_after_buffer_is_gone', function()
  local m, path, client = fixture('delete_retry')
  local attempts = 0
  client.notify = function(_, method, params)
    assert(method == 'workspace/didChangeWatchedFiles')
    assert(params.changes[1].uri == vim.uri_from_fname(path))
    assert(params.changes[1].type == 3)
    attempts = attempts + 1
    return attempts > 1
  end
  assert(vim.uv.fs_unlink(path))
  m.scan()
  assert(m.pending[path] and m.sync_errors[path], 'lost failed deletion')
  assert(not vim.api.nvim_buf_is_loaded(vim.fn.bufnr(path)))
  m.scan()
  assert(attempts == 2 and not next(m.pending) and m.generation == 1)
  return { attempts = attempts }
end)
check('partial_success_is_not_resent', function()
  local m, path, client = fixture('partial')
  local second = m.root .. '/lib/second.ex'
  vim.fn.writefile({ '# second baseline' }, second)
  vim.cmd.edit(second)
  m.scan()
  local counts = {}
  client.notify = function(_, _, params)
    local uri = params.textDocument.uri
    counts[uri] = (counts[uri] or 0) + 1
    return uri ~= vim.uri_from_fname(second) or counts[uri] > 1
  end
  vim.fn.writefile({ '# first changed' }, path)
  vim.fn.writefile({ '# second changed' }, second)
  pcall(m.scan)
  m.scan()
  assert(counts[vim.uri_from_fname(path)] == 1)
  assert(counts[vim.uri_from_fname(second)] == 2)
  return counts
end)
check('hook_retries_within_budget', function()
  local m, path, client = fixture('hook_retry')
  local attempts = 0
  client.notify = function()
    attempts = attempts + 1
    if attempts == 1 then return false end
    m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
    return true
  end
  vim.fn.writefile({ '# changed disk content' }, path)
  local start = vim.uv.hrtime()
  local reply = m.collect(700, 'PostToolUse')
  local ms = (vim.uv.hrtime() - start) / 1e6
  assert(attempts == 2 and m.ready(), 'hook did not retry its failed save')
  assert(ms < 700)
  return { milliseconds = ms, status = reply.status }
end)
check('overlap_does_not_disable_later_wait', function()
  local m, path = fixture('overlap')
  m.building = true
  vim.fn.writefile({ '# edit during build' }, path)
  m.scan()
  m.building, m.completed, m.result, m.activity = false, m.generation, 'mix_compile_ok', 0
  assert(m.ready(), 'ordinary overlap permanently disabled feedback')
  vim.fn.writefile({ '# next edit needs a build' }, path)
  vim.defer_fn(function()
    m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  end, 250)
  local start = vim.uv.hrtime()
  m.collect(700, 'PostToolUse')
  local ms = (vim.uv.hrtime() - start) / 1e6
  assert(ms >= 200 and ms < 700 and m.ready(), 'later edit skipped its wait')
  return { milliseconds = ms }
end)
check('persistent_failure_is_bounded_and_recoverable', function()
  local m, path, client = fixture('persistent')
  client.notify = function() return false end
  vim.fn.writefile({ '# changed disk content' }, path)
  local start = vim.uv.hrtime()
  local reply = m.collect(450, 'PostToolUse')
  local ms = (vim.uv.hrtime() - start) / 1e6
  assert(reply.status == 'sync_error' and ms < 550 and m.stop_pending)
  client.notify = function() return true end
  m.scan()
  assert(m.generation == 1 and not next(m.pending))
  return { milliseconds = ms, status = reply.status }
end)
check('conflict_preserves_buffer_and_diagnostic_access', function()
  local m, path = fixture('conflict')
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function() return { diagnostics = {} } end }
  dofile(source .. '/neovim_feedback.lua').install()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { '# unsaved editor text' })
  vim.fn.writefile({ '# external disk text' }, path)
  local hover = require('vv-mcp.lsp').request({ operation = 'hover' })
  assert(hover.error.code == 'elixirls_conflict')
  assert(vim.api.nvim_get_current_line() == '# unsaved editor text')
  local diagnostics = require('vv-mcp.lsp').request({ operation = 'diagnostics' })
  assert(not diagnostics.error and diagnostics.feedback.status == 'conflict')
  return { preserved = true, qualified_diagnostics = true }
end)
check('qualified_results_and_superseded_request', function()
  local m = fixture('qualified')
  package.loaded.neovim_sync = m
  local calls, change_during_request = 0, false
  package.loaded['vv-mcp.lsp'] = { request = function()
    calls = calls + 1
    if change_during_request then m.generation = m.generation + 1 end
    return { results = { { client = 'elixirls', result = { contents = 'useful docs' } } } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  local request = require('vv-mcp.lsp').request
  local pending = request({ operation = 'hover' })
  assert(not pending.error and pending.results[1].result.contents == 'useful docs')
  assert(pending.feedback.status == 'pending')
  m.completed, m.result, m.activity = m.generation, 'mix_compile_error', 0
  local failed = request({ operation = 'definition' })
  assert(not failed.error and failed.feedback.status == 'failed')
  change_during_request = true
  local superseded = request({ operation = 'references' })
  assert(not superseded.error and superseded.feedback.status == 'superseded')
  return { calls = calls, pending = pending.feedback, failed = failed.feedback,
    superseded = superseded.feedback }
end)
check('queued_work_stays_pending_across_old_build_completion', function()
  local m = fixture('queued')
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  assert(m.ready())
  m.observe('telemetry/event', { name = 'build_queued' })
  m.activity = 0
  assert(m.status().status == 'pending' and not m.building and m.queued)
  m.observe('window/logMessage', { message = 'Starting build with MIX_ENV: test' })
  assert(m.building and not m.queued)
  m.observe('telemetry/event', { name = 'build_queued' })
  m.observe('telemetry/event', { name = 'build', properties = {
    ['elixir_ls.build_result'] = 'mix_compile_ok',
  } })
  m.activity = 0
  assert(m.status().status == 'pending' and m.queued, 'old completion erased newer queued work')
  m.observe('window/logMessage', { message = 'Starting build with MIX_ENV: test' })
  m.observe('telemetry/event', { name = 'build', properties = {
    ['elixir_ls.build_result'] = 'mix_compile_ok',
  } })
  m.activity = 0
  assert(m.ready(), 'successful successor did not restore service')
  return { old_completion_pending = true, successor_current = true }
end)
check('symbol_results_are_qualified_during_startup', function()
  local m = fixture('symbols')
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function()
    return { results = {}, clients = {} }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  vim.lsp.get_clients = function() return {} end
  for _, operation in ipairs({ 'document_symbols', 'workspace_symbols' }) do
    local reply = require('vv-mcp.lsp').request({ operation = operation })
    assert(not reply.error and reply.feedback.status == 'unavailable')
    assert(reply.feedback.message:find('empty result', 1, true))
  end
  vim.lsp.get_clients = function() return { {is_stopped=function() return false end} } end
  local reply = require('vv-mcp.lsp').request({operation='document_symbols'})
  assert(not reply.error and reply.feedback.status == 'pending')
  return true
end)
check('startup_unavailability_allows_retry', function()
  local m = fixture('unavailable')
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function() error('No client to query') end }
  dofile(source .. '/neovim_feedback.lua').install()
  vim.lsp.get_clients = function() return {} end
  local reply = require('vv-mcp.lsp').request({ operation = 'hover' })
  assert(reply.error.code == 'elixirls_unavailable' and reply.error.retryable)
  assert(reply.error.retryAfterMs == 1000)
  return true
end)
check('early_symbol_error_preserves_startup_feedback', function()
  local m = fixture('early_symbols')
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function()
    return { error = { code = 'no_lsp', message = 'No LSP client attached to buffer' } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  local reply = require('vv-mcp.lsp').request({ operation = 'document_symbols' })
  assert(reply.error.code == 'no_lsp')
  assert(reply.feedback.status == 'pending')
  return true
end)
vim.fn.writefile({ vim.json.encode(results) }, output .. '/results.json')
vim.cmd(failures == 0 and 'qa!' or 'cquit 1')
