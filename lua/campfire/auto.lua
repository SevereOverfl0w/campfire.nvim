local M = {}

local port_files = {
  'repl-port',
  '.nrepl-port',
  'target/repl-port',
  '.shadow-cljs/nrepl.port',
}

local function join(dir, name)
  return dir:gsub('/+$', '') .. '/' .. name
end

local function parent(dir)
  local next_dir = vim.fn.fnamemodify(dir, ':h')
  if next_dir == dir then return nil end
  return next_dir
end

local function start_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name ~= '' then return vim.fn.fnamemodify(name, ':p:h') end
  return vim.fn.getcwd()
end

local function read_port(path)
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local text = fd:read('*a') or ''
  fd:close()
  return text:match('^(%d+)')
end

local function endpoint(text)
  return text:match('^%d+$') or text:match('^%a[%w+.-]*://') or text:match('^[^:/]+:%d+$')
end

local function port_result(path, port, root)
  return {
    url = 'nrepl://localhost:' .. port,
    port = tonumber(port),
    file = path,
    root = root,
    mtime = vim.fn.getftime(path),
  }
end

function M.find(opts)
  opts = opts or {}
  local dir = opts.dir or start_dir(opts.bufnr)
  dir = vim.fn.fnamemodify(dir, ':p')

  while dir do
    dir = dir:gsub('/+$', '')
    for _, name in ipairs(port_files) do
      local path = join(dir, name)
      if vim.fn.filereadable(path) == 1 then
        local port = read_port(path)
        if port then return port_result(path, port, dir) end
      end
    end
    dir = parent(dir)
  end
end

function M.resolve(input, opts)
  opts = opts or {}
  if input == nil or input == '' then return M.find(opts) end

  local text = tostring(input):gsub('^file:/+', '/')
  if endpoint(text) then return { url = text } end

  local path = vim.fn.fnamemodify(vim.fn.expand(text), ':p')
  if vim.fn.filereadable(path) == 1 then
    local port = read_port(path)
    if port then return port_result(path, port, vim.fn.fnamemodify(path, ':p:h')) end
  end
  if vim.fn.isdirectory(path) == 1 then return M.find(vim.tbl_extend('force', opts, { dir = path })) end
  return { url = text }
end

return M
