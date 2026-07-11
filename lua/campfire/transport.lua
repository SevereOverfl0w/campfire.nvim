local bencode = require('campfire.bencode')
local url = require('campfire.url')
local uv = vim.uv or vim.loop

local Transport = {}
Transport.__index = Transport

local function schedule(fn, ...)
  local args = { ... }
  vim.schedule(function() fn(unpack(args)) end)
end

local function safe_call(fn, ...)
  if fn then schedule(fn, ...) end
end

local function is_ip(host)
  return host:match('^%d+%.%d+%.%d+%.%d+$') or host:match(':')
end

local function connect_target(spec)
  if spec.type == 'pipe' then return spec.path or '?' end
  return (spec.host or '?') .. ':' .. tostring(spec.port or '?')
end

local function format_connect_error(err, spec)
  local s = tostring(err)
  local target = connect_target(spec)
  if s:find('ECONNREFUSED', 1, true) then
    return ('connection refused by %s — is an nREPL server listening there?'):format(target)
  end
  if s:find('ETIMEDOUT', 1, true) then
    return ('connection to %s timed out'):format(target)
  end
  if s:find('EHOSTUNREACH', 1, true) or s:find('ENETUNREACH', 1, true) then
    return ('%s unreachable'):format(target)
  end
  if s:find('ECONNRESET', 1, true) then
    return ('connection to %s reset'):format(target)
  end
  if spec.type == 'pipe' and s:find('ENOENT', 1, true) then
    return ('no socket at %s'):format(target)
  end
  return ('connect %s failed: %s'):format(target, s)
end

function Transport.new(spec)
  spec = spec or {}
  local parsed = spec.url and url.parse(spec.url) or spec
  if parsed.type == 'http' then
    return require('campfire.drawbridge').new({
      url = parsed.url,
      on_message = spec.on_message,
      on_error = spec.on_error,
      on_close = spec.on_close,
    })
  end
  return setmetatable({
    spec = parsed,
    state = 'idle',
    decoder = bencode.decoder(),
    stream = nil,
    write_queue = {},
    on_message = spec.on_message,
    on_error = spec.on_error,
    on_close = spec.on_close,
  }, Transport)
end

function Transport:_write_payload(payload, callback)
  self.stream:write(payload, function(err) safe_call(callback, err) end)
end

function Transport:_flush_queue()
  local queue = self.write_queue
  self.write_queue = {}
  for _, item in ipairs(queue) do self:_write_payload(item.payload, item.callback) end
end

function Transport:connect(callback)
  if self.state ~= 'idle' then error('transport already used') end
  self.state = 'connecting'
  local stream = self.spec.type == 'pipe' and uv.new_pipe(false) or uv.new_tcp()
  self.stream = stream
  local function connected(err)
    if err then
      self.state = 'closed'
      safe_call(callback, format_connect_error(err, self.spec))
      return
    end
    self.state = 'open'
    self:_flush_queue()
    stream:read_start(function(read_err, chunk)
      if read_err then
        self.state = 'closed'
        safe_call(self.on_error, read_err)
        safe_call(self.on_close)
        return
      end
      if chunk == nil then
        self.state = 'closed'
        safe_call(self.on_close)
        return
      end
      local ok, messages = pcall(self.decoder.feed, self.decoder, chunk)
      if not ok then
        self.state = 'closed'
        safe_call(self.on_error, messages)
        self:close()
        return
      end
      for _, message in ipairs(messages) do safe_call(self.on_message, message) end
    end)
    safe_call(callback, nil, self)
  end
  if self.spec.type == 'pipe' then
    stream:connect(self.spec.path, connected)
  elseif self.spec.host == 'localhost' then
    stream:connect('127.0.0.1', self.spec.port, connected)
  elseif is_ip(self.spec.host) then
    stream:connect(self.spec.host, self.spec.port, connected)
  else
    uv.getaddrinfo(self.spec.host, nil, { socktype = 'stream' }, function(resolve_err, addresses)
      if resolve_err then
        connected(resolve_err)
        return
      end
      if not addresses or not addresses[1] then
        connected('no addresses for ' .. tostring(self.spec.host))
        return
      end
      stream:connect(addresses[1].addr, self.spec.port, connected)
    end)
  end
  return self
end

function Transport:write(message, callback)
  if self.state == 'closed' or self.state == 'idle' then
    local err = 'transport is not open'
    safe_call(callback, err)
    return false, err
  end
  local payload = type(message) == 'string' and message or bencode.encode(message)
  if self.state == 'connecting' then
    self.write_queue[#self.write_queue + 1] = { payload = payload, callback = callback }
    return true
  end
  self:_write_payload(payload, callback)
  return true
end

function Transport:close()
  if self.state == 'closed' then return end
  self.state = 'closed'
  self.write_queue = {}
  local stream = self.stream
  self.stream = nil
  if stream and not stream:is_closing() then
    pcall(function() stream:read_stop() end)
    stream:close(function() safe_call(self.on_close) end)
  else
    safe_call(self.on_close)
  end
end

return { new = Transport.new }
