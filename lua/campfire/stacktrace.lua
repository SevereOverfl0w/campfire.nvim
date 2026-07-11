local resource = require('campfire.resource')
local quickfix = require('campfire.quickfix')

local M = {}

local function oneline(s)
  if type(s) ~= 'string' or s == '' then return nil end
  local collapsed = vim.trim((s:gsub('%s+', ' ')))
  return collapsed ~= '' and collapsed or nil
end

local function frame_has_flag(frame, flag)
  for _, fl in ipairs(frame.flags or {}) do
    if fl == flag then return true end
  end
  return false
end

-- Convert an analyzed cause chain to qf-shaped entries: one navigable line per
-- frame (project → file:line, deps → zipfile://, java → plain since it has no
-- source), cause boundaries as plain headers, a cause's printed ex-data (the
-- analyzer's :data slot) as a plain line above its frames, adjacent :dup
-- frames collapsed. Pure: no client access.
function M.causes_to_qf(causes)
  local entries = {}
  for ci, cause in ipairs(causes or {}) do
    if ci > 1 then
      local hdr = '      caused by: ' .. (cause.class or '')
      local m = oneline(cause.message)
      if m then hdr = hdr .. ': ' .. m end
      entries[#entries + 1] = { text = hdr, filename = '', lnum = 0 }
    end
    local d = oneline(cause.data)
    if d then
      entries[#entries + 1] = { text = '      ex-data: ' .. d, filename = '', lnum = 0 }
    end
    for _, frame in ipairs(cause.stacktrace or {}) do
      if not frame_has_flag(frame, 'dup') then
        local path = resource.url_to_path(frame['file-url'])
        local nm = frame.var or frame.name or '?'
        local ln = tonumber(frame.line) or 0
        entries[#entries + 1] = {
          text = string.format('      at %s (%s:%d)', nm, frame.file or '?', ln),
          filename = path or '',
          lnum = path and ln or 0,
        }
      end
    end
  end
  return entries
end

-- True when the server advertises the analyze-last-stacktrace op (cider-nrepl).
function M.last_op_available(client)
  local ops = client and client.describe and client.describe.ops
  return ops ~= nil and ops['analyze-last-stacktrace'] ~= nil
end

-- cider's analyze-last-stacktrace reads the JVM `*e`. ClojureScript errors live
-- in the cljs runtime's own `*e`, which that op can't see — yet shadow-cljs
-- (and any piggieback setup carrying cider-nrepl on its JVM tooling session)
-- still advertises the op, so it answers `no-error` for a live cljs error. So
-- for cljs-family runtimes we always take the `*e`-extraction fallback instead,
-- regardless of what the connection advertises. nbb already lacks the op; this
-- just makes the choice explicit and covers shadow/piggieback too.
local CLJS_FAMILY = { cljs = true, nbb = true }

function M.is_cljs_family(client)
  return client ~= nil and CLJS_FAMILY[client.lang] == true
end

-- True when the analyzed cider op should drive the stacktrace for this client
-- (advertised AND the error session is a JVM Clojure one).
function M.use_analyzed(client)
  return M.last_op_available(client) and not M.is_cljs_family(client)
end

-- True when the server advertises the test-stacktrace op (cider-nrepl).
function M.test_op_available(client)
  local ops = client and client.describe and client.describe.ops
  return ops ~= nil and ops['test-stacktrace'] ~= nil
end

-- Fetch the analyzed cause chain for a session's most recent eval error via
-- cider-nrepl's analyze-last-stacktrace op. Streams one response per cause;
-- callback fires once with the full list when the request completes. No-op
-- (callback fired with nil) when the op isn't advertised. opts.session targets
-- an explicit session id (a clone); otherwise opts.scope selects a named scope,
-- default = user.
function M.fetch_last(client, opts, callback)
  opts = opts or {}
  if not M.last_op_available(client) then
    if callback then callback(nil) end
    return
  end
  local causes = {}
  local req = { op = 'analyze-last-stacktrace' }
  if opts.session then req.session = opts.session else req.scope = opts.scope or 'user' end
  client:request(
    req,
    function(message)
      if message.stacktrace or message.class then
        causes[#causes + 1] = {
          class = message.class,
          message = message.message,
          data = message.data,
          stacktrace = message.stacktrace,
        }
      end
      for _, status in ipairs(message.status or {}) do
        if status == 'done' or status == 'no-error' then
          if callback then callback(causes) end
          return
        end
      end
    end)
end

-- Render an eval-time error as a fresh quickfix list: header line, then
-- analyzed frames if available. `opts.header` is the title/first-entry text
-- (e.g. "Campfire: eval error" or "Campfire prep [require]: ...").
function M.render_error(client, opts, callback)
  opts = opts or {}
  local items = {}
  items[#items + 1] = {
    filename = '', lnum = 0, type = 'E',
    text = opts.header or 'Campfire: eval error',
  }
  local function finish()
    quickfix.set(items, opts.title or 'Campfire eval')
    quickfix.populated()
    if callback then callback() end
  end
  M.fetch_last(client, { scope = opts.scope or 'user' }, function(causes)
    if causes then
      for _, e in ipairs(M.causes_to_qf(causes)) do
        items[#items + 1] = {
          filename = e.filename, lnum = e.lnum, type = '', text = e.text,
        }
      end
    end
    finish()
  end)
end

-- Pull a single throw-site {file, line, relative} from an eval-error response,
-- preferring the location already on the wire. nil when none is recoverable
-- (e.g. a bare runtime js/Error whose only frames point into compiled JS). Pure:
-- file is the raw source path as reported, left for the caller to resolve.
-- Handles the err text shapes "… at ns/fn (file:line)" (clj) and "… ns
-- file:line:col" (bb) — those lines are the real source line. Falls back to the
-- structured :ex map nbb/cljs carry (its :data :line + the first absolute :file
-- "/…", the throwing site of an analysis error), whose :line is relative to the
-- eval snippet, not the buffer — relative = true marks it for caller offsetting.
local function error_site(message)
  local err = message.err
  if type(err) == 'string' then
    -- clj: "… at <ns>/<fn> (<file>:<line>)". The ns prefix carries the source
    -- directory the bare <file> lives in, so rebuild a classpath-relative
    -- resource path from it (fireplace#qfmassage does the same): drop the ns's
    -- last segment (which the filename already names) and munge dots → slashes.
    local nsfn, file, line = err:match('at%s+([%w%.%-_%$/]+)%s+%(([^():%s]+):(%d+)%)')
    if file then
      local ns = nsfn:match('^([^/]+)/')
      local dir = ns and ns:match('^(.*)%.[^.]+$')
      if dir then file = (dir:gsub('%-', '_'):gsub('%.', '/')) .. '/' .. file end
    else
      -- shadow/JS frame: "… (<file>:<line>:<col>)" — the path is wrapped in parens,
      -- so match inside them or `%S+` would capture the leading '(' and the path
      -- would no longer read as absolute. This is the innermost frame (the raise
      -- site); the full user-facing chain is :Stacktrace's job.
      file, line = err:match('%(([^()%s:]+):(%d+):%d+%)')
      if not file then
        -- bb: "… <ns> <file>:<line>:<col>" (bare absolute/relative path).
        file, line = err:match('(%S+%.%w+):(%d+):%d+')
      end
    end
    if file and file ~= 'NO_SOURCE_FILE' and file ~= 'REPL' then
      return { file = file, line = tonumber(line) }
    end
  end
  local ex = message.ex
  if type(ex) == 'string' then
    local file = ex:match(':file%s+"(/[^"]+)"')
    local line = ex:match(':line%s+(%d+)')
    if file and line then
      return { file = file, line = tonumber(line), relative = true }
    end
  end
end

-- Drop a one-entry location list at the throw site of an eval-error, so the
-- user can :ll/:lne straight to the offending line without :Stacktrace.
-- No-op (location list untouched, returns false) when no site is recoverable.
-- The file is resolved against the client classpath so a source-relative path
-- jumps to disk. opts carries the originating eval's { line } so a snippet-
-- relative site (nbb/cljs ex) maps back to the buffer line; err-text sites
-- already carry the real source line and are used as-is.
function M.set_error_loc(client, message, opts)
  local site = error_site(message)
  if not site then return false end
  local path = resource.find(client, site.file)
  if type(path) ~= 'string' or path:sub(1, 1) ~= '/' then return false end
  local lnum = site.line or 0
  if site.relative and opts and opts.line then
    lnum = opts.line + math.max(lnum - 1, 0)
  end
  vim.fn.setloclist(0, {}, ' ', {
    title = 'Campfire eval error',
    items = { {
      filename = path,
      lnum = lnum,
      col = 0,
      type = 'E',
      text = oneline(message.err) or 'eval error',
    } },
  })
  return true
end

-- First qf entry that resolves to a real on-disk file (project frame). The
-- analyzed chain lists frames innermost-first, so this is the deepest user
-- frame — where the user wants to land. nil when the chain is all java/deps.
local function top_user_index(items)
  for i, it in ipairs(items) do
    if it.filename and it.filename ~= '' and (it.lnum or 0) > 0 then
      return i
    end
  end
end

-- Open the quickfix window without stealing focus and, when a project frame
-- is present, point the qf cursor at it. Fireplace's :Stacktrace runs copen
-- (which jumps), but campfire keeps the source window focused like its other
-- lists (tests, history).
local function open_and_jump(items)
  local cur = vim.fn.win_getid()
  vim.cmd('botright copen')
  if vim.fn.win_getid() ~= cur then vim.fn.win_gotoid(cur) end
  local idx = top_user_index(items)
  if idx then vim.fn.setqflist({}, 'r', { idx = idx }) end
end

-- Render a cause chain to a fresh quickfix list and open it: header item
-- (class: message, type 'E') followed by one navigable item per frame via
-- causes_to_qf, qf cursor parked at the deepest project frame. Shared by every
-- :Stacktrace path so they produce identical-looking output. `title`
-- is the list title, default = "Campfire stacktrace".
local function render_causes(causes, title)
  local header = causes[1].class or 'Campfire: eval error'
  local m = oneline(causes[1].message)
  if m then header = header .. ': ' .. m end
  local items = { { filename = '', lnum = 0, type = 'E', text = header } }
  for _, e in ipairs(M.causes_to_qf(causes)) do
    items[#items + 1] = { filename = e.filename, lnum = e.lnum, type = '', text = e.text }
  end
  quickfix.set(items, title or 'Campfire stacktrace')
  quickfix.populated()
  open_and_jump(items)
end

local function no_throw()
  vim.api.nvim_echo({ { 'Campfire: expression did not throw', 'MoreMsg' } }, false, {})
end

-- The JVM half of a cider-less capture (clj-bare/bb/lg): render the Throwable
-- bound to `sym` as the delimited string decode_fallback_value parses, built
-- with clojure.core only (no cheshire — it isn't on every cider-less runtime).
-- Layout: class \n <N frames> \n {name TAB method TAB file TAB line} × N \n
-- message. The frame count is emitted up front so a multi-line message (the
-- tail) can't be confused for frames.
local function jvm_extract(sym)
  return '(let [m# (clojure.core/Throwable->map ' .. sym .. ')'
    .. ' via# (clojure.core/-> m# :via clojure.core/first)'
    .. ' trace# (clojure.core/vec (:trace m#))'
    .. ' rows# (clojure.core/map (clojure.core/fn [fr#]'
    .. ' (clojure.core/str (clojure.core/nth fr# 0) "\t" (clojure.core/nth fr# 1)'
    .. ' "\t" (clojure.core/nth fr# 2) "\t" (clojure.core/nth fr# 3))) trace#)]'
    .. ' (clojure.core/apply clojure.core/str (clojure.core/interpose "\n"'
    .. ' (clojure.core/concat [(clojure.core/str (:type via#)) (clojure.core/count trace#)]'
    .. ' rows# [(clojure.core/str (clojure.core/or (:cause m#) (:message via#)))]))))'
end

-- The cljs half of a cider-less capture (nbb/cljs): render the error bound to
-- `sym` as the SAME delimited string jvm_extract builds, so the Lua side stays
-- unified. SCI wraps analysis errors as ExceptionInfo whose ex-data carries
-- :file/:line plus a :sci.impl/callstack volatile of {:file :line} frames — a
-- jumpable cross-file chain (the ex-data :file/:line goes in as the top frame).
-- Bare runtime js/Errors have nil ex-data, so we parse the V8 `.-stack` text:
-- each "    at <name> (<file>:<line>:<col>)" line yields a [name "" file line]
-- frame (resource.find resolves the path — on shadow these are absolute paths
-- into the build's cljs-runtime mirror, which exist on disk and so jump). Lines
-- with no file:line (the message header, "at <anon>") are dropped, never
-- fabricated. try/and/or/when bare — special forms read on SCI. class prefers
-- (:type ex-data) then (.-name) over (type e) (which prints the raw js
-- constructor source on nbb).
local function cljs_extract(sym)
  return '(let [e# ' .. sym .. ' d# (ex-data e#)]'
    .. ' (if d#'
    .. ' (let [csv# (:sci.impl/callstack d#) cs# (when csv# (deref csv#))'
    .. ' frames# (concat (when (:file d#) [["" "" (:file d#) (:line d#)]])'
    .. ' (for [fr# cs# :when (:file fr#)] ["" "" (:file fr#) (:line fr#)]))'
    .. ' rows# (map (fn [fr#] (str (nth fr# 0) "\t" (nth fr# 1) "\t" (nth fr# 2) "\t" (nth fr# 3))) frames#)]'
    .. ' (apply str (interpose "\n"'
    .. ' (concat [(str (or (:type d#) (.-name e#))) (count frames#)] rows# [(str (ex-message e#))]))))'
    .. ' (let [stack# (clojure.string/split-lines (str (.-stack e#)))'
    .. ' parse# (fn [ln#] (let [nm# (or (second (re-find #"\\bat\\s+([^(]+?)\\s*\\(" ln#)) "")'
    .. ' fl# (re-find #"([^()\\s]+):(\\d+):\\d+\\)?\\s*$" ln#)]'
    .. ' (when fl# [(clojure.string/trim nm#) "" (nth fl# 1) (nth fl# 2)])))'
    .. ' frames# (keep parse# stack#)'
    .. ' rows# (map (fn [fr#] (str (nth fr# 0) "\t" (nth fr# 1) "\t" (nth fr# 2) "\t" (nth fr# 3))) frames#)]'
    .. ' (apply str (interpose "\n"'
    .. ' (concat [(or (.-name e#) "js/Error") (count frames#)] rows# [(str (.-message e#))]))))))'
end

-- A cider-less expr request (bb/clj-bare/nbb/lg etc): capture any error the expr
-- throws and return it as one delimited string (see jvm_extract/cljs_extract for
-- the layout), or nil when nothing threw. A reader conditional keeps the form
-- portable: nREPL evals with :read-cond :allow, so the JVM runtimes read the
-- :clj catch + Throwable->map path and SCI reads the :default catch + cljs path
-- (java.lang.Throwable / Throwable->map don't resolve on SCI — the previous
-- JVM-only form failed at analysis there, swallowing the real throw). The js
-- ExceptionInfo SCI wraps every error in is a js/Error, so one instance? check
-- covers both ex-info and bare runtime errors. nREPL pr-strs the returned
-- string, so the value channel is a quoted literal a single json_decode recovers
-- (see decode_fallback_value).
local function fallback_capture_code(expr)
  return '(let [r# (try ' .. expr
    .. ' #?(:clj (catch java.lang.Throwable t# t#) :default (catch :default t# t#)))]'
    .. ' #?(:clj (when (clojure.core/instance? java.lang.Throwable r#) ' .. jvm_extract('r#') .. ')'
    .. ' :default (when (instance? js/Error r#) ' .. cljs_extract('r#') .. ')))'
end

-- A cider-less no-arg request (bb/clj-bare/nbb/lg etc): render the session's
-- last error (*e) as the same delimited string fallback_capture_code returns, or
-- nil when there's no recent error. The cider-less analogue of analyze-last-
-- stacktrace: on nbb *e holds an SCI-wrapped error whose ex-data carries the
-- :file/:line + :sci.impl/callstack even for runtime js/Errors, so the cljs path
-- recovers a jumpable chain the manual catch (which sees the bare js/Error) can't.
-- Runs on the user session — *e is read-only here, so the user's last error is
-- left intact. Reader conditional as in fallback_capture_code.
local function fallback_last_code()
  return '(when *e'
    .. ' #?(:clj ' .. jvm_extract('*e') .. ' :default ' .. cljs_extract('*e') .. '))'
end

-- Decode the value channel of a fallback_capture_code eval into a
-- {class, message, trace=[[name method file line] …]} map, or nil when the expr
-- didn't throw. nREPL pr-strs the returned string, so the value is a quoted
-- literal: json_decode once recovers the real (newline/tab-delimited) text.
local function decode_fallback_value(value)
  if type(value) ~= 'string' or value == '' or value == 'nil' then return nil end
  local ok, flat = pcall(vim.fn.json_decode, value)
  if not ok or type(flat) ~= 'string' then return nil end
  local lines = vim.split(flat, '\n', { plain = true })
  if #lines < 2 then return nil end
  local n = tonumber(lines[2]) or 0
  local trace = {}
  for i = 1, n do
    local p = vim.split(lines[2 + i] or '', '\t', { plain = true })
    trace[#trace + 1] = { p[1], p[2], p[3], tonumber(p[4]) }
  end
  local message = table.concat({ unpack(lines, 3 + n) }, '\n')
  return { class = lines[1], message = message, trace = trace }
end

-- Build a causes-compatible chain from a decoded fallback map so the bb path
-- renders through causes_to_qf like the cider paths. Each trace tuple is
-- [class method file line]; element 0 is the declaring fn/class (the display
-- name), element 2 the file, element 3 the line. Only frames with a string file
-- and a positive integer line become items; the file is resolved against the
-- client classpath so it's jumpable when present on disk.
local function fallback_causes(client, map)
  local stacktrace = {}
  for _, fr in ipairs(map.trace or {}) do
    local file = fr[3]
    local line = tonumber(fr[4])
    if type(file) == 'string' and file ~= '' and line and line > 0 then
      local path = resource.find(client, file)
      stacktrace[#stacktrace + 1] = {
        var = fr[1],
        file = file,
        line = line,
        ['file-url'] = (type(path) == 'string' and path:sub(1, 1) == '/') and ('file://' .. path) or nil,
      }
    end
  end
  return { { class = map.class, message = map.message, stacktrace = stacktrace } }
end

local function no_error()
  vim.api.nvim_echo({ { 'Campfire: no recent error', 'MoreMsg' } }, false, {})
end

-- Eval a cider-less capture form (fallback_capture_code or fallback_last_code),
-- accumulate its value channel, then decode + render the delimited string as a
-- stacktrace. `on_empty` fires when the form returned nil (didn't throw / no
-- recent error). target is the request routing: { session = <id> } targets an
-- explicit session (a clone), else { scope = … } a named scope. Shared by the
-- expr path (a user-session clone, no_throw) and the no-arg path (user scope,
-- no_error).
local function fetch_fallback(client, code, target, title, on_empty)
  local eval = require('campfire.eval')
  local values = {}
  client:request(
    eval.request(vim.tbl_extend('force', { code = code }, target)),
    function(message)
      if message.value then
        for _, v in ipairs(type(message.value) == 'table' and message.value or { message.value }) do
          values[#values + 1] = v
        end
      end
      for _, status in ipairs(message.status or {}) do
        if status == 'done' then
          local map = decode_fallback_value(table.concat(values, ''))
          if not map then return on_empty() end
          render_causes(fallback_causes(client, map), title)
          return
        end
      end
    end)
end

-- Clone the user session, hand the clone's session id to `body`, and close the
-- clone once `body` calls the supplied `done` (so the close fires on every exit
-- branch, throw or not). The clone inherits the user session's *1/*2/*3/*e; on
-- clj/bb it is isolated (a set! in the clone can't touch the user *e), so the
-- expr path can stash into the clone's *e freely. nbb's clone SHARES the SCI
-- dynamic env, so the caller must NOT set! *e on the non-cider path. Best-effort
-- on a clone failure: body is skipped and on_fail (if given) fires.
local function with_user_clone(client, body, on_fail)
  local user_sid = client:session('user')
  if not user_sid then if on_fail then on_fail() end return end
  client:request({ op = 'clone', session = user_sid }, function(message)
    local clone = message['new-session']
    if clone and clone ~= '' then
      local function done() client:request({ op = 'close', session = clone }, function() end) end
      body(clone, done)
    elseif message.status then
      for _, status in ipairs(message.status) do
        if status == 'done' then if on_fail then on_fail() end return end
      end
    end
  end)
end

-- Render the stacktrace of an expr's exception via a per-invocation clone of the
-- user session (which inherits the user's *1/*2/*3/*e so :Stacktrace *1
-- and the like resolve), leaving the user session itself untouched, then close
-- the clone. Branches on cider availability: with cider, (set! *e <expr>) seats
-- the throwable (a throw sets *e directly; an exception VALUE like *1/e/(ex-info)
-- is bound by set!) in the clone's *e — safe because the clj clone is isolated —
-- and analyze-last-stacktrace reads it off the clone; without cider, the form
-- catches the throw-or-value locally and returns the frames as a delimited string
-- (no set!, so nbb's shared *e is never touched). Echoes a notice when nothing
-- exceptional surfaced.
local function fetch_expr(client, expr, title)
  local eval = require('campfire.eval')
  with_user_clone(client, function(clone, done)
    if M.use_analyzed(client) then
      client:request(
        eval.request({ code = '(set! *e ' .. expr .. ')', session = clone }),
        function(message)
          for _, status in ipairs(message.status or {}) do
            if status == 'done' then
              M.fetch_last(client, { session = clone }, function(causes)
                done()
                if not causes or #causes == 0 then return no_throw() end
                render_causes(causes, title)
              end)
              return
            end
          end
        end)
    else
      local values = {}
      client:request(
        eval.request({ code = fallback_capture_code(expr), session = clone }),
        function(message)
          if message.value then
            for _, v in ipairs(type(message.value) == 'table' and message.value or { message.value }) do
              values[#values + 1] = v
            end
          end
          for _, status in ipairs(message.status or {}) do
            if status == 'done' then
              done()
              local map = decode_fallback_value(table.concat(values, ''))
              if not map then return no_throw() end
              render_causes(fallback_causes(client, map), title)
              return
            end
          end
        end)
    end
  end, no_throw)
end

-- On-demand view of a session's live error — campfire's equivalent of
-- fireplace's :Stacktrace. With no expr: analyzes the USER session's live *e —
-- via cider's analyze-last-stacktrace when advertised, else by evaluating an
-- extraction over *e (so nbb/cljs and bare runtimes still surface the last
-- error's frames). With opts.expr: clones the user session per invocation (so it
-- inherits the user's *1/*2/*3/*e), evaluates the expr on the clone, surfaces the
-- stacktrace of the exception it produced (thrown or returned as a value), then
-- closes the clone — the user session's *e/state stay intact. Renders to the
-- quickfix list, opens the window without stealing focus, and points the qf
-- cursor at the deepest project frame. Echoes a friendly notice (rather than
-- erroring) on no recent error or no throw. opts.scope selects the no-expr
-- session, default = user.
function M.command(opts)
  opts = opts or {}
  local client = opts.client
  if not client then
    local campfire = require('campfire')
    local err
    if campfire.ensure_current then
      client, err = campfire.ensure_current()
    else
      client = campfire.current and campfire.current()
    end
    if not client then return 'echoerr ' .. vim.fn.string(err or 'Campfire: no live nREPL connection') end
  end

  local expr = opts.expr
  if type(expr) == 'string' and vim.trim(expr) ~= '' then
    fetch_expr(client, expr, opts.title)
    return ''
  end

  local scope = opts.scope or 'user'
  if not M.use_analyzed(client) then
    fetch_fallback(client, fallback_last_code(), { scope = scope }, opts.title, no_error)
    return ''
  end

  M.fetch_last(client, { scope = scope }, function(causes)
    if not causes or #causes == 0 then return no_error() end
    render_causes(causes, opts.title)
  end)
  return ''
end

M._top_user_index = top_user_index
M._fallback_capture_code = fallback_capture_code
M._fallback_last_code = fallback_last_code
M._decode_fallback_value = decode_fallback_value
M._error_site = error_site

return M
