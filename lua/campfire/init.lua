local M = {}

local config = require('campfire.config')
local auto = require('campfire.auto')
local client_mod = require('campfire.client')
local runtime = require('campfire.runtime')
local connect_mod = require('campfire.connect')
local probe = require('campfire.probe')
local templates = require('campfire.templates')
local health = require('campfire.health')

-- Root-keyed registry, fireplace-style.
--
-- `by_root[root]` carries the clients connected from that project root and a
-- per-extension scope override map populated by `:Scope`. `by_label`
-- and `clients` are derived views maintained alongside it so external callers
-- (and the integration test surface) keep their flat-list semantics. There's
-- no concept of "the current project root" — resolution always starts from a
-- buffer.
local state = {
  by_root = {},
  by_label = {},
  clients = {},
  last_plan = {},
}

local GLOBAL_ROOT = '*'

local function ensure_root(root)
  root = root or GLOBAL_ROOT
  local bucket = state.by_root[root]
  if not bucket then
    bucket = { clients = {}, scope_by_ext = {} }
    state.by_root[root] = bucket
  end
  return bucket
end

local handlers = {}

local function echo(msg, hi)
  vim.schedule(function()
    vim.api.nvim_echo({ { msg, hi or 'None' } }, false, {})
  end)
end

local function errecho(msg)
  vim.schedule(function() vim.api.nvim_err_writeln(msg) end)
end

local function default_on_error(e) errecho('Campfire: transport error: ' .. tostring(e)) end
local function default_on_close() echo('Campfire: connection closed') end

-- Max dialect-probe attempts on the bootstrap path before giving up and
-- finalising with whatever was found (~30s at PROBE_DELAY_MS=1500).
local PROBE_RETRIES = 20

-- Whether the post-bootstrap dialect probe should run again. A bootstrapped cljs
-- REPL (shadow node-repl, piggieback) can take tens of seconds to attach, during
-- which the probe reads unknown; without a re-probe that unknown is cached for
-- the session (breaking routing/pretty/tests). So on the bootstrap path we retry
-- while the dialect is still unknown, capped. A plain connect (no bootstrap)
-- probes once: a server that truly reports unknown shouldn't stall the connect.
local function reprobe_needed(has_bootstrap, lang, attempt)
  if not has_bootstrap then return false end
  if lang and lang ~= 'unknown' then return false end
  return attempt < PROBE_RETRIES
end

local function unique_label(base)
  if not state.by_label[base] then return base end
  local i = 2
  while state.by_label[base .. '-' .. i] do i = i + 1 end
  return base .. '-' .. i
end

local function normalise_root(root)
  if not root or root == GLOBAL_ROOT then return root end
  -- vim.fn.resolve follows symlinks (e.g. macOS /var -> /private/var) so two
  -- callers reaching the same project through different prefixes agree on
  -- the bucket key.
  local p = vim.fn.resolve(vim.fn.fnamemodify(root, ':p'))
  return (p:gsub('/+$', ''))
end

local unregister_client

