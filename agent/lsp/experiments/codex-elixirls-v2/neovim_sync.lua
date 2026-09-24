-- Shared prototype core. Uses Neovim watchers/checktime/diagnostic storage.
-- Build logs are version-specific hints, never a compiler correctness guarantee.
local M = { generation = 0, completed = -1, building = false, queued = false,
  activity = 0, last_output = '', reported_diagnostics = false, reported_pending = false,
  conflicts = {}, files = {}, pending = {}, sync_errors = {}, result = nil,
  last_post_generation = 0, stop_pending = false }
local function now() return vim.uv.hrtime() / 1e9 end

local function snapshot()
  local result = vim.system({ 'git', '-C', M.root, 'ls-files', '-z', '--cached',
    '--others', '--exclude-standard', '--', '*.ex', '*.exs', '*.erl', '*.hrl',
    '*.yrl', '*.xrl', '*.eex', '*.leex', '*.heex', '*.sface' }):wait(1000)
  assert(result.code == 0, 'Cannot enumerate project source files')
  local files = {}
  for _, relative in ipairs(vim.split(result.stdout, '\0', { plain = true, trimempty = true })) do
    local path = M.root .. '/' .. relative
    local stat = vim.uv.fs_lstat(path)
    if relative:sub(1, 4) ~= 'tmp/' and stat and stat.type == 'file' then
      local file = assert(io.open(path, 'rb'))
      files[path] = vim.fn.sha256(file:read('*a'))
      file:close()
    end
  end
  return files
end

local function notify_watched(path, kind)
  local clients = vim.lsp.get_clients({ name = 'elixirls' })
  assert(#clients > 0, 'ElixirLS is not available for ' .. path)
  for _, client in ipairs(clients) do
    assert(client:notify('workspace/didChangeWatchedFiles', {
      changes = { { uri = vim.uri_from_fname(path), type = kind } },
    }), 'ElixirLS did not accept file notification')
  end
end

local function scan()
  local files, changed = snapshot(), {}
  for path, hash in pairs(files) do
    if M.files[path] ~= hash then changed[path] = M.files[path] and 2 or 1 end
  end
  for path in pairs(M.files) do
    if not files[path] then changed[path] = 3 end
  end
  M.files = files
  if next(changed) then
    M.generation = M.generation + 1
    M.activity = now()
    for path, kind in pairs(changed) do M.pending[path] = kind end
  end
  local loaded = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then loaded[vim.api.nvim_buf_get_name(b)] = b end
  end
  for path, kind in pairs(M.pending) do
    local b = loaded[path]
    if not b then
      -- Reconcile disk contents even when a native watcher missed the event.
      -- Keep failed delivery pending; a later scan needs no second disk edit.
      local ok, err = pcall(notify_watched, path, kind)
      M.sync_errors[path], M.conflicts[path] = not ok and tostring(err) or nil, nil
      if ok then M.pending[path] = nil end
    else
      if vim.bo[b].modified then
        M.conflicts[path] = true
      else
        M.conflicts[path] = nil
        local ok, err = pcall(function()
          if not files[path] then
            vim.api.nvim_buf_delete(b, { force = false })
            notify_watched(path, kind)
            return
          end
          vim.api.nvim_buf_call(b, function() vim.cmd('silent checktime') end)
          -- Reload refreshes text with didClose/didOpen; it does not emit a save.
          -- Match the advertised ElixirLS save.includeText capability without
          -- running unrelated BufWritePost hooks or writing the file again.
          assert(not vim.bo[b].modified, 'Buffer changed during reload')
          local ending = vim.bo[b].fileformat == 'dos' and '\r\n'
            or (vim.bo[b].fileformat == 'mac' and '\r' or '\n')
          local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), ending)
            .. (vim.bo[b].endofline and ending or '')
          assert(vim.fn.sha256(text) == files[path], 'Reload did not synchronize ' .. path)
          local clients = vim.lsp.get_clients({ bufnr = b, name = 'elixirls' })
          assert(#clients > 0, 'ElixirLS is not attached to ' .. path)
          for _, client in ipairs(clients) do
            assert(client:notify('textDocument/didSave', {
              textDocument = { uri = vim.uri_from_bufnr(b) }, text = text,
            }, b), 'ElixirLS did not accept save notification')
          end
        end)
        M.sync_errors[path] = not ok and tostring(err) or nil
        if ok then M.pending[path] = nil end
      end
    end
  end
