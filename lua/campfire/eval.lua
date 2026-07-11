local history = require('campfire.history')
local pretty = require('campfire.pretty')
local prep = require('campfire.prep')
local runtime = require('campfire.runtime')
local stacktrace = require('campfire.stacktrace')

local M = {}

local function current_client()
  return require('campfire').ensure_current()
end

local ECHO_GROUP = { out = 'Question', err = 'WarningMsg', value = 'None' }

-- shadow-cljs reports an eval throw with NO eval-error status and NO :ex map —
-- only err-channel text plus this exact sentinel on the value channel. Detecting
-- it lets the throw-site loclist + error handling fire on shadow like everywhere
-- else; it's also suppressed from the value echo (it isn't a real result).
local SHADOW_EXCEPTION = ':repl/exception!'

local function vim_dquote(s)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
  return '"' .. s .. '"'
end

-- Mirrors vim-fireplace's s:echon (autoload/fireplace.vim ~line 1228).
-- Each chunk's trailing newline is held in state.buffer instead of being
-- emitted; subsequent chunks land on the same cmdline run via :echon, so
-- streamed out/value fragments concatenate into one logical message.
--
-- nvim_echo + opts.id was tried first but the default cmdline UI doesn't
-- collapse id-tagged messages in place — each call still printed all
-- accumulated chunks, so users saw earlier fragments repeated. Only
-- ext_messages-aware UIs honour the id.
--
-- Called synchronously from the eval response callback, which already runs
-- in vim.schedule context (transport.on_message safe_call). Wrapping in
-- another vim.schedule would defer the echo past M.foreground's exit and
-- the cmdline would clear before the result rendered.
local function echon(state, text, kind)
  if not text or text == '' then return end
  local combined = (state.buffer or '') .. text
  local trailing = combined:sub(-1) == '\n' and '\n' or ''
  state.buffer = trailing
  local printable = trailing == '' and combined or combined:sub(1, -2)
  if printable == '' then return end
  vim.cmd('echohl ' .. (ECHO_GROUP[kind] or 'None'))
  vim.cmd('echon ' .. vim_dquote(printable))
  vim.cmd('echohl None')
end

function M.request(opts)
  opts = opts or {}
  return {
    op = 'eval',
    code = opts.code or '',
    ns = opts.ns,
    session = opts.session,
    scope = opts.scope or 'user',
    file = opts.file,
    line = opts.line,
    column = opts.column,
    runtime = opts.runtime,
  }
end

local function start_eval(client, opts, callback, echo_state)
  local entry = history.start({
    code = opts.code or '',
    runtime = opts.runtime or 'auto',
    file = opts.file,
    line = opts.line,
    column = opts.column,
  })
  local silent = opts.silent
  local req = pretty.apply(M.request(opts), client)
  -- Accumulate the error channels across the request. clj/bb split err and ex
  -- across separate messages (and only ex carries the eval-error status); nbb
  -- emits no eval-error status at all, just err + ex. Coalescing both lets the
  -- one throw-site loclist fire from a single done-time view (see below).
  local err_acc = { saw_error = false }
  local handle = client:request(req, function(message)
    history.record(entry, message)
    prep.inspect_response(client, opts, message)
    local shadow_error = message.value == SHADOW_EXCEPTION
    if not silent then
      if message.out then echon(echo_state, message.out, 'out') end
      if message.err then echon(echo_state, message.err, 'err') end
      -- Terminate each value with a newline so consecutive form values don't
      -- glue (nREPL sends one value message per top-level form, but the value
      -- text carries no trailing newline). echon holds the trailing \n in its
      -- buffer, so the final value's newline is swallowed — no dangling blank.
      if message.value and not shadow_error then echon(echo_state, message.value .. '\n', 'value') end
    end
    if message.err then err_acc.err = (err_acc.err or '') .. message.err end
    if message.ex then err_acc.ex = message.ex; err_acc.saw_error = true end
    if shadow_error then err_acc.saw_error = true end
    if callback then callback(message) end
    for _, status in ipairs(message.status or {}) do
      if status == 'eval-error' then err_acc.saw_error = true end
      if status == 'done' then
        -- On an interactive eval throw, drop a single jumpable loclist entry at
        -- the throw site — the location is already on the wire (err text on
        -- clj/bb, the structured ex on nbb/cljs) so no extra round-trip. The
        -- full frame chain stays :Stacktrace's job. Suppressible via
        -- config.
        if err_acc.saw_error and not silent
            and require('campfire.config').get().eval_error_loclist then
          stacktrace.set_error_loc(client, err_acc, opts)
        end
        history.finish(entry)
        -- Track the newest eval in an open :Last preview, like fireplace's
        -- s:RefreshLast. No-op when the preview is closed.
        history.refresh_preview()
      end
    end
  end)
  entry.id = handle.id
  return handle, entry
