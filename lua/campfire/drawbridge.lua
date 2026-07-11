-- HTTP (drawbridge) nREPL transport. Mirrors campfire.transport's interface
-- (state / on_message / on_error / on_close + connect/write/close) so the
-- client is oblivious to whether it speaks bencode-over-socket or
-- drawbridge-over-HTTP.
--
-- Wire protocol (nrepl/drawbridge, verified against a live server):
--   * A request message is form-urlencoded and POSTed. Nested map/vector
--     values are flattened into Ring nested-params (`k[sub]=v`, `k[]=v`) so
--     ops carrying nested maps (cider `test-var-query`'s `var-query`) survive.
--   * The server queues nREPL responses per HTTP (ring) session, keyed by the
--     `drawbridge-session` cookie; curl's cookie jar carries it across calls.
--   * Every GET/POST response body is a JSON array of the response messages
--     available since the last request (`[\n{..},\n{..}\n]`).
--   * A `REPL-Response-Timeout` header on the session's first request tells the
--     server how long to block collecting responses before replying — so a
--     POST returns its op's responses inline, and a long op's later output is
--     drained by GET polls.
local uv = vim.uv or vim.loop

local M = {}
local Http = {}
Http.__index = Http

-- Server-side block window per request (ms). Small so streamed output latency
-- is bounded (the server replies this long after the *last* message it sees).
local READ_TIMEOUT_MS = 100
-- Client-side gap between polls once a burst has drained, so an idle session
-- long-polls at ~1/s instead of hammering the endpoint.
local IDLE_POLL_MS = 750
-- Keep polling at full speed for this many empty rounds after activity, so an
-- op that is slow to produce its first message isn't stalled by the idle gap.
local HOT_POLLS = 3
local MAX_TIME_S = 60

local function schedule(fn, ...)
  local args = { ... }
  if fn then vim.schedule(function() fn(unpack(args)) end) end
end

-- Percent-encode one application/x-www-form-urlencoded component.
local function pct(s)
  return (tostring(s):gsub('[^%w%-_%.~]', function(c) return ('%%%02X'):format(c:byte()) end))
end

-- Flatten a value into Ring nested-params pairs under `prefix`. Maps become
-- `prefix[key]`, vectors become `prefix[]`; scalars terminate. wrap-nested-params
-- on the server reconstructs the original structure.
local function encode_into(prefix, value, out)
  if type(value) == 'table' then
    if vim.islist(value) then
      for _, item in ipairs(value) do encode_into(prefix .. '[]', item, out) end
    else
      for k, v in pairs(value) do encode_into(prefix .. '[' .. tostring(k) .. ']', v, out) end
    end
  else
    out[#out + 1] = pct(prefix) .. '=' .. pct(value)
  end
end

local function form_encode(msg)
  local out = {}
  for k, v in pairs(msg) do encode_into(tostring(k), v, out) end
  return table.concat(out, '&')
end
M.form_encode = form_encode

local function http_status(res)
  return tonumber((tostring(res.stderr or '')):match('(%d%d%d)%s*$') or '')
end

local function curl_error(res)
  local e = vim.trim(tostring(res.stderr or ''))
  return e ~= '' and e or ('curl exit ' .. tostring(res.code))
end

function M.new(spec)
  local self = setmetatable({
    url = spec.url,
    state = 'idle',
    on_message = spec.on_message,
    on_error = spec.on_error,
    on_close = spec.on_close,
    write_queue = {},
    in_flight = false,
    empties = 0,
    read_timeout = spec.read_timeout or READ_TIMEOUT_MS,
    idle_poll = spec.idle_poll or IDLE_POLL_MS,
    jar = spec.jar or vim.fn.tempname(),
  }, Http)
  -- Injectable for tests; default shells out to curl. Signature: (body, cb)
  -- where body is a form string (POST) or nil (GET poll), and cb receives
  -- { code, stdout, stderr }.
  self.request = spec.request or function(body, cb) self:_curl(body, cb) end
  return self
end

function Http:_curl(body, cb)
  local args = {
    'curl', '-sS', '-b', self.jar, '-c', self.jar,
    '-H', 'REPL-Response-Timeout: ' .. self.read_timeout,
    '-w', '%{stderr}%{http_code}', '--max-time', tostring(MAX_TIME_S),
  }
  if body then args[#args + 1] = '--data-binary'; args[#args + 1] = '@-' end
  args[#args + 1] = self.url
  self._proc = vim.system(args, { stdin = body, text = true }, function(res)
    cb({ code = res.code, stdout = res.stdout, stderr = res.stderr })
  end)
end

-- Decode one response body and dispatch its messages. Returns the message
-- count, or (nil, err) on a malformed body / drawbridge error map.
function Http:_deliver(body)
  local ok, decoded = pcall(vim.json.decode, body or '')
  if not ok or type(decoded) ~= 'table' then
    return nil, 'invalid response from nREPL HTTP endpoint'
  end
  if not (vim.islist(decoded) or next(decoded) == nil) then
    -- drawbridge signals errors with a JSON map rather than an array.
    return nil, tostring(decoded.reason or decoded.error or 'nREPL HTTP endpoint error')
  end
  for _, message in ipairs(decoded) do schedule(self.on_message, message) end
  return #decoded
end

-- Validate transport-level success then deliver. Returns (count) or (nil, err).
function Http:_handle(res)
  if res.code ~= 0 then return nil, ('%s: %s'):format(self.url or '?', curl_error(res)) end
  local status = http_status(res)
  if not status or status < 200 or status >= 300 then
    return nil, ('%s returned HTTP %s'):format(self.url or '?', tostring(status or '?'))
  end
  return self:_deliver(res.stdout)
end

function Http:_fail(err)
  if self.state == 'closed' then return end
  schedule(self.on_error, err)
  self:close()
end

function Http:_schedule_pump(delay)
  if self.timer then pcall(function() self.timer:stop(); self.timer:close() end); self.timer = nil end
  if self.state ~= 'open' then return end
  if delay <= 0 then
    -- Defer via the scheduler (never call _pump inline) so a synchronous
    -- request runner can't recurse into an unbounded stack.
    vim.schedule(function() self:_pump() end)
  else
    self.timer = uv.new_timer()
    self.timer:start(delay, 0, function()
      self.timer:close(); self.timer = nil
      self:_pump()
    end)
  end
end

-- Single-flight pump: POST the next queued write if any, else GET-poll. One
-- request in flight at a time preserves nREPL message ordering (the server
-- drains a shared queue per session).
function Http:_pump()
  if self.state ~= 'open' or self.in_flight then return end
  self.in_flight = true
  local item = table.remove(self.write_queue, 1)
  self.request(item and item.body, function(res)
    self.in_flight = false
    if self.state == 'closed' then return end
    local n, err = self:_handle(res)
    if item and item.cb then schedule(item.cb, err) end
    if err then return self:_fail(err) end
    if self.state ~= 'open' then return end
    self.empties = (n and n > 0) and 0 or (self.empties + 1)
    local hot = #self.write_queue > 0 or self.empties < HOT_POLLS
    self:_schedule_pump(hot and 0 or self.idle_poll)
  end)
end

function Http:connect(callback)
  if self.state ~= 'idle' then error('transport already used') end
  self.state = 'connecting'
  -- Initial GET verifies reachability, primes the session cookie, and (being
  -- the session's first request) fixes the server-side read timeout.
  self.request(nil, function(res)
    if self.state == 'closed' then return end
    local _, err = self:_handle(res)
    if err then
      self.state = 'closed'
      schedule(callback, err)
      return
    end
    self.state = 'open'
    self.empties = 0
    schedule(callback, nil, self)
    self:_schedule_pump(0)
  end)
  return self
end

function Http:write(message, callback)
  if self.state == 'closed' or self.state == 'idle' then
    local err = 'transport is not open'
    schedule(callback, err)
    return false, err
  end
  local body = type(message) == 'string' and message or form_encode(message)
  self.write_queue[#self.write_queue + 1] = { body = body, cb = callback }
  self.empties = 0
  if not self.in_flight then self:_schedule_pump(0) end
  return true
end

function Http:close()
  if self.state == 'closed' then return end
  self.state = 'closed'
  self.write_queue = {}
  if self.timer then pcall(function() self.timer:stop(); self.timer:close() end); self.timer = nil end
  if self._proc then pcall(function() self._proc:kill('sigterm') end) end
  if self.jar then pcall(uv.fs_unlink, self.jar) end
  schedule(self.on_close)
end

return M
