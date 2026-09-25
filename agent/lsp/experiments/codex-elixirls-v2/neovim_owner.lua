-- This editor owns the compiler tree until every descendant has stopped.
--
-- A client may kill the MCP launcher at once: Codex sends SIGKILL about 15 ms
-- after SIGTERM. Neovim holds the inherited session locks, so it stops ElixirLS
-- and everything it started before it exits and releases them.
--
-- OTP starts port programs (rebar3, make, System.cmd) in their own process
-- groups. An ElixirLS crash orphans them, so remember their groups while the
-- process tree still links them to this editor. Orphans also keep the crashed
-- server's stdio pipes open, so Neovim would not see the exit until they end.
-- The groups are also published to the state directory: if this editor dies
-- without VimLeavePre, the launcher stops them before it releases the locks.
local ffi = require('ffi')
ffi.cdef('int getpgid(int pid);')

local M = {}
local self_pid = vim.fn.getpid()
local groups = {} -- Descendant process groups other than ours.
local below = {} -- Our direct child -> the groups started below it.
local stopping = false
local registry = vim.env.VV_MCP_REGISTRY
local published_path = registry and vim.fs.dirname(registry) .. '/compiler-groups'
local published, publish_failed
local SAMPLE_MS, SHUTDOWN_MS, GRACE_MS, KILL_MS, POLL_MS = 250, 500, 1500, 1000, 50

local function children(pid)
  local ok, found = pcall(vim.api.nvim_get_proc_children, pid)
  return ok and found or {}
end

-- Whole-file replace, only when the set changes.
local function publish()
  if not published_path then return end
  local list = vim.tbl_keys(groups)
  table.sort(list)
  -- The first line names this editor: the launcher ignores any other session's list.
  local text = self_pid .. '\n' .. table.concat(list, '\n')
  if text == published then return end
  local temporary = published_path .. '.tmp'
  local file = io.open(temporary, 'w')
  if file and file:write(text) and file:close() and os.rename(temporary, published_path) then
    published = text
    return
  end
  -- Never leave an outdated list behind; retry at the next sample.
  os.remove(published_path)
  published = nil
  if not publish_failed then
    publish_failed = true
    io.stderr:write('ElixirLS session: cannot record compiler programs in ' .. published_path .. '\n')
  end
end

-- In-process and cheap: no fork. Runs on the main loop.
local function remember()
  if stopping then return end
  local present = {}
  for _, child in ipairs(children(self_pid)) do
    present[child] = true
    below[child] = below[child] or {}
    local pending = children(child)
    while #pending > 0 do
      local pid = table.remove(pending)
      local group = ffi.C.getpgid(pid)
      if group > 0 and group ~= self_pid then groups[group], below[child][group] = true, true end
      vim.list_extend(pending, children(pid))
    end
  end
  -- Forget stopped groups, so a reused group ID is never signalled.
  -- macOS reports EPERM for a group of zombies; zombies do not write.
  for group in pairs(groups) do
    if vim.uv.kill(-group, 0) ~= 0 then
      groups[group] = nil
      for _, started in pairs(below) do started[group] = nil end
    end
  end
  for child, started in pairs(below) do
    if not present[child] then
      below[child] = nil
      -- The compiler died and left programs it started: stop them now, so its
      -- pipes close and the normal exit report follows.
      if next(started) then M.stop() end
    end
  end
  publish()
end

-- Live owned processes: our group (only our descendants can join it), groups
-- found below us now, and groups remembered before an orphaning crash.
local function owned()
  local ps = vim.system({ '/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=' })
  local result = ps:wait(2000)
  assert(result.code == 0, 'cannot list processes')
  local rows, listed = {}, {}
  for line in result.stdout:gmatch('[^\n]+') do
    local pid, parent, group, state = line:match('^%s*(%d+)%s+(%d+)%s+(%d+)%s+(%S+)')
    -- ps runs as our child in our group; it lists itself.
    if pid and tonumber(pid) ~= ps.pid then
      local row = { pid = tonumber(pid), group = tonumber(group), zombie = state:sub(1, 1) == 'Z' }
      rows[#rows + 1] = row
      local key = tonumber(parent)
      listed[key] = listed[key] or {}
      table.insert(listed[key], row)
    end
  end
  assert(#rows > 0, 'empty process table')
  local pending, seen = { self_pid }, {}
  for _, row in ipairs(rows) do
    if row.group == self_pid then pending[#pending + 1] = row.pid end
  end
  while #pending > 0 do
    local pid = table.remove(pending)
    if not seen[pid] then
      seen[pid] = true
      for _, row in ipairs(listed[pid] or {}) do
        if row.group ~= self_pid then groups[row.group] = true end
        pending[#pending + 1] = row.pid
      end
    end
  end
  local live = {}
  for _, row in ipairs(rows) do
    if not row.zombie and row.pid ~= self_pid and (row.group == self_pid or groups[row.group]) then
      live[#live + 1] = row
    end
  end
  return live
end

local function signal(live, number)
  for _, row in ipairs(live) do
    -- Never signal our own group: this editor must outlive its descendants.
    vim.uv.kill(row.group == self_pid and row.pid or -row.group, number)
  end
end

-- LSP shutdown, then TERM, bounded grace and KILL, re-listing each round to
-- catch late forks. ElixirLS exits at once on LSP exit; on SIGTERM it needs
-- about 2 s. Remembered groups still name port programs its exit orphans.
function M.stop()
  stopping = true
  local ok, err = pcall(function()
    owned()
    for _, client in ipairs(vim.lsp.get_clients({ name = 'elixirls' })) do client:stop() end
    -- is_stopped() is true once stopping starts; a client leaves the list on exit.
    vim.wait(SHUTDOWN_MS, function() return #vim.lsp.get_clients({ name = 'elixirls' }) == 0 end, POLL_MS)
    local number, deadline = 15, vim.uv.hrtime() + GRACE_MS * 1e6
    local live = owned()
    while #live > 0 do
      if vim.uv.hrtime() > deadline then
        if number == 9 then error(#live .. ' processes survived SIGKILL') end
        number, deadline = 9, vim.uv.hrtime() + KILL_MS * 1e6
      end
      signal(live, number)
      vim.uv.sleep(POLL_MS)
      live = owned()
    end
  end)
  if not ok then io.stderr:write('ElixirLS session: compiler cleanup failed: ' .. tostring(err) .. '\n') end
end

-- Register before vim.lsp loads: autocmds run in order, and the LSP exit
-- handler would stop ElixirLS first and orphan its port programs.
function M.setup()
  vim.api.nvim_create_autocmd('VimLeavePre', { callback = M.stop })
  local timer = assert(vim.uv.new_timer())
  timer:start(SAMPLE_MS, SAMPLE_MS, vim.schedule_wrap(remember))
end

return M