end

-- Piggieback's op=eval reads ONE form per request (cider/piggieback#98, never
-- merged — reader-state semantics make atomic multi-form unsafe). Subsequent
-- forms silently drop. Split client-side, send sequentially. Each form gets
-- its own file/line so jump-to-def stays accurate on piggieback >= 0.6.0.
local function chained_eval(client, opts, callback)
  local base_line = opts.line or 1
  local base_column = opts.column or 1
  local forms = runtime.forms(opts.code or '', base_line, base_column)
  if #forms <= 1 then return nil end
  local echo_state = { buffer = '' }
  if not opts.silent then vim.cmd('echo ""') end

  local proxy = { done = false }
  local current_ns = opts.ns
  local i = 1
  local function fire_next()
    if i > #forms then
      proxy.done = true
      return
    end
    local f = forms[i]
    i = i + 1
    local sub = vim.tbl_extend('force', {}, opts, {
      code = f.code, line = f.line, column = f.column, ns = current_ns,
    })
    -- Piggieback's response ns field can echo the session's stored ns rather
    -- than the post-(ns) state, so trust the code: parse (ns X) / (in-ns X)
    -- from the form text and propagate to subsequent forms in the chain.
    local form_declared_ns = runtime.detect_ns(f.code)
    local done_for_form = false
    local handle = start_eval(client, sub, function(message)
      if callback then callback(message) end
      if not done_for_form and vim.tbl_contains(message.status or {}, 'done') then
        done_for_form = true
        if form_declared_ns then current_ns = form_declared_ns end
        proxy.id = nil
        vim.schedule(fire_next)
      end
    end, echo_state)
    proxy.id = handle.id
  end
  fire_next()
  return proxy
end

-- nbb's eval handler resolves vars against the eval frame's *ns*, not the
-- request's `ns` field. Without intervention, every cp on a buffer whose ns
-- ≠ cljs.user fails (`Could not resolve symbol`). Workaround per kindling
-- strategy spec §"nbb ns-switch workaround": prefix `(ns X)\n` + (column-1)
-- spaces to the user code, decrement :line by 1. The prefix occupies one
-- line so :line-1 cancels it; the \n resets reader column to 1, the pad
-- spaces restore the column of the original first form so any column-aware
-- error reporting still maps.
--
-- Skips:
--   * code already starts with (ns <opts.ns>) — whole-buffer reload, form 1
--     IS the ns macro; would duplicate.
--   * opts.ns is the REPL default (cljs.user) — nbb is already there.
--   * non-nbb dialects — they honour the `ns` field on eval directly.
local function apply_nbb_prefix(client, opts)
  if client.lang ~= 'nbb' then return opts end
  if not opts.ns or opts.ns == '' or opts.ns == 'cljs.user' then return opts end
  local existing = runtime.detect_ns(opts.code or '')
  if existing == opts.ns then return opts end

  local column = opts.column or 1
  local pad = string.rep(' ', math.max(column - 1, 0))
  local prefix = '(ns ' .. opts.ns .. ')\n' .. pad
  local out = vim.tbl_extend('force', {}, opts)
  out.code = prefix .. (opts.code or '')
  out.line = math.max((opts.line or 1) - 1, 1)
  return out
end

function M.eval(client, opts, callback)
  opts = opts or {}
  if not client then
    local err
    client, err = current_client()
    if not client then return nil, err or 'Campfire: no live nREPL connection' end
  end

  if client.piggieback then
    local chained = chained_eval(client, opts, callback)
    if chained then return chained end
  end

  opts = apply_nbb_prefix(client, opts)

  local echo_state = { buffer = '' }
  if not opts.silent then
    -- Mirror fireplace's pre-eval `echo ""` so :echon chunks land on a fresh
    -- cmdline run.
    vim.cmd('echo ""')
  end
  return (start_eval(client, opts, callback, echo_state))
end

M._apply_nbb_prefix = apply_nbb_prefix