local function register_client(client)
  state.clients[#state.clients + 1] = client
  if client.label then state.by_label[client.label] = client end
  client.root = normalise_root(client.root)
  local bucket = ensure_root(client.root)
  bucket.clients[#bucket.clients + 1] = client
  -- Prune from the registry when the transport closes (server exit, drop, or
  -- explicit close). A dead client left in place shadows a live sibling in
  -- pick_client, whose liveness check then fails and triggers an auto-connect
  -- dupe on the next eval/RunTests.
  if client.transport then
    local prev = client.transport.on_close
    client.transport.on_close = function()
      if prev then prev() end
      unregister_client(client)
    end
  end
end

function unregister_client(client)
  for i, c in ipairs(state.clients) do
    if c == client then table.remove(state.clients, i); break end
  end
  if client.label and state.by_label[client.label] == client then
    state.by_label[client.label] = nil
  end
  local bucket = state.by_root[client.root or GLOBAL_ROOT]
  if bucket then
    for i, c in ipairs(bucket.clients) do
      if c == client then table.remove(bucket.clients, i); break end
    end
    if #bucket.clients == 0 and next(bucket.scope_by_ext) == nil then
      state.by_root[client.root or GLOBAL_ROOT] = nil
    end
  end
end

local function buffer_ext(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  return name:match('%.([%w]+)$')
end

-- File-extension default lang. Used when no project-level scope override is
-- registered and we have to fall back to ext-based matching.
local EXT_TO_LANG = {
  cljs = 'cljs',
  bb = 'bb',
  lg = 'lg',
  cljc = 'clj',
}

local function default_lang_for_buffer(bufnr)
  local ext = buffer_ext(bufnr)
  return EXT_TO_LANG[ext or ''] or 'clj'
end

local function buffer_root(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = (name ~= '' and vim.fn.fnamemodify(name, ':p:h')) or vim.fn.getcwd()
  return normalise_root(connect_mod.find_project_root(start))
end

-- Resolution order:
--   1. `vim.b.campfire_scope` (buffer pin set by `:Scope!`)
--   2. project-root `scope_by_ext[ext]` (`:Scope` no bang)
--   3. project-root clients with matching ext-default lang
--   4. project-root first client
--   5. any client with matching ext-default lang
--   6. first registered client
local function live(client)
  return client and (not client.transport or client.transport.state ~= 'closed')
end

-- Within a candidate list, prefer a live client of the desired lang; remember
-- the first match of any liveness as a fallback. A dead client should never
-- win over a live sibling — that's what shadows a working connection and makes
-- ensure_current spawn an auto-connect dupe.
local function pick_lang(clients, desired, fallback)
  for _, c in ipairs(clients) do
    if c.lang == desired then
      if live(c) then return c end
      fallback = fallback or c
    end
  end
  return nil, fallback
end

local function pick_client(bufnr)
  bufnr = bufnr or 0
  local pin = vim.b[bufnr].campfire_scope
  if pin and state.by_label[pin] then return state.by_label[pin] end

  local ext = buffer_ext(bufnr)
  local desired = default_lang_for_buffer(bufnr)
  local root = buffer_root(bufnr)
  local bucket = root and state.by_root[root]
  local fallback

  if bucket then
    local label = ext and bucket.scope_by_ext[ext]
    if label and state.by_label[label] then return state.by_label[label] end
    local hit
    hit, fallback = pick_lang(bucket.clients, desired, fallback)
    if hit then return hit end
    if bucket.clients[1] then
      if live(bucket.clients[1]) then return bucket.clients[1] end
      fallback = fallback or bucket.clients[1]
    end
  end

  local hit
  hit, fallback = pick_lang(state.clients, desired, fallback)
  if hit then return hit end
  return fallback or state.clients[1]
end

local NS_FILE_EXTS = { 'clj', 'cljs', 'cljc', 'cljd', 'bb', 'lg' }

local function path_to_ns(rel)
  local stem = rel:gsub('%.[%w]+$', '')
  return (stem:gsub('[/\\]', '.'):gsub('_', '-'))
end

local function bootstrap_then_finalise(client, opts)
  opts = opts or {}
  local function set_lang(lang)
    client.lang = client.lang or lang or 'unknown'
  end
  local function finalise()
    local desired_label = client.label or client.lang
    local final_label = unique_label(desired_label)
    if client.label and state.by_label[client.label] == client then
      state.by_label[client.label] = nil
    end
    client.label = final_label
    state.by_label[client.label] = client
    if not client._campfire_registered then
      register_client(client)
      client._campfire_registered = true
    end
    client._campfire_ready = true
    client._campfire_error = nil
    echo(('Campfire: connected %s [%s] %s'):format(client.label, client.lang, client.url or '?'))
  end

  local function detect_piggieback_then(after)
    if client.lang ~= 'cljs' then return after() end
    local tool = client.named.tooling and client.named.tooling.id
    if not tool then return after() end
    local fired = false
    local function go()
      if fired then return end
      fired = true
      after()
    end
    client:request({
      op = 'eval',
      code = "(some? (clojure.core/find-ns 'cider.piggieback))",
      session = tool,
    }, function(msg)
      if type(msg.value) == 'string' and msg.value:match('^%s*true%s*$') then
        client.piggieback = true
      end
      for _, s in ipairs(msg.status or {}) do
        if s == 'done' or s == 'error' or s == 'eval-error' then go() end
      end
    end)
    vim.defer_fn(go, 3000)
  end

  local function detect_then(after)
    pcall(function() require('campfire.pretty').detect_async(client) end)
    pcall(function() require('campfire.classpath').fetch_async(client) end)
    pcall(function() require('campfire.nbb_classpath').fetch_async(client) end)
    pcall(function() require('campfire.sources').populate(client) end)
    pcall(start_ns_scan, client)
    -- piggieback detection evals (find-ns 'cider.piggieback) on the JVM tooling
    -- session and sets client.piggieback (consumed by per-form eval splitting).
    -- Tooling is never upgraded to cljs; cljs introspection routes to main.
    detect_piggieback_then(after)
  end

  -- A bootstrapped cljs REPL (notably shadow-cljs `node-repl`) can take tens of
  -- seconds to compile + attach its JS runtime; until it does the dialect probe
  -- resolves to unknown. The original single probe cached that unknown for the
  -- whole session (set_lang never overwrites), breaking routing/pretty/tests.
  -- On the bootstrap path we re-probe with backoff until the runtime answers a
  -- real dialect. Plain connects (no bootstrap) probe once, as before — a server
  -- that genuinely reports unknown shouldn't stall the connect.
  local PROBE_DELAY_MS = 1500
  local function probe_then(session_id, attempt)
    session_id = session_id or client:session('tool')
    attempt = attempt or 1
    probe.run(client, session_id, function(err, lang)
      if reprobe_needed(opts.bootstrap, lang, attempt) then
        vim.defer_fn(function() probe_then(session_id, attempt + 1) end, PROBE_DELAY_MS)
        return
      end
      if err then errecho('Campfire: probe failed: ' .. tostring(err)) end
      set_lang(lang)
      detect_then(finalise)
    end)
  end

  if opts.bootstrap then
    client:request({
      op = 'eval',
      code = opts.bootstrap,
      scope = 'user',
    }, function(msg)
      if msg.ex then
        errecho('Campfire: bootstrap error: ' .. tostring(msg.ex))
      end
      for _, s in ipairs(msg.status or {}) do
        if s == 'done' then
          if client.lang then
            detect_then(finalise)
          else
            probe_then(client.named.main.id)
          end
        end
      end
    end)
  elseif client.lang then
    detect_then(finalise)
  else
    probe_then(nil)
  end
end

handlers.connect_complete = function(args)
  local lead = args[1] or ''
  local candidates = { 'nrepl://localhost:', 'nrepl+unix://' }
  for _, name in ipairs(templates.list()) do
    candidates[#candidates + 1] = '<' .. name .. '>'
  end
  return vim.tbl_filter(function(item)
    return lead == '' or item:sub(1, #lead) == lead
  end, candidates)
end

local function live_current()
  local client = M.current()
  if not client then return nil end
  if client.transport and client.transport.state == 'closed' then return nil end
  return client
end

-- Split A into leading reader macro/delim chars + symbol keyword. Vim's
-- customlist passes the full whitespace-delimited token, e.g. "(ma" for
-- `:Eval (ma<Tab>`, but nREPL's complete op wants a bare symbol
-- prefix. Strip the delims for the lookup, re-glue them onto each result.
local function split_lead(lead)
  local prefix, keyword = lead:match("^([({%[#'`]*)(.*)$")
  return prefix or '', keyword or lead
end

-- Build a cider-nrepl `context` form from the cmdline. The user is
-- typing a Clojure form as the command's argument; we substitute the
-- symbol prefix under the cursor with the `__prefix__` marker so the
-- server can contribute in-scope locals to the candidate list.
--
-- L is the full cmdline (with command name), P is the cursor byte
-- offset, lead/keyword are the current arg and its symbol portion (after
-- delim strip). Strip the command name + leading whitespace off L, then
-- replace the trailing `keyword` with `__prefix__`. Anything after the
-- cursor is dropped — cmdline completion always fires at end of input
-- in practice, and cider-nrepl tolerates unbalanced forms.
local function cmdline_context(L, P, lead, keyword)
  if not L or L == '' then return '__prefix__' end
  local before_cursor = L:sub(1, P or #L)
  local _, body_start = before_cursor:find('^%S+%s+')
  local body = body_start and before_cursor:sub(body_start + 1) or before_cursor
  if lead ~= '' and body:sub(-#lead) == lead then
    return body:sub(1, #body - #keyword) .. '__prefix__'
  end
  return body .. '__prefix__'
end

handlers.eval_complete = function(args)
  local lead = args[1] or ''
  local L, P = args[2] or '', args[3] or 0
  local prefix, keyword = split_lead(lead)
  if keyword == '' then return {} end
  local client = live_current()
  if not client then return {} end
  local ok, completion = pcall(require, 'campfire.completion')
  if not ok then return {} end
  local context = cmdline_context(L, P, lead, keyword)
  local items = completion.complete(client, keyword, { ns = runtime.ns(), context = context })
  local out = {}
  for _, item in ipairs(items) do
    if item.word and item.word ~= '' then out[#out + 1] = prefix .. item.word end
  end
  return out
end

local NS_EXT_SET = {}
for _, ext in ipairs(NS_FILE_EXTS) do NS_EXT_SET['.' .. ext] = true end

-- Walk `root` recursively via libuv's threadpool, calling `on_file(absolute)`
-- for each regular file and `on_done()` when the whole tree settles.
-- Each `fs_scandir` callback dispatches to the libuv thread pool, so this
-- never blocks the editor main loop. We refcount in-flight dirs (`pending`)
-- to fire `on_done` exactly once.
local function walk_async(root, on_file, on_done)
  local pending = 1
  local function visit(dir)
    vim.uv.fs_scandir(dir, function(err, req)
      if not err and req then
        while true do
          local name, t = vim.uv.fs_scandir_next(req)
          if not name then break end
          if name:sub(1, 1) ~= '.' then
            local full = dir .. '/' .. name
            if t == 'directory' then
              pending = pending + 1
              visit(full)
            elseif t == 'file' or t == 'link' then
              on_file(full)
            end
          end
        end
      end
      pending = pending - 1
      if pending == 0 then on_done() end
    end)
  end
  visit(root)
end

-- Kick a background scan of the client's source/classpath dirs. Callers read
-- `handle.done` / `handle.result` (set of ns names); `vim.wait` on `done` if
-- still pending. Idempotent per client lifetime.
local function start_ns_scan(client)
  if not client then return { done = true, result = {} } end
  if client._ns_scan then return client._ns_scan end

  local dirs = {}
  local seen_dir = {}
  local function add(list)
    for _, d in ipairs(list or {}) do
      local base = d and d:gsub('/+$', '') or ''
      if base ~= '' and not seen_dir[base] then
        seen_dir[base] = true
        dirs[#dirs + 1] = base
      end
    end
  end
  add(client.source_dirs)
  add(client.classpath_dirs)

  local handle = { done = false, result = {} }
  client._ns_scan = handle

  if #dirs == 0 then
    handle.done = true
    return handle
  end

  local remaining = #dirs
  local result = {}
  for _, base in ipairs(dirs) do
    local prefix = base .. '/'
    walk_async(base, function(path)
      local dot = path:match('(%.[%w]+)$')
      if dot and NS_EXT_SET[dot] and path:sub(1, #prefix) == prefix then
        result[path_to_ns(path:sub(#prefix + 1))] = true
      end
    end, function()
      remaining = remaining - 1
      if remaining == 0 then
        handle.result = result
        handle.done = true
      end
    end)
  end
  return handle
end

local function enumerate_source_nses(client, timeout_ms)
  local handle = start_ns_scan(client)
  if not handle.done then
    vim.wait(timeout_ms or 300, function() return handle.done end, 5)
  end
  return handle.result or {}
end

handlers.ns_complete = function(args)
  local lead = args[1] or ''
  local client = live_current()
  if not client then return {} end

  local seen = {}
  if client.describe and client.describe.ops and client.describe.ops['ns-list'] then
    -- ns-list reads the analyzer's namespaces: on cljs that state lives in
    -- main's compiler-env, so route to main (a JVM tooling session would list
    -- clj nses). Non-eval op, so no clobber.
    local response = client:request_sync({ op = 'ns-list', scope = 'user' })
    local names = response and response['ns-list']
    if type(names) == 'table' then
      for _, n in ipairs(names) do
        if type(n) == 'string' then seen[n] = true end
      end
    end
  end

  for ns in pairs(enumerate_source_nses(client)) do seen[ns] = true end

  if next(seen) == nil then return handlers.eval_complete(args) end

  local out = {}
  for ns in pairs(seen) do
    if lead == '' or ns:sub(1, #lead) == lead then out[#out + 1] = ns end
  end
  table.sort(out)
  return out
end

handlers.disconnect_complete = function(args)
  local lead = args[1] or ''
  local out = {}
  for label, _ in pairs(state.by_label) do
    if lead == '' or label:sub(1, #lead) == lead then out[#out + 1] = label end
  end
  table.sort(out)
  return out
end

handlers.scope_complete = handlers.disconnect_complete

handlers.connect_command = function(args)
  local argstr = args[6] or ''
  local plan, err = connect_mod.plan(argstr)
  if err then return 'echoerr ' .. vim.fn.string('Campfire: ' .. err) end

  local client = client_mod.new({
    url = plan.url,
    path = plan.path,
    label = plan.label,
    lang = plan.lang,
    on_error = default_on_error,
    on_close = default_on_close,
  })

  client.bootstrap = plan.bootstrap
  client.template = plan.template
  -- connect.plan already walks markers and stashes the chosen project root
  -- under `plan.path`, so honour it; only fall back to a fresh lookup if
  -- the plan didn't carry one (e.g. raw URL with no path/markers).
  client.root = plan.root or plan.path or connect_mod.find_project_root()
  state.last_plan[plan.label or plan.url] = plan

  local ok, ferr = pcall(function()
    client:connect(function(connect_err)
      if connect_err then
        errecho('Campfire: connect failed: ' .. tostring(connect_err))
        return
      end
      bootstrap_then_finalise(client, plan)
    end)
  end)
  if not ok then return 'echoerr ' .. vim.fn.string('Campfire: ' .. tostring(ferr)) end
  return ''
end

handlers.connections_command = function()
  if #state.clients == 0 then
    echo('Campfire: no live connections')
    return ''
  end
  local lines = { 'Campfire connections:' }
  for _, c in ipairs(state.clients) do
    lines[#lines + 1] = ('  %s [%s] %s @ %s'):format(
      c.label or '?', c.lang or '?', c.url or '?', c.path or '?')
  end
  echo(table.concat(lines, '\n'))
  return ''
end

local function client_for_buffer(bufnr)
  bufnr = bufnr or 0
  local pin = vim.b[bufnr].campfire_scope
  if pin and state.by_label[pin] then return state.by_label[pin] end
  local desired = default_lang_for_buffer(bufnr)
  for _, c in ipairs(state.clients) do
    if c.lang == desired then return c end
  end
  return nil
end

handlers.disconnect_command = function(args)
  local label = args[1]
  local client
  if label and label ~= '' then
    client = state.by_label[label]
    if not client then
      return 'echoerr ' .. vim.fn.string('Campfire: no connection labelled ' .. label)
    end
  elseif #state.clients == 0 then
    return 'echoerr ' .. vim.fn.string('Campfire: no current connection')
  elseif #state.clients == 1 then
    client = state.clients[1]
  else
    client = client_for_buffer()
    if not client then
      local labels = {}
      for _, c in ipairs(state.clients) do labels[#labels + 1] = c.label or '?' end
      return 'echoerr ' .. vim.fn.string('Campfire: ambiguous; pass a label (' .. table.concat(labels, ', ') .. ')')
    end
  end
  pcall(function() client:close() end)
  unregister_client(client)
  echo('Campfire: disconnected ' .. (client.label or '?'))
  return ''
end

handlers.reconnect_command = function(args)
  local label = args[1]
  local client = (label and label ~= '' and state.by_label[label]) or pick_client()
  if not client then
    return 'echoerr ' .. vim.fn.string('Campfire: no connection to reconnect')
  end
  local plan = state.last_plan[client.label] or {
    url = client.url, path = client.path, label = client.label,
    lang = client.lang, bootstrap = client.bootstrap, template = client.template,
    root = client.root,
  }
  pcall(function() client:close() end)
  unregister_client(client)

  local new_client = client_mod.new({
    url = plan.url, path = plan.path, label = plan.label, lang = plan.lang,
    on_error = default_on_error,
    on_close = default_on_close,
  })
  new_client.bootstrap = plan.bootstrap
  new_client.template = plan.template
  new_client.root = plan.root or client.root or plan.path or connect_mod.find_project_root()
  new_client:connect(function(connect_err)
    if connect_err then
      errecho('Campfire: reconnect failed: ' .. tostring(connect_err))
      return
    end
    bootstrap_then_finalise(new_client, plan)
  end)
  return ''
end

-- Scope command modes:
--   :Scope               -- print the current buffer's resolved scope
--   :Scope LABEL         -- pin (root, ext) → LABEL; every buffer of
--                                   this extension under the same project
--                                   root now routes to LABEL.
--   :Scope!              -- clear the buffer-only pin for this buffer
--   :Scope! LABEL        -- buffer-only pin (legacy behaviour)
--
-- The buffer-only pin (`vim.b.campfire_scope`) still wins over the (root,
-- ext) map, so users keep an escape hatch when the project default doesn't
-- fit a single file.
handlers.scope_command = function(args)
  local label = args[1]
  local bang = args[2]
  local has_bang = bang and bang ~= 0 and bang ~= '' and bang ~= false

  if has_bang and (not label or label == '') then
    vim.b.campfire_scope = nil
    echo('Campfire: buffer scope cleared')
    return ''
  end

  if not label or label == '' then
    local pin = vim.b.campfire_scope
    if pin then
      echo('Campfire: buffer scope ' .. pin)
      return ''
    end
    local ext = buffer_ext()
    local root = buffer_root()
    local bucket = root and state.by_root[root]
    local mapped = bucket and ext and bucket.scope_by_ext[ext]
    if mapped then
      echo(('Campfire: project scope %s/%s -> %s'):format(root, ext, mapped))
    else
      echo('Campfire: scope (none)')
    end
    return ''
  end

  if not state.by_label[label] then
    return 'echoerr ' .. vim.fn.string('Campfire: no connection labelled ' .. label)
  end

  if has_bang then
    vim.b.campfire_scope = label
    echo('Campfire: buffer scope ' .. label)
    return ''
  end

  local ext = buffer_ext()
  if not ext then
    return 'echoerr ' .. vim.fn.string(
      'Campfire: buffer has no file extension; use :Scope! ' .. label .. ' for a buffer pin')
  end
  local root = buffer_root() or GLOBAL_ROOT
  ensure_root(root).scope_by_ext[ext] = label
  echo(('Campfire: project scope %s/%s -> %s'):format(root, ext, label))
  return ''
end

function M.config()
  return config.get()
end

local autocmds_installed = false
local function install_autocmds()
  if autocmds_installed then return end
  autocmds_installed = true
  local prep = require('campfire.prep')
  local group = vim.api.nvim_create_augroup('campfire-prep', { clear = true })
  -- FocusGained: editor regained focus; external processes may have changed
  -- disk state (file reload, namespace refresh from another tool). Drop the
  -- per-connection ns-load cache so the next interactive eval re-probes.
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      for _, c in ipairs(state.clients) do
        pcall(function() prep.cache_clear(c) end)
      end
    end,
  })
end

function M.setup(opts)
  local options = config.setup(opts)
  require('campfire.history').configure(options)
  install_autocmds()
  return options
end

function M.current(bufnr)
  return pick_client(bufnr)
end

function M.connect(opts)
  opts = opts or {}
  local url = connect_mod.resolve_url(opts.url)
  local client = client_mod.new({
    url = url,
    path = opts.path,
    label = opts.label,
    lang = opts.lang,
    describe = opts.describe,
    transport = opts.transport,
    on_error = opts.on_error or default_on_error,
    on_close = opts.on_close or default_on_close,
  })
  client.bootstrap = opts.bootstrap
  client.template = opts.template
  client.root = normalise_root(opts.root or (opts.auto and opts.auto.root) or opts.path
    or connect_mod.find_project_root())
  client._campfire_ready = false
  client._campfire_error = nil
  client._campfire_auto = opts.auto
  register_client(client)
  -- Early-register so pick_client can find the client during the async connect.
  -- Trip the guard finalise() checks so it doesn't register a second time.
  client._campfire_registered = true
  client:connect(function(err)
    if err then
      client._campfire_error = tostring(err)
      unregister_client(client)
      return
    end
    bootstrap_then_finalise(client, opts)
  end)
  return client
end

local function wait_ready(client, timeout)
  if not client then return nil, 'Campfire: no live nREPL connection' end
  if client._campfire_ready == nil then return client end
  if client._campfire_ready then return client end
  if client._campfire_error then return nil, 'Campfire: ' .. client._campfire_error end
  vim.wait(timeout or config.get().auto_connect_timeout, function()
    return client._campfire_ready or client._campfire_error
  end, 10)
  if client._campfire_ready then return client end
  local err = client._campfire_error and ('Campfire: ' .. client._campfire_error) or 'Campfire: nREPL connection timed out'
  if client.transport and client.transport.close then pcall(function() client.transport:close() end) end
  unregister_client(client)
  return nil, err
end

function M.ensure_current(opts)
  opts = opts or {}
  if opts.url then
    local target = auto.resolve(opts.url, opts)
    if not target then return nil, 'Campfire: no nREPL port file found' end
    return wait_ready(M.connect({ url = target.url, path = target.root, auto = target }), opts.timeout)
  end

  local client = pick_client(opts.bufnr)
  if live(client) then return wait_ready(client, opts.timeout) end

  local options = config.get()
  if options.auto_connect == false then return nil, 'Campfire: no live nREPL connection' end

  local target = auto.resolve(nil, opts)
  if not target then return nil, 'Campfire: no live nREPL connection' end
  return wait_ready(M.connect({ url = target.url, path = target.root, auto = target }), opts.timeout)
end

function M.clients()
  return state.clients
end

function M.client_by_label(label)
  return state.by_label[label]
end

function M.runtime(opts)
  return runtime.detect(opts)
end

function M.vim_call(method, args)
  local handler = handlers[method]
  if handler == nil then
    error('Campfire: unknown Vim bridge method ' .. tostring(method))
  end
  return handler(args or {})
end

-- Test seam. Bypass the connect/describe/clone pipeline by hand-injecting a
-- fully-formed client object. Not part of the public surface.
M._internal = {
  register_client = register_client,
  unregister_client = unregister_client,
  reprobe_needed = reprobe_needed,
  PROBE_RETRIES = PROBE_RETRIES,
  state = state,
  buffer_root = buffer_root,
  pick_client = pick_client,
}

function M.health()
  return health.check()
end

return M
