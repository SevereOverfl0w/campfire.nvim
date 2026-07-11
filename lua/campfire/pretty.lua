local M = {}

-- nREPL's print middleware calls the print fn with three args:
--   (print-fn value writer options)
-- so only 3-arg-compatible fns are usable. clojure.pprint/pprint, cljs.pprint
-- /pprint and similar 1/2-arg fns silently fail with empty output.
local PRINTERS = {
  ['cider.nrepl.pprint/pr']            = { width = nil,           length = 'print-length',level = 'print-level' },
  ['cider.nrepl.pprint/pprint']        = { width = 'right-margin',length = 'length',      level = 'level' },
  ['cider.nrepl.pprint/fipp-pprint']   = { width = 'width',       length = 'print-length',level = 'print-level' },
  ['cider.nrepl.pprint/puget-pprint']  = { width = 'width',       length = 'print-length',level = 'print-level' },
  ['cider.nrepl.pprint/zprint-pprint'] = { width = 'width',       length = 'max-length',  level = 'max-depth' },
  ['nrepl.util.print/pprint']          = { width = 'right-margin',length = 'length',      level = 'level' },
  ['nrepl.util.print/pr']              = { width = nil,           length = 'print-length',level = 'print-level' },
}

local DETECT_CANDIDATES = {
  'cider.nrepl.pprint/fipp-pprint',
  'cider.nrepl.pprint/puget-pprint',
  'cider.nrepl.pprint/zprint-pprint',
  'cider.nrepl.pprint/pprint',
  'nrepl.util.print/pprint',
  'nrepl.util.print/pr',
}

-- cider-nrepl defines all wrapper vars regardless of whether the backing
-- library is on the classpath, so a bare (resolve wrapper) is a false
-- positive: at print time the wrapper requires the backing ns and warns when
-- it is absent. Each wrapper here must additionally prove its backing ns can
-- be required. Candidates without an entry need only the resolve check
-- (clojure.pprint is always present; the *pr* wrappers are dep-free).
local BACKING_NS = {
  ['cider.nrepl.pprint/fipp-pprint']   = 'fipp.edn',
  ['cider.nrepl.pprint/puget-pprint']  = 'puget.printer',
  ['cider.nrepl.pprint/zprint-pprint'] = 'zprint.core',
}

local DETECT_TIMEOUT_MS = 500
local DETECT_WATCHDOG_MS = 3000

local function g(name, default)
  local v = vim.g[name]
  if v == nil then return default end
  return v
end

local function truthy(v)
  if v == nil or v == false then return false end
  if type(v) == 'number' then return v ~= 0 end
  return true
end

local function default_width()
  local cols = vim.o.columns
  local win = vim.api.nvim_win_get_width(0)
  if win <= 0 or win > cols then return cols end
  return win
end

local function printer_keys(printer)
  return PRINTERS[printer] or PRINTERS['cider.nrepl.pprint/fipp-pprint']
end

