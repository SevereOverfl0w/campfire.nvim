local runtime = require('campfire.runtime')

local M = {}

-- Per-connection ns-load cache TTL. After this window the next ensure_loaded
-- runs the find-ns probe again, so out-of-band server state (manual
-- remove-ns, tools.namespace refresh without wrap-tracker, etc.) is picked
-- up. Cheap enough on clj/bb (sub-ms p50); piggieback's probe runs on main
-- so it queues behind user evals — keep TTL high enough that interactive
-- editing stays in cache. 20s matches kindling strategy spec.
M.TTL_MS = 20000

-- Per-eval timeout. Bounds find-ns / require / load-file requests so a
-- lost response or hung server doesn't leave the foreground polling loop
-- spinning forever. 5s comfortably covers the slowest measured runtime
-- (piggieback's 8-require cold load at ~143ms); anything beyond that is a
-- pathology, not a slow load.
M.TIMEOUT_MS = 5000

local PARTIAL = 'partial'

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

-- Read the cached load-state for an ns on this client.
--
-- Returns nil for the unknown / expired / never-seen case (caller probes),
-- 'loaded' when the ns was last loaded via require/load-file and the entry is
-- inside the TTL window, 'partial' when scratch-prime fired and the ns has
-- only refers (caller skips probe + goes straight to tmp-file load-file).
function M.cache_get(client, ns)
  if not client or not client.loaded_ns then return nil end
  local entry = client.loaded_ns[ns]
  if not entry then return nil end
  if entry == PARTIAL then return PARTIAL end
  if type(entry) == 'table' and entry.at and (now_ms() - entry.at) < M.TTL_MS then
    return 'loaded'
  end
  return nil
end

function M.cache_set(client, ns, state)
  client.loaded_ns = client.loaded_ns or {}
  if state == 'loaded' then
    client.loaded_ns[ns] = { at = now_ms() }
  elseif state == 'partial' then
    client.loaded_ns[ns] = PARTIAL
  else
    client.loaded_ns[ns] = nil
  end
end

-- Wipe the whole cache for this client. Wired to FocusGained / BufEnter-after-
-- BufLeave by the autocmd installer in Phase 5; also reachable from tests.
function M.cache_clear(client)
  client.loaded_ns = {}
end

-- Where the cold-load eval probes run. clj/bb keep main session clean by
-- routing find-ns + require + io/resource to tooling. cljs runtimes can't —
-- the analyzer / compiler-env lives in main, so a JVM tooling session can't
-- see cljs vars. nbb has only one session.
function M.load_scope(client)
  return ({ clj = 'tool', bb = 'tool', lg = 'tool' })[client and client.lang] or 'user'
end

local load_scope = M.load_scope

-- io/resource always runs on the JVM, so for piggieback/shadow it stays on
-- tooling even though find-ns has to run on main. nbb has no JVM and no
-- tooling session — return nil so callers know to use the client-side replica.
local function classpath_scope(client)
  local lang = client and client.lang
  if lang == 'nbb' then return nil end
  return 'tool'
end

local function repl_user_ns(client)
  return ({ cljs = 'cljs.user', nbb = 'cljs.user' })[client and client.lang] or 'user'
end

local function ns_to_path(ns)
  return (ns:gsub('%-', '_'):gsub('%.', '/'))
end

local function ext_for_lang(lang)
  return ({ cljs = '.cljs', nbb = '.cljs', lg = '.lg' })[lang] or '.clj'
end

-- Err patterns that indicate the ns isn't on the classpath (vs the file
-- being on-cp but blowing up during load). Caller routes the former to
-- scratch-prime / load-file fallback and the latter to attribution.
-- Patterns confirmed against .scratch/ns-loading2 harness traces.
local NOT_ON_CP_PATTERNS = {
  'Could not find namespace',                     -- clj + sci + nbb
  'Could not locate',                             -- clj for missing files
  'FileNotFoundException',                        -- jvm under-the-hood
  'Could not find or load',                       -- shadow
  '%[file%-not%-found%]',                         -- nbb sci variant
  'Use of undeclared Var',                        -- shadow cljs runtime
  'No such namespace',                            -- shadow alt phrasing
}

