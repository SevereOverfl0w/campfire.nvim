local M = {}

function M.detect(opts)
  opts = opts or {}
  if opts.runtime and opts.runtime ~= 'auto' then return opts.runtime end

  local file = opts.file or vim.api.nvim_buf_get_name(opts.bufnr or 0)
  local ext = file:match('%.([%w]+)$')
  if ext == 'cljs' then return 'cljs' end
  if ext == 'bb' then return 'bb' end
  if ext == 'lg' then return 'lg' end
  if ext == 'cljc' and opts.cljc_platform then return opts.cljc_platform end
  return 'clj'
end

-- kindling: stdlib-Lua ns detector. See .scratch/ns-loading2/strategies/kindling.md.
local SYM = '[%w%.%-%*%+%!%?%_%:%/%$%&%=%<%>]+'

local function strip_comments(s)
  return (s:gsub(';[^\n]*', ''))
end

-- Strip "..." literals with backslash-escape awareness. Replace each with a
-- single space so adjacent tokens don't fuse.
local function strip_strings(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' then
      i = i + 1
      while i <= n do
        local ch = s:sub(i, i)
        if ch == '\\' then i = i + 2
        elseif ch == '"' then i = i + 1; break
        else i = i + 1 end
      end
      out[#out + 1] = ' '
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Skip leading metadata at position i: ^kw, ^sym, ^"str", ^{...} (brace-balanced).
-- Returns position after metadata + whitespace.
local function skip_meta(src, i)
  while true do
    local _, e = src:find('^%s+', i); if e then i = e + 1 end
    if src:sub(i, i) ~= '^' then return i end
    i = i + 1
    local c = src:sub(i, i)
    if c == '{' then
      local depth, j = 1, i + 1
      while depth > 0 and j <= #src do
        local ch = src:sub(j, j)
        if ch == '{' then depth = depth + 1
        elseif ch == '}' then depth = depth - 1 end
        j = j + 1
      end
      i = j
    elseif c == '"' then
      local j = i + 1
      while j <= #src and src:sub(j, j) ~= '"' do j = j + 1 end
      i = j + 1
    else
      local _, e2 = src:find('^[^%s%(%)%[%]%{%}]+', i); if e2 then i = e2 + 1 end
    end
  end
end

local function detect_ns(src)
  src = strip_strings(strip_comments(src))
  local i = 1
  while true do
    local s, e = src:find('%(', i); if not s then return nil end
    local j = e + 1
    local _, we = src:find('^%s+', j); if we then j = we + 1 end
    local head = src:sub(j, j + 5)
    if head:match('^ns[%s%(]') then
      j = skip_meta(src, j + 2)
      local name = src:sub(j):match('^(' .. SYM .. ')')
      if name then return name, 'ns' end
    elseif head:match("^in%-ns") then
      j = j + 5
      local _, we2 = src:find("^%s*'", j); if we2 then j = we2 + 1 end
      local name = src:sub(j):match('^(' .. SYM .. ')')
      if name then return name, 'in-ns' end
    end
    i = e + 1
  end
end

M.detect_ns = detect_ns

local OPEN = { ['('] = ')', ['['] = ']', ['{'] = '}' }
local CLOSE = { [')'] = true, [']'] = true, ['}'] = true }

-- Recursive-descent S-expression scanner. Returns one form's end-byte (1-based,
-- inclusive). Skips strings, line comments, char literals; handles nested
-- ()/[]/{} and reader prefixes ^ ' ` ~ ~@ @ # #_.
local function read_sexpr(src, i, n)
  -- skip leading whitespace + comments
  while i <= n do
    local c = src:sub(i, i)
    if c:match('%s') then
      i = i + 1
    elseif c == ';' then
      local nl = src:find('\n', i, true)
      if not nl then return nil end
      i = nl + 1
    else
      break
    end
  end
  if i > n then return nil end
  local c = src:sub(i, i)
  if c == '"' then
    local j = i + 1
    while j <= n do
      local ch = src:sub(j, j)
      if ch == '\\' then j = j + 2
      elseif ch == '"' then return j
      else j = j + 1 end
    end
    return n
  elseif c == '\\' then
    -- char literal: \c or \space, \newline, ...
    local _, e = src:find('^[%w%-]+', i + 1)
    return e or (i + 1)
  elseif OPEN[c] then
    local close = OPEN[c]
    local j = i + 1
    while j <= n do
      local ch = src:sub(j, j)
      if ch == close then return j end
      if ch:match('%s') then j = j + 1
      elseif ch == ';' then
        local nl = src:find('\n', j, true); j = nl and nl + 1 or n + 1
      else
        local e = read_sexpr(src, j, n)
        if not e then return n end
        j = e + 1
      end
    end
    return n
  elseif c == "'" or c == '`' or c == '@' then
    local e = read_sexpr(src, i + 1, n)
    return e or i
  elseif c == '~' then
    local nx = src:sub(i + 1, i + 1)
    local start = (nx == '@') and (i + 2) or (i + 1)
    local e = read_sexpr(src, start, n)
    return e or (start - 1)
  elseif c == '^' then
    -- ^meta form: consume metadata sub-form + main form
    local e1 = read_sexpr(src, i + 1, n)
    if not e1 then return i end
    local e2 = read_sexpr(src, e1 + 1, n)
    return e2 or e1
  elseif c == '#' then
    local nx = src:sub(i + 1, i + 1)
    if nx == '_' then
      -- discard reader macro: read & include subsequent form, then read again
      local skipped = read_sexpr(src, i + 2, n)
      if not skipped then return i + 1 end
      local main = read_sexpr(src, skipped + 1, n)
      return main or skipped
    elseif nx == '?' then
      -- #? or #?@ reader-conditional → ( ... )
      local start = (src:sub(i + 2, i + 2) == '@') and (i + 3) or (i + 2)
      return read_sexpr(src, start, n) or (start - 1)
    elseif nx == '{' or nx == '(' or nx == '"' or nx == "'" then
      return read_sexpr(src, i + 1, n) or i
    else
      -- tagged literal: #sym form (e.g. #inst "...")
      local e1 = read_sexpr(src, i + 1, n)
      if not e1 then return i end
      local e2 = read_sexpr(src, e1 + 1, n)
      return e2 or e1
    end
  else
    -- atom: consume until ws / closer / ; / "
    local j = i
    while j <= n do
      local ch = src:sub(j, j)
      if ch:match('%s') or CLOSE[ch] or ch == ';' or ch == '"' then return j - 1 end
      j = j + 1
    end
    return n
  end
end

-- Split text into top-level forms with (line, column) of each form's start.
-- base_line, base_column default to 1, 1. Returns array of {code, line, column}.
function M.forms(text, base_line, base_column)
  base_line = base_line or 1
  base_column = base_column or 1
  local out = {}
  local i, n = 1, #text
  -- precompute line offsets to map byte index → (line, column)
  local function pos_at(byte_i)
    local line, col = base_line, base_column
    local k = 1
    while k < byte_i do
      if text:sub(k, k) == '\n' then
        line = line + 1
        col = 1
      else
        col = col + 1
      end
      k = k + 1
    end
    return line, col
  end
  while i <= n do
    -- skip ws + comments to next form start
    while i <= n do
      local c = text:sub(i, i)
      if c:match('%s') then i = i + 1
      elseif c == ';' then
        local nl = text:find('\n', i, true); i = nl and nl + 1 or n + 1
      else break end
    end
    if i > n then break end
    local start_i = i
    local end_i = read_sexpr(text, i, n)
    if not end_i or end_i < start_i then break end
    local line, column = pos_at(start_i)
    out[#out + 1] = { code = text:sub(start_i, end_i), line = line, column = column }
    i = end_i + 1
  end
  return out
end

function M.ns(opts)
  opts = opts or {}
  local text = opts.text
  if not text then
    local bufnr = opts.bufnr or 0
    local lines = opts.lines or vim.api.nvim_buf_get_lines(bufnr, 0, math.min(vim.api.nvim_buf_line_count(bufnr), 200), false)
    text = table.concat(lines, '\n')
  end
  return (detect_ns(text))
end

-- Find the top-level form containing the given 1-based row. Returns the
-- form table {code, line, column} or nil if the row sits between forms.
function M.form_at_line(text, row)
  local forms = M.forms(text)
  for i = #forms, 1, -1 do
    local f = forms[i]
    if f.line <= row then
      local _, nl = f.code:gsub('\n', '\n')
      if f.line + nl >= row then return f end
      return nil
    end
  end
  return nil
end

-- Inspect a single Clojure form. If the head symbol begins with "def" and a
-- name symbol follows (skipping ^meta / ^{:keymap …}), return {head, name}.
-- Used to identify deftest / defspec / deftest-check-ns / defn-with-:test-meta
-- and friends regardless of which custom macro the project uses.
function M.parse_def(code)
  if not code or code:sub(1, 1) ~= '(' then return nil end
  local i = 2
  local _, e = code:find('^%s+', i); if e then i = e + 1 end
  local head = code:sub(i):match('^(' .. SYM .. ')')
  if not head then return nil end
  local tail = head:match('/(.+)$') or head
  if not tail:match('^def') then return nil end
  i = i + #head
  i = skip_meta(code, i)
  local name = code:sub(i):match('^(' .. SYM .. ')')
  if not name or name == '' then return nil end
  return { head = head, name = name }
end

return M