-- Detection probe. One runtime-agnostic form: a reader conditional picks the
-- right exception class so the same code runs wherever the tooling session
-- speaks. nREPL reads with :read-cond :allow (verified on clj/bb/nbb/lg).
--   :clj     JVM (clj, bb, AND piggieback — whose tooling session is JVM, so
--            its reader takes :clj even though main is cljs) → Throwable.
--   :cljs    nbb/cljs → :default catch.
--   :default lg / anything else → skip the require probe entirely (no cider
--            wrappers there, so resolve is nil anyway; this also avoids
--            emitting a catch clause lg's reader can't compile).
local function detect_code()
  local preamble = '#?(:clj (try (clojure.core/require (clojure.core/symbol "nrepl.util.print"))'
    .. ' (catch Throwable _#)) :default nil)'
  local parts = {}
  for _, sym in ipairs(DETECT_CANDIDATES) do
    local resolved = '(clojure.core/resolve (clojure.core/symbol "' .. sym .. '"))'
    local backing = BACKING_NS[sym]
    local guard
    if backing then
      -- The wrapper var existing does not imply the backing library loads, so
      -- prove the require. The catch class is reader-conditional per runtime.
      local req = '(try (clojure.core/require (clojure.core/symbol "' .. backing .. '")) true'
      guard = '(clojure.core/and ' .. resolved .. ' '
        .. '#?(:clj ' .. req .. ' (catch Throwable _# false))'
        .. ' :cljs ' .. req .. ' (catch :default _# false))'
        .. ' :default true))'
    else
      guard = resolved
    end
    parts[#parts + 1] = '(clojure.core/when ' .. guard .. ' "' .. sym .. '")'
  end
  return '(do ' .. preamble .. ' (clojure.core/or ' .. table.concat(parts, ' ') .. '))'
end


local function strip_quotes(s)
  if type(s) ~= 'string' then return nil end
  return s:match('^"(.-)"$') or s:match('^:(.+)$')
end

local function resolve(client, value)
  if client.pretty_detected == false then client.pretty_detected = value end
end

function M.detect_async(client)
  if not client or client.pretty_detected ~= nil then return end
  client.pretty_detected = false

  vim.defer_fn(function() resolve(client, nil) end, DETECT_WATCHDOG_MS)

  local ok = pcall(function()
    client:request({ op = 'eval', code = detect_code(), scope = 'tool' }, function(msg)
      pcall(function()
        if msg.value then
          local val = strip_quotes(msg.value)
          if val and val ~= 'nil' then resolve(client, val) end
        end
        for _, s in ipairs(msg.status or {}) do
          if s == 'done' then resolve(client, nil) end
        end
      end)
    end)
  end)
  if not ok then resolve(client, nil) end
end

local function safe_fallback(client)
  -- Prefer a dep-free printer: fipp/puget/zprint need a library that may be
  -- absent. With cider-nrepl (info op) its dep-free pr wrapper is guaranteed
  -- loaded; otherwise fall back to bare nREPL's pr.
  if client and client.describe and client.describe.ops and client.describe.ops.info then
    return 'cider.nrepl.pprint/pr'
  end
  return 'nrepl.util.print/pr'
end

function M.printer(client)
  local explicit = g('campfire_pretty_fn')
  if type(explicit) == 'string' and explicit ~= '' then return explicit end
  if client and client.pretty_detected == false then
    vim.wait(DETECT_TIMEOUT_MS, function() return client.pretty_detected ~= false end, 10)
  end
  if client and type(client.pretty_detected) == 'string' then
    return client.pretty_detected
  end
  return safe_fallback(client)
end

function M.options_from_flat(printer)
  local keys = printer_keys(printer)
  local opts = {}

  if keys.width then
    local w = g('campfire_pretty_width')
    if w == nil then w = default_width() end
    opts[keys.width] = w
  end
  if keys.length then
    local v = g('campfire_pretty_length')
    if v ~= nil then opts[keys.length] = v end
  end
  if keys.level then
    local v = g('campfire_pretty_level')
    if v ~= nil then opts[keys.level] = v end
  end

  if g('campfire_pretty_meta') ~= nil then opts['print-meta'] = truthy(g('campfire_pretty_meta')) end
  local readably = g('campfire_pretty_readably')
  if readably ~= nil then opts['print-readably'] = truthy(readably) end
  local nsmaps = g('campfire_pretty_namespace_maps')
  if nsmaps ~= nil then opts['print-namespace-maps'] = truthy(nsmaps) end

  return opts
end

local function clamp_width(msg, printer)
  local keys = printer_keys(printer)
  if not keys.width then return end
  local opts = msg['nrepl.middleware.print/options']
  if type(opts) ~= 'table' then return end
  local cap = default_width()
  local cur = opts[keys.width]
  if type(cur) == 'number' and cur > cap then opts[keys.width] = cap end
end

local function call_func(msg)
  local f = vim.g.Campfire_pretty_func
  if f == nil then return msg end
  local ok, result
  if type(f) == 'string' then
    ok, result = pcall(vim.fn.call, f, { msg })
  else
    ok, result = pcall(f, msg)
  end
  if not ok then
    vim.schedule(function()
      vim.api.nvim_err_writeln('Campfire: g:Campfire_pretty_func error: ' .. tostring(result))
    end)
    return msg
  end
  if type(result) == 'table' then return result end
  return msg
end

function M.apply(msg, client)
  if g('campfire_pretty', true) == false or g('campfire_pretty', true) == 0 then
    return msg
  end

  local printer = M.printer(client)
  msg['nrepl.middleware.print/print'] = printer

  local opts = M.options_from_flat(printer)

  local user_opts = g('campfire_pretty_options')
  if type(user_opts) == 'table' then
    for k, v in pairs(user_opts) do opts[k] = v end
  end

  msg['nrepl.middleware.print/options'] = opts

  clamp_width(msg, printer)
  msg['nrepl.middleware.print/stream?'] = 1

  return call_func(msg)
end

function M._detect_code() return detect_code() end
M._resolve = resolve
M._watchdog_ms = function(ms) DETECT_WATCHDOG_MS = ms end

return M
