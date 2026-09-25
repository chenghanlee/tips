-- Shared prototype core. Uses Neovim watchers/checktime/diagnostic storage.
-- Build logs are version-specific hints, never a compiler correctness guarantee.
local M = { generation = 0, completed = -1, building = false, queued = false,
  activity = 0, last_output = '', reported_diagnostics = false, reported_pending = false,
  conflicts = {}, files = {}, pending = {}, sync_errors = {}, result = nil,
  last_post_generation = 0, stop_pending = false, documents = {}, builds = 0 }
local function now() return vim.uv.hrtime() / 1e9 end

-- Open documents ElixirLS parses (0.31.1 parser.ex should_parse?; Neovim's language ID is the
-- filetype). Only these get a publication naming their version; the rest never would.
local function parsed(document)
  for _, suffix in ipairs({ '.ex', '.exs', '.eex', '.heex' }) do
    if document.uri:sub(-#suffix) == suffix then return true end
  end
  return document.languageId == 'elixir'
end

-- Build readiness says nothing about a document ElixirLS has not parsed yet. A document is
-- published once ElixirLS publishes diagnostics naming the revision last sent for it, and that
-- revision carried the buffer's current text. `buffer_version` is Neovim's own version in the
-- notification; a buffer edit changes `util.buf_versions` at once but sends didChange 150 ms later.
function M.sent(method, document, buffer_version)
  local uri = document.uri
  if method == 'textDocument/didClose' then
    M.documents[uri] = nil
  elseif method == 'textDocument/didOpen' and parsed(document) then
    -- Neovim sends didOpen for a loaded buffer, so this finds it and never creates one.
    M.documents[uri] = { sent = document.version, buffer_version = buffer_version,
      bufnr = vim.uri_to_bufnr(uri) }
  elseif method == 'textDocument/didChange' and M.documents[uri] then
    M.documents[uri].sent, M.documents[uri].buffer_version = document.version, buffer_version
  end
end

-- Files still waiting for diagnostics of their current text, for one document's URI or every
-- open document when nil. `util.buf_versions` is @nodoc in the pinned Neovim 0.12.5; only read here.
local function unpublished(uri)
  local names = {}
  for key, document in pairs(uri and { [uri] = M.documents[uri] } or M.documents) do
    if document.published ~= document.sent
        or vim.lsp.util.buf_versions[document.bufnr] ~= document.buffer_version then
      local path = vim.uri_to_fname(key)
      names[#names + 1] = path:sub(1, #M.root + 1) == M.root .. '/' and path:sub(#M.root + 2) or path
    end
  end
  table.sort(names)
  return names
end

local function snapshot()
  local result = vim.system({ 'git', '-C', M.root, 'ls-files', '-z', '--cached',
    '--others', '--exclude-standard', '--', '*.ex', '*.exs', '*.erl', '*.hrl',
    '*.yrl', '*.xrl', '*.eex', '*.leex', '*.heex', '*.sface', 'mix.lock' }):wait(1000)
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
          -- LSP text omits a UTF-8 BOM; compare the original disk representation.
          local disk_text = vim.bo[b].bomb and ('\239\187\191' .. text) or text
          assert(vim.fn.sha256(disk_text) == files[path], 'Reload did not synchronize ' .. path)
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
  elseif method == 'telemetry/event' and (data.name == 'build' or data.name == 'build_error') then
    -- A crashed build worker (dependency compile, deps check, compile_env) sends
    -- build_error and then its mix.exs diagnostic, never build. It is a finished,
    -- failed build; a build queued meanwhile stays queued.
    M.building = false
    -- Counts every observed build end. A build of paths the scanner ignores (deps/, git-ignored
    -- sources) runs without a new generation; only this count shows it happened.
    M.builds = M.builds + 1
    M.completed = M.started or -1
    M.result = data.name == 'build_error' and 'build_error'
      or (data.properties and data.properties['elixir_ls.build_result'])
    M.activity = now()
    M.scan()
  elseif method == 'textDocument/publishDiagnostics' then
    local document = M.documents[data.uri]
    if document and data.version == document.sent then
      document.published = data.version
      -- Errors in this document's diagnostics for the version last sent; an older version's
      -- publication never sets this.
      document.errors = #vim.tbl_filter(function(d) return d.severity == 1 end, data.diagnostics or {})
    end
    M.activity = now()
  end
end

-- The 150 ms quiet window covers a real race: ElixirLS sends the `build` telemetry from the build
-- process and publishes build diagnostics from the server after its build_finished cast, so their
-- order is scheduling, not design. Measured on r22: publication first in 30/30 builds, by
-- 0.2-1.5 ms (first-read/build_order_probe.py). Every publication restarts it. It guards cached
-- diagnostics only: `settle == false` skips it for answers computed from ElixirLS's current text
-- and the compiled code, which the build events above already cover.
local function built(settle)
  return not M.exited and not M.scan_error and next(M.pending) == nil and next(M.conflicts) == nil
    and not M.building and not M.queued and M.completed == M.generation
    and (settle == false or now() - M.activity >= 0.15)
end

function M.ready(uri) return built() and #unpublished(uri) == 0 end

-- A client that stopped before its exit report is a dead server, not a start:
-- a crashed server's orphaned programs can hold its pipes open for a while.
local function server_state()
  local clients = vim.lsp.get_clients({ name = 'elixirls' })
  for _, client in ipairs(clients) do
    if not client:is_stopped() then return 'running' end
  end
  return #clients > 0 and 'stopped' or 'starting'
end

-- One observation shared by MCP and hooks. "current" is an editor build hint,
-- never a replacement for ordinary compilation/tests or a server revision ID.
-- `uri` limits publication readiness to the one document an answer covers. `semantic` answers
-- (hover, definition, references, document_symbols) read no published diagnostics.
function M.status(uri, semantic)
  local status, message, waiting
  local state = server_state()
  local is_built, names = built(not semantic), unpublished(uri)
  if M.exited or state == 'stopped' then
    local how = M.exited and string.format(' (code %d, signal %d)', M.exited.code, M.exited.signal) or ''
    status, message = 'exited', 'ElixirLS exited' .. how
      .. '. Restart the coding client in this worktree to reconnect. This is not a clean result.'
  elseif state == 'starting' then
    status, message = 'starting', 'ElixirLS is still starting. Retry in about 1 second. This is not a clean result.'
  elseif next(M.conflicts) then
    status, message = 'conflict', 'Neovim has unsaved changes; automatic reload was refused.'
  elseif M.scan_error or next(M.sync_errors) then
    status, message = 'sync_error', 'External-edit synchronization is pending after a scan/reload/save failure; '
      .. 'it will retry on the next hook or LSP read. Cached results may be stale.'
  elseif not is_built then
    status, message = 'pending', 'Compilation pending; diagnostics are not yet current. '
      .. 'Retry in about 1 second. This is not a clean result.'
  elseif #names > 0 then
    -- The build finished; only document publications are missing.
    waiting = table.concat(vim.list_slice(names, 1, 3), ', ')
      .. (#names > 3 and string.format(' and %d more', #names - 3) or '')
    status, message = 'pending', 'Diagnostics for ' .. waiting .. ' have not arrived from ElixirLS yet. '
      .. 'Retry in about 1 second. This is not a clean result.'
  elseif M.result == 'build_error' then
    status, message = 'failed', 'Compilation stopped before file diagnostics (dependency, lock or config). '
      .. 'Run the normal mix compile for the exact file and line.'
  elseif M.result ~= 'mix_compile_ok' and M.result ~= 'mix_compile_noop' then
    status, message = 'failed', 'Compilation failed; read diagnostics and fix the errors.'
  else
    -- Semantic answers skip the quiet window, so they make no claim about diagnostics.
    status, message = 'current', 'Last observed compilation completed'
      .. (semantic and '. ' or '; compiler diagnostics are available. ') .. 'Normal compilation/tests remain required.'
  end
  return { status = status, message = message, generation = M.generation, completed = M.completed,
    building = M.building, queued = M.queued, retryable = status ~= 'exited' and status ~= 'conflict',
    waiting = waiting }
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
      return M.exited ~= nil or server_state() == 'stopped' or M.ready() or next(M.conflicts) ~= nil
    end, 20)
  end
  -- Native watcher callbacks run while vim.wait yields. A second full snapshot
  -- after exhausting the wait would extend the hook's deadline.
  local diagnostics = {}
  for _, d in ipairs(vim.diagnostic.get()) do
    local path = vim.api.nvim_buf_get_name(d.bufnr)
    if path:sub(1, #M.root + 1) == M.root .. '/' and d.severity <= vim.diagnostic.severity.WARN then
      diagnostics[#diagnostics + 1] = { path = path:sub(#M.root + 2), diagnostic = d }
    end
  end
  table.sort(diagnostics, function(a, b)
    local x, y = a.diagnostic, b.diagnostic
    if x.severity ~= y.severity then return x.severity < y.severity end
    if a.path ~= b.path then return a.path < b.path end
    if x.lnum ~= y.lnum then return x.lnum < y.lnum end
    if x.col ~= y.col then return x.col < y.col end
    return x.message < y.message
  end)
  local lines, omitted_errors = {}, 0
  for i, item in ipairs(diagnostics) do
    local d = item.diagnostic
    -- Cut at 600 bytes, never inside a UTF-8 character: a partial character breaks the hook's JSON.
    local text = d.message:gsub('\n', ' ')
    if #text > 600 then text = text:sub(1, 600 + vim.str_utf_start(text, 601)) end
    lines[i] = string.format('%s:%d:%d: %s: %s', item.path,
      d.lnum + 1, d.col + 1, d.severity == 1 and 'error' or 'warning', text)
    if i > 8 and d.severity == 1 then omitted_errors = omitted_errors + 1 end
  end
  local rendered = table.concat(vim.list_slice(lines, 1, 8), '\n')
  if #lines > 8 then
    rendered = rendered .. string.format('\n%d more diagnostics (%d errors).', #lines - 8, omitted_errors)
  end
  local observed = M.status()
  local message, status = observed.message, observed.status
  if event and status == 'pending' then
    -- Stop consumes the pending state: only a later tool checks again.
    local cause = observed.waiting and ('Diagnostics for ' .. observed.waiting .. ' have not arrived from ElixirLS')
      or 'Compilation is still pending'
    message = stopping and cause .. ', so validation is unfinished. This is not a clean result.'
      or cause .. '. Feedback will be checked after the next eligible tool or at Stop. '
        .. 'This is not a clean result.'
  end
  if status == 'current' or status == 'failed' then
    if #lines > 0 then
      -- A crashed build's only diagnostic is mix.exs:1; say where the real error is.
      status, message = 'diagnostics', rendered .. (M.result == 'build_error' and '\n' .. message or '')
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
      .. rendered
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
  local scheduled = false
  local group = vim.api.nvim_create_augroup('tips_elixirls_sync', { clear = true })
  vim.api.nvim_create_autocmd('LspNotify', { group = group, callback = function(args)
    if args.data.method == 'workspace/didChangeWatchedFiles' and not scheduled then
      scheduled = true
      vim.schedule(function()
        scheduled = false
        M.scan()
      end)
    end
  end })
end

return M
