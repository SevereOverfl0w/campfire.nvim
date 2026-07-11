local info = require('campfire.info')
local runtime = require('campfire.runtime')

local M = {}
local hover_win

function M.close_hover(winid)
  winid = winid or hover_win
  if winid and vim.api.nvim_win_is_valid(winid) then pcall(vim.api.nvim_win_close, winid, true) end
  if winid == hover_win then hover_win = nil end
end

local function display_width(lines)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

function M.hover(symbol, data)
  M.close_hover()
  local lines = info.doc_hover_lines(symbol, data)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype = 'nofile'
  local width = math.max(1, math.min(vim.o.columns - 4, display_width(lines)))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    focusable = false,
  })
  hover_win = winid
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinLeave', 'BufHidden', 'InsertEnter' }, {
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    callback = function() M.close_hover(winid) end,
  })
  return winid
end

-- Clojure's clojure.lang.Compiler/CHAR_MAP. Demunge is lossy: '-' and '_'
-- both round-trip to '-', so user-facing symbols use idiomatic kebab-case.
local MUNGE_MAP = {
  ['-'] = '_',
  [':'] = '_COLON_',
  ['+'] = '_PLUS_',
  ['>'] = '_GT_',
  ['<'] = '_LT_',
  ['='] = '_EQ_',
  ['~'] = '_TILDE_',
  ['!'] = '_BANG_',
  ['@'] = '_CIRCA_',
  ['#'] = '_SHARP_',
  ["'"] = '_SINGLEQUOTE_',
  ['"'] = '_DOUBLEQUOTE_',
  ['%'] = '_PERCENT_',
  ['^'] = '_CARET_',
  ['&'] = '_AMPERSAND_',
  ['*'] = '_STAR_',
  ['|'] = '_BAR_',
  ['{'] = '_LBRACE_',
  ['}'] = '_RBRACE_',
  ['['] = '_LBRACK_',
  [']'] = '_RBRACK_',
  ['/'] = '_SLASH_',
  ['\\'] = '_BSLASH_',
  ['?'] = '_QMARK_',
}

