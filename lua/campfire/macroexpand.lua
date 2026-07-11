local capabilities = require('campfire.capabilities')
local pretty = require('campfire.pretty')
local runtime = require('campfire.runtime')

local M = {}

local function expander_fn(expander)
  if expander == 'macroexpand-all' then return 'clojure.walk/macroexpand-all' end
  return expander
end

local CLJ_LIKE_RUNTIMES = { clj = true, bb = true, lg = true }

function M.request(code, expander, opts)
  opts = opts or {}
  local runtime_name = opts.runtime or 'clj'
  -- macroexpand is a non-eval op: route to main. cljs macroexpansion needs
  -- main's compiler-env (a JVM tooling session would macroexpand against clj);
  -- non-eval ops don't queue behind user evals or touch *1/*2/*3.
  local view = capabilities.view(opts.describe or {}, runtime_name)
  if view:has('macroexpand') then
    return {
      op = 'macroexpand',
      code = code,
      expander = expander,
      ns = opts.ns,
      ['display-namespaces'] = 'tidy',
      scope = 'user',
    }
  end
  if not CLJ_LIKE_RUNTIMES[runtime_name] then
    return nil, ('Campfire: macroexpand unavailable for %s runtime'):format(runtime_name)
  end
  if expander == 'macroexpand-step' then
    -- No clojure.core/macroexpand-step. The fallback only handles
    -- macroexpand-1/macroexpand/macroexpand-all. Caller (reexpand branch)
    -- should retry with macroexpand-1.
    return nil, 'Unrecognized expander in fallback: macroexpand-step'
  end
  return {
    op = 'eval',
    code = ('(%s \'%s)'):format(expander_fn(expander), code),
    ns = opts.ns,
    scope = 'tool',
  }
end

local function extract_value(request, response)
  if response.err and not response.expansion and not response.value then
    return nil, 'Campfire: ' .. tostring(response.err)
  end
  if request.op == 'macroexpand' then
    return response.expansion
  end
  if type(response.value) == 'table' then return response.value[1] end
  return response.value
end

local function resolve_client(opts)
  if opts.client then return opts.client end
  local campfire = require('campfire')
  if campfire.ensure_current then return campfire.ensure_current() end
  return campfire.current and campfire.current()
end

function M.expand(code, expander, opts)
  opts = opts or {}
  local client, cerr = resolve_client(opts)
  if not client then return nil, cerr or 'Campfire: no live nREPL connection' end

  local runtime_name = opts.runtime or runtime.detect({})
  local request, rerr = M.request(code, expander, vim.tbl_extend('force', opts, {
    runtime = runtime_name,
    describe = opts.describe or client.describe or {},
  }))
  if rerr then return nil, rerr end

  local response = client:request_sync(pretty.apply(request, client))
  local value, verr = extract_value(request, response)
  if verr then return nil, verr end
  if value == nil or value == '' then return nil, 'Campfire: empty macroexpansion' end
  return value
end

local function trimmed(s)
  return vim.trim(s or '')
end

function M.expand_n(code, expander, n, opts)
  n = math.max(1, n or 1)
  if expander ~= 'macroexpand-1' then n = 1 end

  local current = code
  local last_expansion
  local iterations = 0
  for _ = 1, n do
    local next_value, err = M.expand(current, expander, opts)
    if err then
      if iterations == 0 then return nil, err end
      return last_expansion, iterations
    end
    if trimmed(next_value) == trimmed(current) then
      if iterations == 0 then return next_value, 1 end
      return last_expansion, iterations
    end
    iterations = iterations + 1
    last_expansion = next_value
    current = next_value
  end
  return last_expansion, iterations
end

local function normalize_count(c)
  if c == nil or c == 0 then return 1 end
  return c
end

local function form_label(code)
  local single = (code:gsub('%s+', ' '))
  if #single > 40 then single = single:sub(1, 40) end
  return single
end

local function err(msg)
  vim.api.nvim_echo({ { msg, 'ErrorMsg' } }, true, {})
end

function M.op(kind, expander, count)
  local operator = require('campfire.operator')
  local ui = require('campfire.ui')

  local active = ui.active_macroexpand()
  if active then
    local state = active.state
    -- Reexpand drills one macro deeper anywhere in the tree. Uses cider-nrepl's
    -- `macroexpand-step` (walk/prewalk expanding the next macro encountered)
    -- which is what users intuitively want when pressing cmm repeatedly —
    -- macroexpand-1 alone gets stuck once the outer head is a special form
    -- even though sub-forms still hold macros. Cider-nrepl 0.30+ required.
    local step_expander = 'macroexpand-step'
    local next_value, err_msg = M.expand(state.expansion, step_expander, {
      ns = state.ns,
      runtime = state.runtime,
    })
    if err_msg and (err_msg:find('Unrecognized expander', 1, true)
                    or err_msg:find('macroexpand-step', 1, true)) then
      -- Old cider-nrepl or server without it. Fall back to macroexpand-1
      -- (outer head only).
      step_expander = 'macroexpand-1'
      next_value, err_msg = M.expand(state.expansion, step_expander, {
        ns = state.ns,
        runtime = state.runtime,
      })
    end
    if not next_value then
      err(err_msg)
      return
    end
    if trimmed(next_value) == trimmed(state.expansion) then
      vim.api.nvim_echo({ { 'Campfire: macroexpand fixed point', 'WarningMsg' } }, true, {})
      ui.macroexpand_hover(state.expansion, state.iterations, {
        ns = state.ns,
        runtime = state.runtime,
        expander = step_expander,
        fixed_point = true,
      })
      return
    end
    ui.macroexpand_hover(next_value, (state.iterations or 1) + 1, {
      ns = state.ns,
      runtime = state.runtime,
      expander = step_expander,
    })
    return
  end

  local ok, extracted = pcall(operator.extract, kind)
  if not ok or not extracted or not extracted.code or extracted.code == '' then
    err('Campfire: no form to macroexpand')
    return
  end

  local ns = runtime.ns()
  local expansion, iterations = M.expand_n(extracted.code, expander, normalize_count(count), { ns = ns })
  if not expansion then
    err(iterations)
    return
  end
  ui.macroexpand_hover(expansion, iterations, { ns = ns, expander = expander })
end

function M.command(bang, expander, args, count)
  local ui = require('campfire.ui')
  local code
  if args and args ~= '' then
    code = args
  else
    local operator = require('campfire.operator')
    local ok, extracted = pcall(operator.extract, vim.fn.line('.'))
    if not ok or not extracted or not extracted.code or extracted.code == '' then
      return 'echoerr ' .. vim.fn.string('Campfire: no form to macroexpand')
    end
    code = extracted.code
  end

  local ns = runtime.ns()
  local expansion, iterations = M.expand_n(code, expander, normalize_count(count), { ns = ns })
  if not expansion then
    return 'echoerr ' .. vim.fn.string(iterations)
  end
  if bang then
    return ui.macroexpand_split(form_label(code), expansion, iterations)
  end
  ui.macroexpand_hover(expansion, iterations, { ns = ns })
  return ''
end

return M
