local templates = require('campfire.templates')

local M = {}

M.project_markers = {
  'deps.edn',
  'project.clj',
  'shadow-cljs.edn',
  'bb.edn',
  '.nrepl-port',
  '.shadow-cljs/nrepl.port',
  '.git',
}

M.port_files = {
  'repl-port',
  '.nrepl-port',
  'target/repl-port',
  '.shadow-cljs/nrepl.port',
}

local function walk_up(start, predicate)
  local dir = vim.fn.fnamemodify(start or vim.fn.getcwd(), ':p')
  if vim.fn.isdirectory(dir) == 0 then dir = vim.fn.fnamemodify(dir, ':h') end
  while dir and dir ~= '/' and dir ~= '' do
    local hit = predicate(dir)
    if hit then return hit, dir end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end
    dir = parent
  end
end

function M.find_project_root(start)
  local _, dir = walk_up(start, function(d)
    for _, marker in ipairs(M.project_markers) do
      local path = d .. '/' .. marker
      -- `.git` can be either a directory (normal checkout) or a file
      -- (worktrees, submodules), so accept either form.
      if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
        return true
      end
    end
  end)
  return dir or vim.fn.getcwd()
end

function M.discover_port_file(start)
  local hit = walk_up(start, function(d)
    for _, marker in ipairs(M.port_files) do
      local file = d .. '/' .. marker
      if vim.fn.filereadable(file) == 1 then return file end
    end
  end)
  return hit
end

local function is_url_shaped(t)
  if t:match('^%d+$') then return true end
  if t:match('^%w[%w+-]*://') then return true end
  if vim.fn.filereadable(t) == 1 then return true end
  return false
end

local function is_template(t)
  return t:match('^<[^>]+>$') ~= nil
end

local function is_flag(t)
  return t:match('^[%w_-]+=') ~= nil
end

function M.parse(argstr)
  local result = { flags = {} }
  argstr = argstr or ''

  local toks = {}
  for tok in argstr:gmatch('%S+') do toks[#toks + 1] = tok end

  local form_idx
  for i, tok in ipairs(toks) do
    if tok:sub(1, 1) == '+' then form_idx = i; break end
  end
  if form_idx then
    local trailing = {}
    for i = form_idx, #toks do trailing[#trailing + 1] = toks[i] end
    trailing[1] = trailing[1]:sub(2)
    if trailing[1] == '' then table.remove(trailing, 1) end
    result.form = vim.trim(table.concat(trailing, ' '))
    while #toks >= form_idx do table.remove(toks) end
  end

  for _, tok in ipairs(toks) do
    if is_template(tok) then
      if result.template then return nil, 'multiple templates' end
      result.template = tok:sub(2, -2)
    elseif is_flag(tok) then
      local key, value = tok:match('^([%w_-]+)=(.*)$')
      result.flags[key] = value
    elseif is_url_shaped(tok) and not result.url then
      result.url = tok
    else
      return nil, 'unexpected token: ' .. tok
    end
  end

  return result
end

function M.resolve_url(url)
  if not url then return nil end
  if url:match('^%d+$') then return 'nrepl://localhost:' .. url end
  if url:match('^%w[%w+-]*://') then return url end
  if vim.fn.filereadable(url) == 1 then
    local lines = vim.fn.readfile(url, '', 1)
    local port = lines[1] and lines[1]:match('%d+')
    if port then return 'nrepl://localhost:' .. port end
  end
  return url
end

function M.plan(argstr)
  local parsed, err = M.parse(argstr)
  if err then return nil, err end

  if not parsed.url then
    local portfile = M.discover_port_file()
    if not portfile then return nil, 'no URL given and no .nrepl-port found' end
    parsed.url = portfile
  end

  if parsed.template and not parsed.form then
    local name, arg = parsed.template:match('^([^:]+):?(.*)$')
    arg = arg ~= '' and arg or nil
    local form, terr = templates.resolve(name, arg)
    if terr then return nil, terr end
    parsed.form = form
  end

  return {
    url = M.resolve_url(parsed.url),
    path = parsed.flags.path or M.find_project_root(),
    label = parsed.flags.label,
    lang = parsed.flags.lang,
    bootstrap = parsed.form,
    template = parsed.template,
  }
end

return M