-- Run prep.ensure_loaded for opts.ns first, then fire M.eval. opts is
-- expected to carry { ns, file, bufnr } so prep can derive buffer text on
-- the not-on-cp fallback. Hard prep failures echo via err_writeln and
-- short-circuit the user op; soft success continues into eval transparent
-- to the caller.
--
-- Returns immediately with a proxy handle whose `id` becomes set once eval
-- fires. Callers using M.foreground tolerate a nil id (treats as not-yet-
-- started) until the prep callback resolves.
function M.with_prep(client, opts, callback)
  opts = opts or {}
  if not client then
    local err
    client, err = current_client()
    if not client then return nil, err or 'Campfire: no live nREPL connection' end
  end

  local ns = opts.ns
  if not ns or ns == '' then
    return M.eval(client, opts, callback)
  end

  -- Detect ns/in-ns kind off the buffer so prep picks the right branch.
  local bufnr = opts.bufnr
  local text = opts.buffer_text
  if (not text or text == '') and bufnr then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    text = table.concat(lines, '\n')
  end
  local _, kind = runtime.detect_ns(text or '')
  kind = kind or 'ns'

  -- Snapshot whether the cache claimed the ns was loaded BEFORE the prep
  -- pass kicks off. The response inspector uses this to gate stale-cache
  -- repair: a `namespace-not-found` only invalidates if we thought we had
  -- it.
  local pre_loaded = prep.cache_get(client, ns) == 'loaded'

  local proxy = {}
  prep.ensure_loaded(client, ns, kind, {
    file = opts.file ~= '' and opts.file or nil,
    buffer_text = text,
    bufnr = bufnr,
    -- Surface each in-flight preamble request id so M.foreground can target a
    -- user Ctrl-C at the still-running require / load-file: proxy.id stays nil
    -- until the user eval itself fires.
    on_inflight = function(id) proxy.prep_id = id end,
  }, function(err)
    -- User aborted (Ctrl-C in the foreground loop) while the preamble was in
    -- flight. The interrupt resolves the require with a `done`, which lands
    -- here — but firing the user eval now would defeat the abort.
    if proxy.aborted then return end
    if err then
      -- Preamble is best-effort context-setting, not a gate: surface why it
      -- failed but still run the eval. A self-contained form then succeeds
      -- even when its ns failed to load (e.g. a sibling compile error); a
      -- form that does depend on the unloaded ns errors on its own — same as
      -- typing it at a raw REPL. Fall through to M.eval below.
      vim.schedule(function() vim.api.nvim_err_writeln(err) end)
      -- For require/load-file step errors, the failing eval is still the
      -- session's last; analyze-last-stacktrace returns its analyzed frames.
      -- Surface them via qf so the user can jump to the offending line.
      if err:match('%[require%]') or err:match('%[load%-file%]') then
        stacktrace.render_error(client, { header = err, scope = prep.load_scope(client) })
      end
    end
    local sub = vim.tbl_extend('force', {}, opts, { pre_ns_loaded = pre_loaded })
    local handle = M.eval(client, sub, callback)
    if handle then
      proxy.id = handle.id
      proxy.handle = handle
    else
      proxy.done = true
    end
  end)
  return proxy
end

function M.foreground(client, handle, opts)
  opts = opts or {}
  local function finished()
    if handle.done then return true end
    -- Connection death: stop polling regardless of request state. The closed
    -- transport also fails in-flight requests, but during the preamble phase
    -- handle.id is still nil, so this is the only signal that resolves the wait.
    if client.transport and client.transport.state == 'closed' then return true end
    return handle.id ~= nil and client.requests[handle.id] == nil
  end
  local ok, result = pcall(function()
    while not vim.wait(1, finished) do
      if opts.echo then
        local peek = vim.fn.getchar(1)
        if peek ~= 0 then
          local char = type(peek) == 'number' and vim.fn.nr2char(peek) or peek
          if char == string.char(4) then return { backgrounded = true } end
          client:stdin(handle.id, char)
        end
      end
    end
    return { done = true }
  end)
  if not ok then
    -- handle.id is the user eval once it has fired; during the preamble it's
    -- still nil and handle.prep_id points at the in-flight require/load-file.
    -- Mark aborted first so with_prep's prep callback won't fire the eval when
    -- the interrupt resolves the preamble.
    handle.aborted = true
    client:interrupt(handle.id or handle.prep_id)
    error(result)
  end
  return result
end

local function range_code(line1, line2)
  return table.concat(vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false), '\n')
end

function M.command(args)
  local runtime_name, line1, line2, range, bang, _, text = unpack(args)
  local code = text ~= '' and text or range_code(line1, line2)
  local rt = runtime_name == 'auto' and runtime.detect({}) or runtime_name
  local client, connect_err = current_client()
  if not client then return 'echoerr ' .. vim.fn.string(connect_err or 'Campfire: no live nREPL connection') end

  local bufnr = vim.api.nvim_get_current_buf()
  local handle, err = M.with_prep(client, {
    code = code, runtime = rt, ns = runtime.ns(), line = line1, column = 1,
    file = vim.api.nvim_buf_get_name(bufnr), bufnr = bufnr,
  })
  if err then return 'echoerr ' .. vim.fn.string(err) end
  if bang == 0 or bang == false then M.foreground(client, handle, { echo = true }) end
  return ''
end

return M
