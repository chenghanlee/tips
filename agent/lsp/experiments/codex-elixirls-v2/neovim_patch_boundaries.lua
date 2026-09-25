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
    assert(not reply.error and reply.feedback.status == 'starting')
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
  assert(reply.error.code == 'elixirls_starting' and reply.error.retryable)
  assert(reply.error.retryAfterMs == 1000)
  return true
end)
check('exited_server_requires_reconnect_without_polling', function()
  local m = fixture('exited')
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function() error('Do not query a dead server') end }
  dofile(source .. '/neovim_feedback.lua').install()
  m.exited = { code = 0, signal = 9 }
  local reply = require('vv-mcp.lsp').request({ operation = 'hover' })
  assert(reply.error.code == 'elixirls_exited' and reply.error.retryable == false)
  assert(reply.error.retryAfterMs == nil and reply.error.message:find('reconnect'))
  local start = vim.uv.hrtime()
  local feedback = m.collect(5000, 'PostToolUse')
  assert(feedback.status == 'exited' and (vim.uv.hrtime() - start) / 1e6 < 300)
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
check('bom_reload_preserves_wire_text', function()
  local m, path, client = fixture('bom')
  vim.fn.writefile({ '\239\187\191# before' }, path)
  vim.cmd('edit!')
  m.scan()
  local text
  client.notify = function(_, method, params)
    if method == 'textDocument/didSave' then text = params.text end
    return true
  end
  vim.fn.writefile({ '\239\187\191# after' }, path)
  m.scan()
  assert(not next(m.sync_errors), vim.inspect(m.sync_errors))
  assert(text == '# after\n', 'BOM must stay in disk representation, not LSP text')
  return true
end)
check('errors_precede_truncated_warnings', function()
  local m, _, _ = fixture('diagnostic_priority')
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { '# first', '# second' })
  vim.api.nvim_set_option_value('modified', false, { buf = b })
  local ns = vim.api.nvim_create_namespace('beta_priority')
  local diagnostics = {}
  for i = 1, 9 do diagnostics[#diagnostics + 1] = { lnum = 0, col = 0, severity = 2, message = 'warning ' .. i } end
  diagnostics[#diagnostics + 1] = { lnum = 1, col = 0, severity = 1, message = 'THE_COMPILE_ERROR' }
  vim.diagnostic.set(ns, b, diagnostics)
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  local reply = m.collect(0)
  vim.diagnostic.reset(ns)
  assert(reply.message:find('THE_COMPILE_ERROR', 1, true), reply.message)
  assert(reply.message:find('2 more diagnostics (0 errors)', 1, true), reply.message)
  return reply.message
end)
check('setup_replaces_and_coalesces_notify_scans', function()
  local first = fixture('first_setup')
  local old, current = 0, 0
  first.scan = function() old = old + 1 end
  local second = fixture('second_setup')
  second.scan = function() current = current + 1 end
  for _ = 1, 10 do
    vim.api.nvim_exec_autocmds('LspNotify', { data = { method = 'workspace/didChangeWatchedFiles' } })
  end
  vim.wait(50, function() return false end)
  assert(old == 0 and current == 1, string.format('old=%d current=%d', old, current))
  return true
end)
check('semantic_current_makes_no_diagnostics_claim', function()
  local m = fixture('semantic_current')
  m.scan()  -- first scan records the fixture files
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function()
    return { results = { { client = 'elixirls', result = { contents = 'docs' } } } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  local request = require('vv-mcp.lsp').request
  for _, operation in ipairs({ 'hover', 'definition', 'references', 'document_symbols' }) do
    local reply = request({ operation = operation })
    assert(reply.feedback.status == 'current', operation .. ' ' .. reply.feedback.status)
    assert(not reply.feedback.message:find('diagnostics', 1, true), operation)
  end
  local diagnostics = request({ operation = 'diagnostics' })
  assert(diagnostics.feedback.message:find('compiler diagnostics are available', 1, true))
  return true
end)
check('unanswered_is_not_an_empty_current_answer', function()
  local m = fixture('unanswered')
  m.scan()  -- first scan records the fixture files
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp'] = { request = function()
    return { results = { { client = 'elixirls', error = 'timeout' } } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  for _, operation in ipairs({ 'hover', 'document_symbols', 'workspace_symbols' }) do
    local reply = require('vv-mcp.lsp').request({ operation = operation })
    assert(reply.feedback.status == 'unanswered' and reply.feedback.retryable, operation)
    assert(reply.feedback.message:find('(elixirls: timeout)', 1, true)
      and reply.feedback.message:find('not an empty result', 1, true), operation)
  end
  return true
end)
check('terminal_status_is_not_hidden', function()
  local m = fixture('terminal')
  m.scan()  -- first scan records the fixture files
  package.loaded.neovim_sync = m
  local during
  package.loaded['vv-mcp.lsp'] = { request = function()
    during()
    return { results = { { client = 'elixirls', error = 'timeout' } } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  local request, seen = require('vv-mcp.lsp').request, {}
  for _, operation in ipairs({ 'hover', 'document_symbols' }) do
    for _, change in ipairs({ false, true }) do
      m.exited, m.completed, m.result, m.activity = nil, m.generation, 'mix_compile_ok', 0
      -- A server exit during the request reaches Neovim's request_sync as a timeout.
      during = function()
        m.exited = { code = 1, signal = 0 }
        if change then m.generation = m.generation + 1 end
      end
      local reply = request({ operation = operation })
      assert(reply.feedback.status == 'exited' and reply.feedback.retryable == false,
        operation .. ' ' .. reply.feedback.status)
      seen[#seen + 1] = reply.feedback.status
    end
  end
  m.exited = nil
  during = function() m.conflicts[m.root .. '/lib/target.ex'] = true end
  local conflict = request({ operation = 'document_symbols' })
  assert(conflict.feedback.status == 'conflict' and conflict.feedback.retryable == false)
  return seen
end)
check('build_during_request_is_not_current', function()
  local m = fixture('build_during')
  m.scan()  -- first scan records the fixture files
  package.loaded.neovim_sync = m
  local build = false
  package.loaded['vv-mcp.lsp'] = { request = function()
    if build then
      -- A watcher-only build (ignored deps/ path): starts and ends, generation unchanged.
      m.observe('window/logMessage', { message = 'Starting build with MIX_ENV: test' })
      m.observe('telemetry/event', { name = 'build', properties = {
        ['elixir_ls.build_result'] = 'mix_compile_ok',
      } })
    end
    return { results = { { client = 'elixirls', result = { contents = 'docs' } } } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  local request = require('vv-mcp.lsp').request
  local idle = request({ operation = 'hover' })
  assert(idle.feedback.status == 'current', idle.feedback.status)
  build = true
  local during = request({ operation = 'hover' })
  assert(during.feedback.generation == idle.feedback.generation, 'generation changed')
  assert(during.feedback.status == 'pending', during.feedback.status)
  assert(during.feedback.message:find('Retry the query', 1, true))
  build = false
  local after = request({ operation = 'hover' })
  assert(after.feedback.status == 'current', after.feedback.status)
  return { idle = idle.feedback.status, during = during.feedback.status, after = after.feedback.status }
end)
check('document_symbols_qualified_by_current_errors', function()
  local m, path = fixture('symbol_errors')
  m.scan()  -- first scan records the fixture files
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp.normalize'] = { input_path = function(input) return input end }
  package.loaded['vv-mcp.lsp'] = { request = function()
    return { results = { { client = 'elixirls', result = {} } } }
  end }
  dofile(source .. '/neovim_feedback.lua').install()
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  local bufnr = vim.fn.bufnr(path)
  local uri = vim.uri_from_bufnr(bufnr)
  m.documents[uri] = { sent = 1, buffer_version = vim.lsp.util.buf_versions[bufnr], bufnr = bufnr }
  local request = require('vv-mcp.lsp').request
  local function publish(version, severity)
    m.observe('textDocument/publishDiagnostics', { uri = uri, version = version,
      diagnostics = severity and { { severity = severity, message = 'x' } } or {} })
    m.activity = 0
  end
  local function symbols() return request({ operation = 'document_symbols', uri = path }).feedback end
  publish(1, 1)
  local broken = symbols()
  assert(broken.status == 'current' and broken.message:find('has errors', 1, true), broken.message)
  m.documents[uri].sent = 2  -- repair sent; its publication has not arrived
  local waiting = symbols()
  assert(waiting.status == 'pending' and not waiting.message:find('has errors', 1, true))
  publish(1, 1)  -- a late publication for the old version is not reused
  assert(symbols().status == 'pending')
  publish(2, nil)
  local repaired = symbols()
  assert(repaired.status == 'current' and not repaired.message:find('has errors', 1, true))
  publish(2, 2)  -- a warning is not an error
  assert(not symbols().message:find('has errors', 1, true))
  publish(2, 1)
  local hover = request({ operation = 'hover', uri = path }).feedback
  assert(hover.status == 'current' and not hover.message:find('has errors', 1, true))
  return { broken = broken.status, waiting = waiting.status, repaired = repaired.status }
end)
check('client_errors_are_not_empty_answers', function()
  local m, path = fixture('client_errors')
  m.scan()  -- first scan records the fixture files
  package.loaded.neovim_sync = m
  package.loaded['vv-mcp.lsp.normalize'] = { input_path = function(input) return input end }
  local reply
  package.loaded['vv-mcp.lsp'] = { request = function() return vim.deepcopy(reply) end }
  dofile(source .. '/neovim_feedback.lua').install()
  m.completed, m.result, m.activity = m.generation, 'mix_compile_ok', 0
  local request = require('vv-mcp.lsp').request
  local function ask(answers)
    reply = { results = answers }
    return request({ operation = 'references', uri = path, line = 1, character = 1 }).feedback
  end
  local empty = ask({ { client = 'elixirls' } })
  assert(empty.status == 'current' and not empty.message:find('No answer', 1, true), empty.message)
  -- vv-mcp formats a server error response with Neovim's own formatter.
  local invalid = vim.lsp.rpc.format_rpc_error({ code = -32602, message = 'file:///x' })
  local refused = ask({ { client = 'elixirls', error = invalid } })
  assert(refused.status == 'unanswered' and refused.message:find(invalid, 1, true), refused.message)
  local down = vim.lsp.rpc.format_rpc_error({ code = -32603, message = 'down' })
  local partial = ask({ { client = 'elixirls', result = { { uri = path } } }, { client = 'other', error = down } })
  assert(partial.status == 'current'
    and partial.message:find('No answer from other: ' .. down .. '; results may be incomplete', 1, true),
    partial.status .. ': ' .. partial.message)
  return { empty = empty.status, refused = refused.status, partial = partial.status }
end)

vim.fn.writefile({ vim.json.encode(results) }, output .. '/results.json')
vim.cmd(failures == 0 and 'qa!' or 'cquit 1')
