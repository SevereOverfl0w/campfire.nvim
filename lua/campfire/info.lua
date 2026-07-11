local capabilities = require('campfire.capabilities')
local resource = require('campfire.resource')

local M = {}

local function parse_eval_map(value)
  if type(value) ~= 'string' or not value:match('^%s*{') then return value end
  local parsed = {}
  for key, quoted in value:gmatch(':(%S+)%s+"(.-)"') do
    parsed[key] = quoted
  end
  for key, bare in value:gmatch(':(%S+)%s+([^,%}]+)') do
    if parsed[key] == nil then parsed[key] = bare:gsub('%s+$', '') end
  end
  if parsed.line then parsed.line = tonumber(parsed.line) or parsed.line end
  return parsed
end

local function quoted_symbol(symbol)
  if symbol:match('^[%w_?!%*%+/%=<%>%.:-]+$') then return "'" .. symbol end
  return '(symbol ' .. string.format('%q', symbol) .. ')'
end

local function fallback_code(symbol)
  local sym = quoted_symbol(symbol)
  return '(clojure.core/if-let [m (clojure.core/meta (clojure.core/resolve '
    .. sym
    .. '))] {:name (:name m) :ns (str (:ns m)) :doc (:doc m) :arglists-str (str (:arglists m)) :file (:file m) :line (:line m)} {})'
end

function M.request(symbol, opts)
  opts = opts or {}
  local runtime_name = opts.runtime or (require('campfire').runtime and require('campfire').runtime({}) or 'clj')
  local selected, err = capabilities.view(opts.describe or {}, runtime_name):require('info')
  if not selected then return nil, err end
  if selected.fallback then
    -- eval-based fallback (server has no info op): keep on tooling so it can't
    -- clobber main's *1/*2/*e.
    return { op = 'eval', code = fallback_code(symbol), ns = opts.ns or 'user', fallback = true, scope = 'tool' }
  end
  -- info is a non-eval op (skips the eval executor): route to main so cljs
  -- resolves against main's compiler-env. A JVM tooling session returns
  -- no-info for cljs vars.
  return { op = selected.op, symbol = symbol, sym = symbol, ns = opts.ns, scope = 'user' }
end

function M.eldoc_request(symbol, opts)
  opts = opts or {}
  return {
    op = capabilities.view(opts.describe or {}, opts.runtime or 'clj'):first('eldoc') or 'eldoc',
    symbol = symbol,
    sym = symbol,
    ns = opts.ns,
    scope = 'user',
  }
end

function M.normalize(message)
  if type(message.value) == 'table' and #message.value > 0 then return parse_eval_map(message.value[1]) end
  if type(message.value) == 'table' then return message.value end
  if type(message.info) == 'table' then return message.info end
  return message
end

function M.exists(data)
  local info = M.normalize(data or {})
  return info.name ~= nil or info.class ~= nil or info.doc ~= nil or info.file ~= nil or info.resource ~= nil
end

local function trim(text)
  return tostring(text):gsub('^%s+', ''):gsub('%s+$', '')
end

local function arglist_text(arglist)
  if type(arglist) == 'table' then return '[' .. table.concat(arglist, ' ') .. ']' end

  local text = trim(arglist)
  if text == '' then return nil end
  text = text:gsub('%s*\n%s*', ' ')
  if text:sub(1, 1) == '[' or text:sub(1, 1) == '(' then return text end
  return '[' .. text .. ']'
end

local function looks_like_arglist(text)
  text = trim(text)
  return text:sub(1, 1) == '[' or text:sub(1, 1) == '('
end

