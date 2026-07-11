local transport_mod = require('campfire.transport')

local M = {}
local Client = {}
Client.__index = Client

local counter = 0

local function status_has(message, status)
  for _, item in ipairs(message.status or {}) do
    if item == status then return true end
  end
  return false
end

function M.id()
  counter = counter + 1
  return ('cf-%d'):format(counter)
end

function M.combine(responses)
  local combined = { status = {}, value = {} }
  local seen_status = {}

  for _, response in ipairs(responses) do
    for key, value in pairs(response) do
      if key == 'id' or key == 'ns' or key == 'session' then
        combined[key] = value
      elseif key == 'status' then
        for _, status in ipairs(value) do
          if not seen_status[status] then
            seen_status[status] = true
            combined.status[#combined.status + 1] = status
          end
        end
      elseif key == 'value' then
        combined.value[#combined.value + 1] = value
      elseif type(value) == 'string' then
        combined[key] = (combined[key] or '') .. value
      else
        combined[key] = value
      end
    end
  end

  if #combined.status == 0 then combined.status = nil end
  if #combined.value == 0 then combined.value = nil end

  return combined
end

function M.new(opts)
  opts = opts or {}
  local client = setmetatable({
    transport = opts.transport,
    requests = {},
    out_listeners = {},
    named = {},
    describe = opts.describe or {},
    url = opts.url,
    path = opts.path,
    label = opts.label,
    lang = opts.lang,
  }, Client)

  if not client.transport then
    client.transport = transport_mod.new({
      url = opts.url,
      on_error = opts.on_error,
      on_close = opts.on_close,
    })
  end

  client.transport.on_message = function(message) client:_receive(message) end

  -- Connection death is the one definitive "everything in flight is doomed"
  -- signal (socket close: server crash/exit, network drop, or our own
  -- close()). Fail every in-flight request so foreground loops / request_sync
  -- unblock instead of polling a request that can never complete. Wraps any
  -- caller-supplied on_close. (This replaces the old silent-death watchdog,
  -- whose liveness probe could not tell a busy session from a dead one.)
  local prev_on_close = client.transport.on_close
  client.transport.on_close = function()
    client:_fail_all_inflight('connection closed')
    if prev_on_close then prev_on_close() end
  end

  return client
end

function Client:connect(callback)
  return self.transport:connect(function(err)
    if err then
      if callback then callback(err) end
      return
    end
    self:_init(callback)
  end)
end

function Client:_init(callback)
  self:request({ op = 'describe' }, function(message)
    if not status_has(message, 'done') then return end
    local req = self.requests[message.id]
    self.describe = M.combine(req and req.responses or { message })
    self:_clone_sessions(callback)
  end)
end

local CLONE_TIMEOUT_MS = 5000

-- Surface helpers. The client has no view of init.lua's echo/errecho, so it
-- carries its own thin wrappers (same shape) for session-recycle messages.
-- Both schedule onto the main loop in case they run off a callback.
local function echo(msg)
  vim.schedule(function() vim.api.nvim_echo({ { msg, 'WarningMsg' } }, true, {}) end)
end

local function errecho(msg)
  vim.schedule(function() vim.api.nvim_err_writeln(msg) end)
end

M.timeout = {}

function M.timeout.drop(client, msg, callback)
  local req = client.requests[msg.id]
  if not req then return end
  local resp = { id = msg.id, status = { 'done', 'timeout' }, err = 'timeout' }
  req.responses[#req.responses + 1] = resp
  if req.sync then
    client.completed = client.completed or {}
    client.completed[msg.id] = req.responses
  end
  client.requests[msg.id] = nil
  if callback then pcall(callback, resp) end
end

function Client:_clone_sessions(callback)
  local pending = 2
  local fired = false
  local function fire(err)
    if fired then return end
    fired = true
    if callback then callback(err, err and nil or self) end
  end
  local function got(field)
    return function(msg)
      if msg['new-session'] and msg['new-session'] ~= '' then
        self.named[field] = { id = msg['new-session'] }
      end
      if msg.err then return fire('clone ' .. field .. ': ' .. msg.err) end
      if status_has(msg, 'done') then
        if not self.named[field] then
          return fire('clone ' .. field .. ' returned done without new-session')
        end
        pending = pending - 1
        if pending == 0 then fire(nil) end
      end
    end
  end
  self:request({ op = 'clone', timeout_ms = CLONE_TIMEOUT_MS }, got('main'))
  self:request({ op = 'clone', timeout_ms = CLONE_TIMEOUT_MS }, got('tooling'))
end

function Client:session(scope)
  local field = (scope == 'tool' or scope == 'tooling') and 'tooling'
    or (scope == 'user' or scope == 'main') and 'main'
    or scope
  local entry = field and self.named and self.named[field]
  return entry and entry.id or nil
end

function Client:request(request, callback)
  local msg = vim.deepcopy(request)
  if msg.id == nil or msg.id == '' then msg.id = M.id() end
  if msg.session == '' or msg.session == false then msg.session = nil end
  if msg.ns == '' or msg.ns == false then msg.ns = nil end

  local scope = msg.scope
  local timeout_ms = msg.timeout_ms
  local on_timeout = M.timeout.drop
  msg.scope, msg.timeout_ms = nil, nil

  -- Closed transport: the write would be silently dropped and the request
  -- would hang forever. Resolve immediately with an error so callers don't
  -- wait on a doomed request (mirrors the no-session error path).
  if self.transport and self.transport.state == 'closed' then
    local resp = { id = msg.id, session = msg.session,
      status = { 'done', 'error', 'connection-closed' }, err = 'connection closed' }
    if callback then
      vim.schedule(function() pcall(callback, resp) end)
    else
      self.completed = self.completed or {}
      self.completed[msg.id] = { resp }
    end
    return { id = msg.id, session = msg.session, err = 'connection closed' }
  end

  if scope and msg.session == nil then
    msg.session = self:session(scope)
    if msg.session == nil then
      local err = 'no ' .. scope .. ' session'
      local resp = { id = msg.id, status = { 'done', 'error' }, err = err }
      if callback then vim.schedule(function() pcall(callback, resp) end) end
      return { id = msg.id, session = nil, err = err }
    end
  end

  local received = {}
  self.requests[msg.id] = {
    request = msg,
    responses = received,
    callbacks = { function(message) received[#received + 1] = message end },
    sync = callback == nil,
  }
  if callback then
    table.insert(self.requests[msg.id].callbacks, callback)
  end

  if timeout_ms then
    self.requests[msg.id].timer = vim.defer_fn(function()
      if self.requests[msg.id] then on_timeout(self, msg, callback) end
    end, timeout_ms)
  end

  self.transport:write(msg)
  return { id = msg.id, session = msg.session }
end

function Client:request_sync(request, timeout)
  local t = timeout or 1000
  local req = vim.tbl_extend('keep', request, { timeout_ms = t })
  local handle = self:request(req)
  local responses
  vim.wait(t + 50, function()
    if self.requests[handle.id] == nil then
      responses = self.completed and self.completed[handle.id]
      return true
    end
    return false
  end)
  if self.completed then self.completed[handle.id] = nil end
  return M.combine(responses or {})
end

function Client:_receive(message)
  local req = message.id and self.requests[message.id]
  if req then
    for _, callback in ipairs(req.callbacks) do pcall(callback, message) end
    if status_has(message, 'done') then
      if req.timer then pcall(function() req.timer:close() end) end
      if req.sync then
        self.completed = self.completed or {}
        self.completed[message.id] = req.responses
      end
      self.requests[message.id] = nil
    end
  end

  -- Session-scoped stdout/stderr listener. cider-nrepl tags test stdout/stderr
  -- with the session's bound *out* writer — captured at the last eval, not the
  -- running op — so output from a test-var-query run arrives under a stale,
  -- already-completed message id and the id-based dispatch above never sees it.
  -- A listener keyed on the session id (set for the op's duration) recovers it.
  if message.session and (message.out or message.err) then
    local listener = self.out_listeners[message.session]
    if listener then pcall(listener, message) end
  end

  -- Responsive recovery. When the server reports a scope session as unknown
  -- (server restart, session GC, closed out-of-band) it says so immediately
  -- via `unknown-session` — fail that session's in-flight requests and clone a
  -- fresh session. This and transport-close are the two recovery signals; both
  -- are definitive (a server reply / a socket close), unlike a liveness probe,
  -- which cannot tell a busy session from a dead one.
  if message.session and status_has(message, 'unknown-session')
      and self:_scope_of(message.session) then
    self:_recycle_dead(message.session, 'unknown to server')
  end
end

-- Map a session id back to its named scope ('main'/'tooling'), or nil if the
-- id is not one of the cloned sessions (e.g. the base describe session).
function Client:_scope_of(sid)
  for _, field in ipairs({ 'main', 'tooling' }) do
    local entry = self.named[field]
    if entry and entry.id == sid then return field end
  end
  return nil
end

-- Requests still awaiting a `done` that are bound to sid. Returns the list of
-- ids (empty = nothing in-flight on this session).
function Client:_session_inflight(sid)
  local ids = {}
  for id, req in pairs(self.requests) do
    if req.request.session == sid then ids[#ids + 1] = id end
  end
  return ids
end

-- Resolve one in-flight request with a synthetic error status (tagged `tail`)
-- so M.foreground / request_sync unblock instead of polling a doomed request
-- forever. Mirrors M.timeout.drop's shape but fires every callback and records
-- the sync response.
local function resolve_inflight(self, id, tail, err)
  local req = self.requests[id]
  if not req then return end
  local resp = { id = id, session = req.request.session,
    status = { 'done', 'error', tail }, err = err }
  req.responses[#req.responses + 1] = resp
  for _, callback in ipairs(req.callbacks) do pcall(callback, resp) end
  if req.timer then pcall(function() req.timer:close() end) end
  if req.sync then
    self.completed = self.completed or {}
    self.completed[id] = req.responses
  end
  self.requests[id] = nil
end

-- Fail every in-flight request (all sessions, plus session-less ones like an
-- in-progress clone) — used on transport close, where the socket is gone and
-- nothing will ever complete.
function Client:_fail_all_inflight(err)
  for id in pairs(self.requests) do resolve_inflight(self, id, 'connection-closed', err) end
end

-- Fail every in-flight request on a dead session so callers unblock.
function Client:_fail_inflight(sid, err)
  for _, id in ipairs(self:_session_inflight(sid)) do resolve_inflight(self, id, 'session-dead', err) end
end

-- Recycle a dead scope's session. op=clone with NO session clones from the base
-- connection, which runs on a different (live) thread, so it succeeds where the
-- dead session's thread cannot. On the clone's done we swap named[scope].id to
-- the fresh id; subsequent scope-routed requests then use it transparently. If
-- the transport itself is closed there is nothing to recycle onto — surface
-- that distinctly and bail (no loop).
function Client:_recycle_session(scope)
  if self.transport and self.transport.state == 'closed' then
    errecho('Campfire: connection closed — cannot recycle ' .. scope .. ' session')
    return
  end
  self:request({ op = 'clone', timeout_ms = CLONE_TIMEOUT_MS }, function(msg)
    if msg['new-session'] and msg['new-session'] ~= '' then
      self.named[scope] = { id = msg['new-session'] }
    end
    if msg.err then
      errecho('Campfire: failed to recycle ' .. scope .. ' session: ' .. tostring(msg.err))
      return
    end
    if status_has(msg, 'done') then
      if self.named[scope] and self.named[scope].id then
        echo('Campfire: ' .. scope .. ' session recycled')
      else
        errecho('Campfire: recycle of ' .. scope .. ' session returned no new-session')
      end
    end
  end)
end

-- Surface a dead scope session, unblock its stuck requests, and recycle it.
-- Reached from the `unknown-session` fast path (the server told us the session
-- is gone); guarded so repeated replies can't fire two clones for the same id.
function Client:_recycle_dead(sid, reason)
  local scope = self:_scope_of(sid)
  if not scope then return end
  self.session_recycling = self.session_recycling or {}
  if self.session_recycling[sid] then return end
  self.session_recycling[sid] = true
  echo('Campfire: nREPL ' .. scope .. ' session ' .. reason .. ' — recycling')
  self:_fail_inflight(sid, reason)
  self:_recycle_session(scope)
end

-- Register `fn` to receive every out/err message on `sid`, regardless of the
-- message id they carry (see _receive). One listener per session; nil clears.
function Client:set_output_listener(sid, fn)
  if sid then self.out_listeners[sid] = fn end
end

function Client:stdin(session_or_id, data)
  local req = self.requests[session_or_id]
  local session = req and req.request.session
  if not session then return false end

  self.transport:write({
    op = 'stdin',
    id = M.id(),
    session = session,
    stdin = type(data) == 'string' and data or vim.fn.nr2char(data),
  })
  return true
end

function Client:interrupt(id)
  local req = self.requests[id]
  if not req or not req.request.session then return false end
  self.transport:write({
    op = 'interrupt',
    id = M.id(),
    session = req.request.session,
    ['interrupt-id'] = id,
  })
  return true
end

function Client:close()
  for _, key in ipairs({ 'main', 'tooling' }) do
    local s = self.named[key]
    if s then
      pcall(function()
        self.transport:write({ op = 'close', id = M.id(), session = s.id })
      end)
    end
  end
  self.named = {}
  -- Defer transport close so the server has time to flush its ack
  -- responses for the op=close messages we just wrote. bb logs a broken-
  -- pipe stack trace and nbb's Node runtime CRASHES on EPIPE if the TCP
  -- socket disappears mid-write. Across a full integration sweep that
  -- adds up to several connect/disconnect cycles which kill the bb / nbb
  -- backends and cascade into "connection refused" for every later
  -- suite. 50ms is plenty for the server to drain its tx buffer.
  local transport = self.transport
  vim.defer_fn(function() pcall(function() transport:close() end) end, 50)
end

return setmetatable(M, { __call = function(_, opts) return M.new(opts) end })