end

function M.scan()
  local ok, err = pcall(scan)
  M.scan_error = not ok and tostring(err) or nil
  return ok
end

function M.observe(method, data)
  if method == 'telemetry/event' and data.name == 'build_queued' then
    M.queued = true
    M.activity = now()
  elseif method == 'window/logMessage' and (data.message or ''):find('Starting build with MIX_ENV:', 1, true) then
    -- Build events are observations, not acknowledgements of exact source bytes.
    M.building, M.queued, M.started = true, false, M.generation
    if M.scan() then M.started = M.generation end
    M.activity = now()
  elseif method == 'telemetry/event' and data.name == 'build' then
    M.building = false
    M.completed = M.started or -1
    M.result = data.properties and data.properties['elixir_ls.build_result']
    M.activity = now()
    M.scan()
  elseif method == 'textDocument/publishDiagnostics' then
    M.activity = now()
  end
end

function M.ready()
  return not M.scan_error and next(M.pending) == nil and next(M.conflicts) == nil
    and not M.building and not M.queued and M.completed == M.generation and now() - M.activity >= 0.15
end

local function server_available()
  for _, client in ipairs(vim.lsp.get_clients({ name = 'elixirls' })) do
    if not client:is_stopped() then return true end
  end
  return false
end

-- One observation shared by MCP and hooks. "current" is an editor build hint,
-- never a replacement for ordinary compilation/tests or a server revision ID.
function M.status()
  local status, message
  if not server_available() then
    status, message = 'unavailable', 'Compiler feedback unavailable: ElixirLS is still starting or has stopped. This is not a clean result.'
  elseif next(M.conflicts) then
    status, message = 'conflict', 'Neovim has unsaved changes; automatic reload was refused.'
  elseif M.scan_error or next(M.sync_errors) then
    status, message = 'sync_error', 'External-edit synchronization is pending after a scan/reload/save failure; it will retry on the next hook or LSP read. Cached results may be stale.'
  elseif not M.ready() then
    status, message = 'pending', 'Compilation pending; diagnostics are not yet current. Retry in about 1 second. This is not a clean result.'
  elseif M.result ~= 'mix_compile_ok' and M.result ~= 'mix_compile_noop' then
    status, message = 'failed', 'Compilation failed; read diagnostics and fix the errors.'
  else
    status, message = 'current', 'Last observed compilation completed; compiler diagnostics are available. Normal compilation/tests remain required.'
  end
  return { status = status, message = message, generation = M.generation, completed = M.completed,
    building = M.building, queued = M.queued }
end