function M.classify_err(err)
  if type(err) ~= 'string' or err == '' then return 'unknown' end
  for _, pat in ipairs(NOT_ON_CP_PATTERNS) do
    if err:match(pat) then return 'not-on-cp' end
  end
  return 'eval-error'
end

local function status_has(msg, name)
  for _, s in ipairs(msg.status or {}) do
    if s == name then return true end
  end
  return false
end

-- A probe reply is truthy iff its printed value is exactly `true`.
local function is_true(v)
  return type(v) == 'string' and v:match('^%s*true%s*$') ~= nil
end

-- Truncate a code body for display in error messages. Long bodies bury
-- the user in cmdline; the first 80 chars usually identifies the probe.
local function elide(s, n)
  s = tostring(s or '')
  s = s:gsub('%s+', ' ')
  if #s <= n then return s end
  return s:sub(1, n - 1) .. '…'
end

-- Single-request eval helper that accumulates value + err + ex across
-- streamed responses and fires `cb` once on done. nREPL responses for one
-- op can split across many messages (out / err / value / status), so the
-- callback wraps the whole life-cycle. On timeout, client.lua's
-- M.timeout.drop synthesises a done+err='timeout' response; we treat that
-- as eval_error and annotate the state with `timeout = true` so callers
-- can attribute the failure precisely.
--
-- state on cb fire:
--   value       — concatenated value chunks (string or nil)
--   err         — concatenated err stream
--   ex          — final ex field if any
--   eval_error  — true on status⊇{eval-error|error}
--   timed_out   — true when M.timeout.drop fired
--   elapsed_ms  — wall-clock ms from send to done
--   code        — the body sent (echoed back so callers can build error msgs)
--   scope       — the scope used
local function send_eval(client, opts, cb)
  local started = now_ms()
  local state = {
    value = nil, err = nil, ex = nil,
    eval_error = false, timed_out = false,
    code = opts.code, scope = opts.scope or 'user',
  }
  local fired = false
  local function fire()
    if fired then return end
    fired = true
    state.elapsed_ms = math.floor(now_ms() - started + 0.5)
    cb(state)
  end
  -- timeout_ms / on_inflight are per-call: read probes pass a bound; the cold
  -- require/load-file pass none (wait for the real done) plus an on_inflight
  -- hook so a user Ctrl-C in the foreground loop can interrupt them.
  local handle = client:request({
    op = 'eval',
    code = opts.code,
    ns = opts.ns,
    scope = state.scope,
    timeout_ms = opts.timeout_ms,
  }, function(msg)
    if msg.value then state.value = (state.value or '') .. msg.value end
    if msg.err then state.err = (state.err or '') .. msg.err end
    if msg.ex then state.ex = msg.ex end
    if status_has(msg, 'eval-error') or status_has(msg, 'error') then
      state.eval_error = true
    end
    for _, s in ipairs(msg.status or {}) do
      if s == 'timeout' then state.timed_out = true end
    end
    if status_has(msg, 'done') then fire() end
  end)
  if opts.on_inflight then opts.on_inflight(handle.id) end
end

-- Compose a diagnostic line for a failed prep eval: distinguishes
-- timeout vs server-side throw, includes the elapsed wall-clock, scope,
-- and an elided form of the code we sent. Lets the user tell "probe
-- never responded" apart from "probe ran but the form blew up".
local function diagnose(state, fallback)
  if state.timed_out then
    return string.format(
      'timeout after %dms on %s session (limit %dms) — sent: %s',
      state.elapsed_ms or 0, state.scope, M.TIMEOUT_MS, elide(state.code, 80))
  end
  local reason = state.err or state.ex or fallback or 'no value'
  return string.format(
    '%s (%dms on %s session, sent: %s)',
    vim.trim(tostring(reason)), state.elapsed_ms or 0, state.scope, elide(state.code, 80))
end