local function arglists_text(info)
  local arglists = info['arglists-str'] or info.arglists
  if type(arglists) == 'table' then
    if #arglists > 0 and type(arglists[1]) ~= 'table' and not looks_like_arglist(arglists[1]) then
      return arglist_text(arglists)
    end
    local out = {}
    for _, arglist in ipairs(arglists) do
      local text = arglist_text(arglist)
      if text then out[#out + 1] = text end
    end
    return table.concat(out, ' ')
  end
  if arglists then
    local text = trim(arglists)
    if text:match('^%b()$') then text = trim(text:sub(2, -2)) end
    text = text:gsub('%s*\n%s*', ' ')
    return text ~= '' and text or nil
  end
end

local function arglists_lines(info)
  local arglists = info['arglists-str'] or info.arglists
  if type(arglists) == 'string' then
    local text = trim(arglists)
    if text:match('^%b()$') then text = trim(text:sub(2, -2)) end
    return text ~= '' and vim.split(text, '\n', { plain = true }) or {}
  end
  if type(arglists) == 'table' then
    if #arglists > 0 and type(arglists[1]) ~= 'table' and not looks_like_arglist(arglists[1]) then
      return { arglist_text(arglists) }
    end
    local out = {}
    for _, arglist in ipairs(arglists) do
      local text = arglist_text(arglist)
      if text then out[#out + 1] = text end
    end
    return out
  end
  return {}
end

local function indent_text()
  local width = vim.fn.shiftwidth()
  if width <= 0 then width = vim.bo.tabstop end
  return string.rep(' ', width)
end

local function title_for(symbol, info)
  return info.class or (info.ns and info.name and (info.ns .. '/' .. info.name)) or info.name or symbol
end

local function signature_lines(symbol, info)
  local title = title_for(symbol, info)
  local arglists = arglists_lines(info)
  if #arglists == 0 then return { title } end

  local lines = { '(' .. title }
  local indent = indent_text()
  for i, arglist in ipairs(arglists) do
    lines[#lines + 1] = indent .. arglist .. (i == #arglists and ')' or '')
  end
  return lines
end

local function add_doc(lines, doc)
  if not doc then return lines end
  lines[#lines + 1] = ''
  local doc_lines = vim.split(doc, '\n', { plain = true })
  if doc_lines[1] then doc_lines[1] = '  ' .. doc_lines[1] end
  vim.list_extend(lines, doc_lines)
  return lines
end

function M.doc_lines(symbol, data)
  local info = M.normalize(data or {})
  local title = title_for(symbol, info)
  local arglists = arglists_text(info)
  local lines = { arglists and ('(' .. title .. ' ' .. arglists .. ')') or title }
  if info.doc then
    lines[#lines + 1] = ''
    vim.list_extend(lines, vim.split(info.doc, '\n', { plain = true }))
  end
  return lines
end

function M.doc_hover_lines(symbol, data)
  local info = M.normalize(data or {})
  return add_doc(signature_lines(symbol, info), info.doc)
end

function M.doc_markdown(symbol, data)
  local info = M.normalize(data or {})
  local lines = { '```clojure' }
  vim.list_extend(lines, signature_lines(symbol, info))
  lines[#lines + 1] = '```'
  add_doc(lines, info.doc)
  return table.concat(lines, '\n')
end

function M.source_location(data)
  local info = M.normalize(data or {})
  local file = info.file or info.resource or ''
  file = resource.url_to_path(file, info.resource) or file
  if file == '' then return nil end
  return { filename = file, lnum = tonumber(info.line) or 1 }
end

function M.lookup(symbol, opts)
  opts = opts or {}
  local runtime_name = opts.runtime or (require('campfire').runtime and require('campfire').runtime({}) or 'clj')
  local client = opts.client
  if not client then
    local campfire = require('campfire')
    local err
    if campfire.ensure_current then
      client, err = campfire.ensure_current()
    else
      client = campfire.current()
    end
    if not client then return nil, err or 'Campfire: no live nREPL connection' end
  end
  local request, err = M.request(symbol, vim.tbl_extend('force', opts, {
    runtime = runtime_name,
    describe = opts.describe or client.describe or {},
  }))
  if err then return nil, err end
  local response = client:request_sync(request)
  if response.err then return nil, 'Campfire: ' .. tostring(response.err) end
  local data = M.normalize(response)
  if not M.exists(data) then return nil, 'Campfire: symbol not found: ' .. symbol end
  return data
end

return M