function M.collect(budget_ms, event, expires_at)
  local started = now()
  local function remaining()
    local left = budget_ms - (now() - started) * 1000
    if expires_at then
      -- Unix time is shared across local processes; monotonic elapsed time
      -- independently caps the wait if the wall clock moves backwards.
      local seconds, micros = vim.uv.gettimeofday()
      left = math.min(left, (expires_at - seconds - micros / 1e6) * 1000)
    end
    return math.max(0, math.floor(left))
  end
  local stopping = event == 'Stop'
  if stopping and not M.stop_pending then
    return { message = '', status = 'quiet', generation = M.generation }
  end
  if expires_at and remaining() == 0 then
    return { message = '', status = 'expired', generation = M.generation }
  end
  M.scan()
  local edited = M.generation ~= M.last_post_generation
  if event and not stopping and not edited then budget_ms = 0 end
  if budget_ms > 0 then
    local retry_at = now() + 0.2
    vim.wait(remaining(), function()
      if (M.scan_error or next(M.pending)) and now() >= retry_at then
        M.scan()
        retry_at = now() + 0.2
      end
      return M.ready() or next(M.conflicts) ~= nil
    end, 20)
  end
  -- Native watcher callbacks run while vim.wait yields. A second full snapshot
  -- after exhausting the wait would extend the hook's deadline.
  local lines = {}
  for _, d in ipairs(vim.diagnostic.get()) do
    local path = vim.api.nvim_buf_get_name(d.bufnr)
    if path:sub(1, #M.root + 1) == M.root .. '/' and d.severity <= vim.diagnostic.severity.WARN then
      lines[#lines + 1] = string.format('%s:%d:%d: %s: %s', path:sub(#M.root + 2),
        d.lnum + 1, d.col + 1, d.severity == 1 and 'error' or 'warning', d.message:gsub('\n', ' '):sub(1, 600))
    end
  end
  table.sort(lines)
  local observed = M.status()
  local message, status = observed.message, observed.status
  if event and status == 'pending' then
    message = 'Compilation is still pending. Feedback will be checked after the next eligible tool or at Stop. This is not a clean result.'
  end
  if status == 'current' or status == 'failed' then
    if #lines > 0 then
      status, message = 'diagnostics', table.concat(vim.list_slice(lines, 1, 8), '\n')
      if #lines > 8 then message = message .. '\nAdditional diagnostics omitted.' end
    elseif status == 'failed' then
      status, message = 'failed', 'Compilation failed; no diagnostic details were published.'
    elseif M.reported_diagnostics then
      status, message = 'cleared', 'Previously reported compiler diagnostics cleared after compilation.'
    elseif M.reported_pending then
      status, message = 'completed', 'Compilation completed; no compiler diagnostics are currently reported.'
    else
      status, message = 'quiet', ''
    end
  elseif #lines > 0 then
    message = message .. '\nCached diagnostics (may be stale):\n'
      .. table.concat(vim.list_slice(lines, 1, 8), '\n')
  end
  -- Late duplicate publications can reset the quiet window without a new edit.
  -- An unchanged tool must not replace already-reported feedback with pending.
  if event and not stopping and not edited and status == 'pending' then
    return { message = '', status = status, generation = M.generation, completed = M.completed,
      building = M.building, diagnostic_count = #lines }
  end
  -- Startup/MCP reads observe without consuming public delivery history.
  if not event then
    observed.message, observed.status, observed.diagnostic_count = message, status, #lines
    return observed
  end
  -- Do not consume delivery state after a delayed/expired RPC.
  if expires_at then
    local seconds, micros = vim.uv.gettimeofday()
    if seconds + micros / 1e6 >= expires_at + 0.1 then
      return { message = '', status = 'expired', generation = M.generation }
    end
  end
  -- Consume Stop only after successful collection, never before a fallible scan.
  if stopping then M.stop_pending = false end
  -- Do not lose a previous error merely because a parser briefly clears its cache.
  if status == 'diagnostics' then M.reported_diagnostics = true end
  if status == 'cleared' then M.reported_diagnostics = false end
  if status == 'pending' or status == 'sync_error' then M.reported_pending = true end
  if M.ready() then M.reported_pending = false end
  if event and not stopping then
    if edited or status == 'sync_error' then
      M.stop_pending = status == 'pending' or status == 'sync_error'
    elseif status ~= 'pending' and status ~= 'sync_error' then
      M.stop_pending = false
    end
    M.last_post_generation = M.generation
  end
  local key = tostring(M.generation) .. ':' .. status .. ':' .. message
  local output = message ~= '' and (stopping or key ~= M.last_output) and ('ElixirLS: ' .. message) or ''
  M.last_output = key
  return { message = output, status = status, generation = M.generation, completed = M.completed,
    building = M.building, diagnostic_count = #lines }
end

function M.setup()
  M.root = vim.uv.fs_realpath(vim.fn.getcwd())
  M.files = snapshot()
  vim.api.nvim_create_autocmd('LspNotify', { callback = function(args)
    if args.data.method == 'workspace/didChangeWatchedFiles' then
      vim.schedule(M.scan)
    end
  end })
end

return M