local DEMUNGE_MAP = {}
local DEMUNGE_KEYS = {}
for k, v in pairs(MUNGE_MAP) do
  DEMUNGE_MAP[v] = k
  DEMUNGE_KEYS[#DEMUNGE_KEYS + 1] = v
end
-- Longest first so '_PLUS_' wins over the bare '_' that maps to '-'.
table.sort(DEMUNGE_KEYS, function(a, b) return #a > #b end)

local function munge_part(s)
  return (s:gsub('.', function(c) return MUNGE_MAP[c] or c end))
end

local function demunge_part(s)
  local out, i = {}, 1
  while i <= #s do
    local matched
    for _, key in ipairs(DEMUNGE_KEYS) do
      if s:sub(i, i + #key - 1) == key then
        out[#out + 1] = DEMUNGE_MAP[key]
        i = i + #key
        matched = true
        break
      end
    end
    if not matched then
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.doc_url(symbol)
  local slash = symbol:find('/', 1, true)
  if slash then
    return 'campfire://doc/' .. munge_part(symbol:sub(1, slash - 1)) .. '/' .. munge_part(symbol:sub(slash + 1))
  end
  return 'campfire://doc/' .. munge_part(symbol)
end

function M.parse_doc_url(name)
  local rest = name:match('^campfire://doc/(.+)$')
  if not rest then return nil end
  local slash = rest:find('/', 1, true)
  if slash then
    return demunge_part(rest:sub(1, slash - 1)) .. '/' .. demunge_part(rest:sub(slash + 1))
  end
  return demunge_part(rest)
end

local doc_cache = {}

local function fill_doc_buffer(bufnr, symbol, data, scope, ns)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  -- Link the doc buffer back to where it was opened (fireplace stamps its scratch
  -- buffers similarly) so K / [D / :Source run from here resolve against
  -- the same connection and namespace instead of a default. Without the ns the
  -- doc buffer has no (ns …) form, so lookups go out with ns=nil and even a
  -- fully-qualified symbol fails to resolve. ft=clojure highlights the arglists
  -- and triggers campfire#activate, registering the buffer-local commands.
  if scope and scope ~= '' then vim.b[bufnr].campfire_scope = scope end
  if ns and ns ~= '' then vim.b[bufnr].campfire_ns = ns end
  vim.bo[bufnr].filetype = 'clojure'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, info.doc_lines(symbol, data))
end

function M.doc(symbol, data, scope, ns)
  local name = M.doc_url(symbol)
  doc_cache[name] = { symbol = symbol, data = data, scope = scope, ns = ns }
  vim.cmd('split ' .. vim.fn.fnameescape(name))
  return ''
end

function M.bufread_doc()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cached = doc_cache[name]
  doc_cache[name] = nil
  if cached then
    fill_doc_buffer(bufnr, cached.symbol, cached.data, cached.scope, cached.ns)
    return
  end
  -- Re-read (e.g. :edit on the doc buffer): route the lookup through the buffer's
  -- own pin + ns so it stays on the originating connection, and re-stamp them.
  local scope = vim.b[bufnr].campfire_scope
  local ns = vim.b[bufnr].campfire_ns
  local symbol = M.parse_doc_url(name)
  if not symbol then return end
  local data, err = info.lookup(symbol, { ns = ns or runtime.ns() })
  if err and not symbol:find('/', 1, true) then
    data, err = info.lookup(symbol, { ns = 'clojure.core' })
  end
  if err then
    vim.api.nvim_echo({ { err, 'ErrorMsg' } }, true, {})
    return
  end
  fill_doc_buffer(bufnr, symbol, data, scope, ns)
end

function M.source(data)
  local loc = info.source_location(data)
  if not loc then return 'echoerr ' .. vim.fn.string('Campfire: source unavailable') end
  vim.cmd('edit +' .. loc.lnum .. ' ' .. vim.fn.fnameescape(loc.filename))
  return ''
end

local function macroexpand_lines(expansion, iterations, fixed_point)
  local lines = vim.split(expansion or '', '\n', { plain = true })
  local header
  if iterations and iterations > 1 then
    header = ';; macroexpand-1 ×' .. iterations
  end
  if fixed_point then
    header = (header and (header .. ' — ') or ';; ') .. 'fixed point'
  end
  if header then
    table.insert(lines, 1, header)
  end
  return lines
end

local active_macroexpand = { win = nil, state = nil }

function M.active_macroexpand()
  if active_macroexpand.win and vim.api.nvim_win_is_valid(active_macroexpand.win) then
    return active_macroexpand
  end
  active_macroexpand = { win = nil, state = nil }
  return nil
end

function M.close_macroexpand_hover()
  if active_macroexpand.win and vim.api.nvim_win_is_valid(active_macroexpand.win) then
    pcall(vim.api.nvim_win_close, active_macroexpand.win, true)
  end
  active_macroexpand = { win = nil, state = nil }
end

function M.macroexpand_hover(expansion, iterations, opts)
  opts = opts or {}
  local lines = macroexpand_lines(expansion, iterations, opts.fixed_point)
  local bufnr, winid = vim.lsp.util.open_floating_preview(lines, 'clojure', {
    border = 'rounded',
    focus = false,
    focus_id = 'campfire-macroexpand',
    max_width = math.max(40, math.floor(vim.o.columns / 2)),
    max_height = math.max(1, math.floor(vim.o.lines / 2)),
  })
  if not bufnr then return winid end

  active_macroexpand = {
    win = winid,
    state = {
      expansion = expansion or '',
      iterations = iterations or 1,
      expander = opts.expander or 'macroexpand-1',
      ns = opts.ns,
      runtime = opts.runtime,
    },
  }

  return winid
end

function M.macroexpand_split(label, expansion, iterations)
  local name = 'campfire://macroexpand/' .. (label or 'form'):gsub('[^%w_./:$-]', '_')
  local bufnr = vim.fn.bufnr(name, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'clojure'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, macroexpand_lines(expansion, iterations))
  vim.cmd('split ' .. vim.fn.fnameescape(name))
  return ''
end

function M.symbol(arg)
  if arg and arg ~= '' then return arg end
  return vim.fn.expand('<cword>')
end

function M.command(args)
  local kind, symbol = args[1], M.symbol(args[2])
  if symbol == '' then return 'echoerr ' .. vim.fn.string('Campfire: symbol required') end
  -- From a doc buffer the originating ns rides on b:campfire_ns (no (ns …) form
  -- to parse); elsewhere fall back to detecting it from the buffer text.
  local ns = vim.b.campfire_ns or runtime.ns()
  local data, err = info.lookup(symbol, { ns = ns })
  if err and not symbol:find('/', 1, true) then
    data, err = info.lookup(symbol, { ns = 'clojure.core' })
  end
  if err then return 'echoerr ' .. vim.fn.string(err) end
  if kind == 'hover' then
    M.hover(symbol, data)
    return ''
  end
  if kind == 'source' then return M.source(data) end
  -- Carry the connection + ns this lookup resolved against onto the doc buffer.
  local campfire = require('campfire')
  local client = campfire.current and campfire.current()
  return M.doc(symbol, data, client and client.label, ns)
end

return M