-- Probe `(some-> (find-ns 'X) ns-publics seq)` — distinguishes a fully-loaded
-- ns (has user vars) from an interned-empty one (only refers, no defns).
-- The empty case is real: out-of-band (create-ns 'X), or our own scratch-
-- prime fallback after a failed cold-load.
local function fire_find_ns(client, ns, cb)
  -- Bare symbols throughout: find-ns / ns-publics / seq / boolean / some->
  -- all refer in from clojure.core in clj/bb and cljs.core in cljs/nbb,
  -- so they resolve under either user or cljs.user without a qualifier.
  -- Qualifying as clojure.core/require / clojure.core/in-ns breaks on
  -- cljs because those symbols don't exist in cljs.core (require / in-ns
  -- are REPL special forms there).
  --
  -- lg (let-go) has find-ns but not ns-publics — degrades to the bare
  -- (some? (find-ns 'X)) form. Loses the loaded-vs-interned-empty
  -- distinction, accept since lg has a simpler REPL model.
  local code
  if client and client.lang == 'lg' then
    code = "(some? (find-ns '" .. ns .. "))"
  else
    code = "(boolean (some-> (find-ns '" .. ns .. ") ns-publics seq))"
  end
  send_eval(client, {
    code = code,
    ns = repl_user_ns(client),
    scope = load_scope(client),
    timeout_ms = M.TIMEOUT_MS,
  }, function(state)
    if state.eval_error then return cb(false, diagnose(state, 'eval-error')) end
    if state.value == nil then return cb(false, diagnose(state, 'no value returned')) end
    cb(is_true(state.value), nil)
  end)
end

-- Server-side classpath probe via clojure.java.io/resource. JVM-only (clj /
-- bb / piggieback / shadow); nbb gets the client-side replica via the
-- nbb_classpath Lua loop. Caller checks classpath_scope first.
local function fire_classpath_server(client, ns, lang_ext, cb)
  local path = ns_to_path(ns) .. lang_ext
  -- classpath_scope routes us to the JVM tooling session for every cljs
  -- runtime (piggieback / shadow), so qualifying as clojure.core/some? +
  -- clojure.java.io/resource is safe — this never executes under cljs/nbb.
  local code = '(clojure.core/some? (clojure.java.io/resource "' .. path .. '"))'
  send_eval(client, {
    code = code,
    ns = repl_user_ns(client),
    scope = 'tool',
    timeout_ms = M.TIMEOUT_MS,
  }, function(state)
    if state.eval_error then return cb(false, nil, diagnose(state, 'eval-error')) end
    cb(is_true(state.value), path, nil)
  end)
end

-- Client-side classpath probe for nbb. Walks the cached nbb_classpath list
-- (populated by Phase 2) and returns the first on-disk hit. Returns
-- (on_cp, abs_path) so caller can compare against buffer text if needed.
local function fire_classpath_nbb(client, ns, cb)
  if not client.nbb_classpath then return cb(false, nil, 'nbb classpath cache missing') end
  local base = ns_to_path(ns)
  for _, dir in ipairs(client.nbb_classpath) do
    for _, ext in ipairs({ '.cljs', '.cljc', '.clj' }) do
      local candidate = dir:gsub('/+$', '') .. '/' .. base .. ext
      local ok, st = pcall(vim.uv.fs_stat, candidate)
      if ok and st and st.type == 'file' then
        return cb(true, candidate, nil)
      end
    end
  end
  cb(false, nil, nil)
end

-- Public probe entry. Dispatches per dialect.
function M.fire_classpath(client, ns, cb)
  local scope = classpath_scope(client)
  if scope == nil then return fire_classpath_nbb(client, ns, cb) end
  return fire_classpath_server(client, ns, ext_for_lang(client.lang), cb)
end

-- (require 'X). On success cache becomes 'loaded'. On failure caller
-- classifies the err and routes to fallback.
--
-- No timeout: a cold require can legitimately take tens of seconds (large dep
-- trees) — we wait for the real `done` rather than synthesising one. A
-- premature timeout would let the user eval fire on the main session while this
-- require is still loading on tooling; the two then race Clojure's loader
-- (partial namespaces → "random var" errors), and an interrupt can't cleanly
-- cancel a mid-flight load on any backend. on_inflight surfaces the request id
-- so a user Ctrl-C in the foreground loop targets this require.
local function cold_require(client, ns, opts, cb)
  -- Bare `(require 'X)`: in clj/bb refers from clojure.core (a normal fn);
  -- in cljs (piggieback / shadow) the cljs analyzer recognises it as the
  -- top-level REPL special form (cljs.core has no `require` function, so
  -- a qualified form would unresolve). nbb's sci honours bare require too.
  send_eval(client, {
    code = "(require '" .. ns .. ")",
    ns = repl_user_ns(client),
    scope = load_scope(client),
    on_inflight = opts and opts.on_inflight,
  }, function(state)
    if state.eval_error then
      -- Pass the bare err string out so the classifier can match
      -- against patterns ("Could not locate" etc) without the
      -- elapsed-ms / scope decoration in the way; with_prep
      -- re-decorates for user-facing display via diagnose().
      return cb(false, state.err or state.ex or 'eval-error', state)
    end
    cb(true, nil, state)
  end)
end

-- Scratch-prime: install (in-ns 'X) + (refer-clojure) so the user's
-- interactive forms have a refers-only ns to land in. Two sequential eval
-- ops because cljs has no in-ns fn (it's a REPL special form, must stand
-- alone). Cache flips to 'partial' on success — caller of ensure_loaded
-- will route to load-file on subsequent hits if the user fixes the file.
local function scratch_prime(client, ns, cb)
  -- Always main: the in-ns frame switch lands where user code runs.
  -- Bare in-ns / refer-clojure: in cljs `in-ns` is a REPL special form
  -- (not a fn), so `clojure.core/in-ns` would unresolve. clj/bb route
  -- in-ns through clojure.core via the user ns refers. nbb's sci treats
  -- `(in-ns 'X)` as inert (returns the ns object, doesn't switch); that's
  -- expected — the nbb eval-prefix workaround handles ns-switching for
  -- nbb, scratch-prime is a no-op step there but still cheap to issue.
  local scope = 'user'
  send_eval(client, {
    code = "(in-ns '" .. ns .. ")",
    ns = repl_user_ns(client),
    scope = scope,
    timeout_ms = M.TIMEOUT_MS,
  }, function(state)
    if state.eval_error then return cb(false, 'in-ns: ' .. diagnose(state, 'eval-error')) end
    -- Qualified (clojure.core/refer-clojure): after (in-ns 'X), the new
    -- ns has zero refers, so a bare `refer-clojure` symbol doesn't
    -- resolve — drive against clj shows "Unable to resolve symbol:
    -- refer-clojure". The qualified form works on clj because the macro
    -- lives at clojure.core/refer-clojure; on cljs the analyzer auto-
    -- aliases clojure.core → cljs.core for macro calls in this position.
    send_eval(client, {
      code = '(clojure.core/refer-clojure)',
      ns = ns,
      scope = scope,
      timeout_ms = M.TIMEOUT_MS,
    }, function(state2)
      if state2.eval_error then
        return cb(false, 'refer-clojure: ' .. diagnose(state2, 'eval-error'))
      end
      cb(true, nil)
    end)
  end)
end

-- Tmp-file naming per kindling strategy spec §"Tmp file naming". Sibling of
-- the buffer's saved file (hidden, random tag) so the runtime's classpath
-- resolver sees it from the same dir as the real file. For an unsaved
-- scratch buffer there's no source dir, so use tempname() + derive basename
-- from the ns. Caller cleans up via vim.uv.fs_unlink (saved-file case) or
-- vim.fn.delete(dir, 'rf') (scratch case).
function M.tmp_path(opts)
  opts = opts or {}
  local rand = math.random(100000, 999999)
  if opts.file and opts.file ~= '' then
    local dir = vim.fn.fnamemodify(opts.file, ':h')
    local basename = vim.fn.fnamemodify(opts.file, ':t')
    return {
      path = dir .. '/.preload_' .. rand .. '_' .. basename,
      kind = 'sibling',
      cleanup_dir = nil,
    }
  end
  local tmp = vim.fn.tempname()
  local sub = ns_to_path(opts.ns or ('scratch_' .. rand))
  local dir = tmp .. '/' .. vim.fn.fnamemodify(sub, ':h')
  vim.fn.mkdir(dir, 'p')
  local ext = ext_for_lang(opts.lang or 'clj')
  return {
    path = tmp .. '/' .. sub .. ext,
    kind = 'scratch',
    cleanup_dir = tmp,
  }
end

-- Send op=load-file with the buffer text. clj/bb honour the `file` content
-- directly; shadow/piggieback ignore `file` and read disk from `file-path`,
-- so we write the buffer text to a tmp path first.
function M.send_load_file(client, opts, cb)
  local tmp = opts.tmp
  -- Like cold_require: a buffer load can be slow, so no timeout (wait for the
  -- real done), and on_inflight so a user Ctrl-C can interrupt it.
  local handle = client:request({
    op = 'load-file',
    file = opts.text,
    ['file-name'] = vim.fn.fnamemodify(tmp.path, ':t'),
    ['file-path'] = tmp.path,
    scope = 'user',
  }, function(msg)
    if not status_has(msg, 'done') then return end
    local errs = (msg.err or '') .. (msg.ex or '')
    local had_error = status_has(msg, 'eval-error') or status_has(msg, 'error')
    cb(not had_error, had_error and (errs ~= '' and errs or nil) or nil)
  end)
  if opts.on_inflight then opts.on_inflight(handle.id) end
end

-- Orchestrator entry. Caller passes (client, ns, kind, opts, cb) where
--   kind     = 'ns' or 'in-ns' (from runtime.detect_ns)
--   opts.file       = absolute path of buffer file or '' for scratch
--   opts.buffer_text = current buffer text (optional, only used for
--                      tmp-file load-file path)
--   opts.bufnr      = buffer number for scratch dirty check (optional)
--
-- cb signature: cb(err) — err is the tagged "Campfire prep [...]: ..." or
-- nil on success.
function M.ensure_loaded(client, ns, kind, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  if not client or not ns or ns == '' then return cb(nil) end

  -- squint has no ns to load: a "namespace" is compile-time keys in the
  -- shared ns-state atom, populated by vite when it compiles the served
  -- files; the eval op's :ns just `assoc`s :current onto that atom (it even
  -- creates an unknown ns lazily). There is nothing to probe (find-ns /
  -- ns-publics are undefined) and nothing to load (load-file is stubbed,
  -- require is a no-op). Eval directly.
  if client.lang == 'squint' then return cb(nil) end

  local state = M.cache_get(client, ns)
  if state == 'loaded' then return cb(nil) end

  -- Partial state: skip probe, go straight to tmp-file load-file using the
  -- buffer text. If load-file succeeds the cache flips to 'loaded' and the
  -- partial state is gone.
  if state == 'partial' then
    return M._do_load_file(client, ns, opts, cb)
  end

  fire_find_ns(client, ns, function(loaded, err)
    if err then
      cb(M._fail('find-ns probe', err))
      return
    end
    if loaded then
      M.cache_set(client, ns, 'loaded')
      return cb(nil)
    end
    M._cold_load(client, ns, kind, opts, cb)
  end)
end

-- Cold-load path: ns is not loaded server-side. Fire classpath probe in
-- parallel with the require, branch on result.
function M._cold_load(client, ns, kind, opts, cb)
  -- kind=in-ns shortcuts the classpath compare. The buffer is a subfile of
  -- some parent ns; require pulls it transitively (clj/bb) or just primes
  -- (cljs).
  if kind == 'in-ns' then
    return M._try_require(client, ns, opts, cb)
  end

  -- lg has no clojure.java.io/resource and no (in-ns) ns-switch / load-file
  -- equivalent. Skip the classpath compare + scratch-prime fallback: just
  -- (require 'X) and surface whatever err the runtime returns.
  if client.lang == 'lg' then
    return M._try_require_lg(client, ns, opts, cb)
  end

  M.fire_classpath(client, ns, function(on_cp, _path, cp_err)
    if cp_err then
      -- non-fatal: treat as not-on-cp and let require's classifier decide
      on_cp = false
    end
    if not on_cp then
      -- not on classpath: scratch-prime so user's interactive forms land
      -- somewhere refers-aware. cache becomes 'partial' so the next call
      -- routes to load-file (which can pick up a freshly-typed (ns ...)
      -- form once user types it).
      return M._do_scratch_prime(client, ns, cb)
    end
    M._try_require(client, ns, opts, cb)
  end)
end

-- lg-only cold load. (require 'X) routes through lg's own loader, which
-- has no notion of `:reload` / classpath probing / scratch-prime — and lg
-- has no `(in-ns)` runtime function, so fallback to refers-only is also
-- unavailable. Surface success or the raw err; no recovery.
function M._try_require_lg(client, ns, opts, cb)
  cold_require(client, ns, opts, function(ok, err, state)
    if ok then
      M.cache_set(client, ns, 'loaded')
      return cb(nil)
    end
    cb(M._fail('require', state and diagnose(state, err) or (err or 'unknown error')))
  end)
end

function M._try_require(client, ns, opts, cb)
  cold_require(client, ns, opts, function(ok, err, state)
    if ok then
      M.cache_set(client, ns, 'loaded')
      return cb(nil)
    end
    local kind = M.classify_err(err)
    if kind == 'not-on-cp' then
      -- The buffer's (ns X (:require ...)) is the source of truth: write
      -- buffer text to tmp + op=load-file so server picks up declared
      -- aliases.
      return M._do_load_file(client, ns, opts, cb)
    end
    -- File's top-level threw / compile error. Scratch-prime so user has a
    -- bare ns to land interactive forms in, and surface the original err
    -- annotated with timing + scope so timeout vs throw is unambiguous.
    M._do_scratch_prime(client, ns, function(_)
      local detail = state and diagnose(state, err) or (err or 'unknown error')
      cb(M._fail('require', detail))
    end)
  end)
end

function M._do_scratch_prime(client, ns, cb)
  scratch_prime(client, ns, function(ok, err)
    if not ok then
      return cb(M._fail('scratch-prime', err or 'unknown error'))
    end
    M.cache_set(client, ns, 'partial')
    cb(nil)
  end)
end

function M._do_load_file(client, ns, opts, cb)
  local text = opts.buffer_text
  if not text or text == '' then
    -- Caller didn't pass buffer text but cache says we need load-file.
    -- Fall back to scratch-prime so the user at least has a refers-aware
    -- ns to eval into.
    return M._do_scratch_prime(client, ns, function(serr)
      if serr then return cb(serr) end
      cb(M._fail('load-file', 'no buffer text available'))
    end)
  end
  local tmp = M.tmp_path({ file = opts.file, ns = ns, lang = client.lang })
  local fd, oerr = vim.uv.fs_open(tmp.path, 'w', 420)
  if not fd then
    return cb(M._fail('load-file', 'tmp open failed: ' .. tostring(oerr)))
  end
  vim.uv.fs_write(fd, text, 0)
  vim.uv.fs_close(fd)

  M.send_load_file(client, { text = text, tmp = tmp, on_inflight = opts.on_inflight }, function(ok, err)
    -- Cleanup tmp regardless of outcome.
    if tmp.kind == 'sibling' then
      pcall(vim.uv.fs_unlink, tmp.path)
    else
      pcall(vim.fn.delete, tmp.cleanup_dir, 'rf')
    end
    if ok then
      M.cache_set(client, ns, 'loaded')
      return cb(nil)
    end
    cb(M._fail('load-file', err or 'unknown error'))
  end)
end

-- Tagged error formatter. Phase 7 wires the writeln; for now callers
-- propagate the string up the cb chain so eval/operator surfaces can echo
-- it in their own style.
function M._fail(step, detail)
  return 'Campfire prep [' .. step .. ']: ' .. tostring(detail)
end

-- Inspect a streamed nREPL response for signals that the server's view of
-- an ns has diverged from the cache. Drops cache entries so the next
-- ensure_loaded re-probes + reloads. Three signals:
--
--   1. status ⊇ {namespace-not-found} — clj's structured marker.
--   2. err matching /No namespace:\s+<ns>\s+found/ — bb (no structured
--      status); falls back to text regex.
--   3. message.changed-namespaces — cider-nrepl wrap-tracker reports
--      these proactively when tools.namespace/refresh fires or the user
--      runs remove-ns.
--
-- Repair is gated on `pre_ns_loaded` in the user-op opts: a stale-cache
-- repair fires only when the cache claimed the ns was loaded. Cold or
-- typo cases (cache was nil) don't trigger repair — the original error
-- is the user's signal.
function M.inspect_response(client, opts, message)
  if not client or not message then return end

  local ns = opts and opts.ns
  if ns and opts.pre_ns_loaded then
    local needs = false
    for _, s in ipairs(message.status or {}) do
      if s == 'namespace-not-found' then needs = true end
    end
    if not needs and type(message.err) == 'string'
        and message.err:match('No namespace:%s+%S+%s+found') then
      needs = true
    end
    if needs then M.cache_set(client, ns, nil) end
  end

  local changed = message['changed-namespaces']
  if type(changed) == 'table' then
    for _, name in ipairs(changed) do
      if type(name) == 'string' then M.cache_set(client, name, nil) end
    end
  end
end

return M
