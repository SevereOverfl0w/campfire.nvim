local capabilities = require('campfire.capabilities')

local M = {}

local function current_client()
  return require('campfire').ensure_current()
end

local function buffer_runtime(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  local ext = name:match('%.([%w]+)$')
  if ext == 'cljs' then return 'cljs' end
  if ext == 'bb' then return 'bb' end
  return 'clj'
end

function M.request(code, opts)
  opts = opts or {}
  local view = capabilities.view(opts.describe or {}, opts.runtime or 'clj')
  if not view:has('format-code') then return nil, 'format-code op unavailable' end
  return { op = 'format-code', code = code, scope = 'tool' }
end

function M.extract(response)
  if not response then return nil end
  if response.err and response.err ~= '' then return nil, response.err end
  for _, status in ipairs(response.status or {}) do
    if status == 'error' or status == 'format-code-error' then
      return nil, response['format-code-error'] or response.err or 'format-code error'
    end
  end
  return response['formatted-code']
end

function M.format_sync(client, code, opts)
  opts = opts or {}
  if not client then
    local err
    client, err = current_client()
    if not client then return nil, err or 'Campfire: no live nREPL connection' end
  end
  local request, err = M.request(code, { describe = client.describe, runtime = opts.runtime })
  if not request then return nil, err end
  local response = client:request_sync(request, opts.timeout or 2000)
  return M.extract(response)
end

local function lines_to_code(lines)
  return table.concat(lines, '\n')
end

local function replace_range(bufnr, line1, line2, formatted)
  local new_lines = vim.split(formatted, '\n', { plain = true })
  if #new_lines > 0 and new_lines[#new_lines] == '' then
    new_lines[#new_lines] = nil
  end
  vim.api.nvim_buf_set_lines(bufnr, line1 - 1, line2, false, new_lines)
end

function M.formatexpr(lnum, count)
  lnum = lnum or vim.v.lnum
  count = count or vim.v.count
  if not lnum or lnum < 1 or count == nil or count < 1 then return 1 end

  local mode = vim.fn.mode()
  if mode:match('[iR]') then return 1 end

  local bufnr = vim.api.nvim_get_current_buf()
  local first = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
  if first:match('^%s*;') then return 1 end
  local line1 = lnum
  local line2 = lnum + count - 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  if #lines == 0 then return 0 end

  local client = current_client()
  if not client then return 1 end

  local formatted = M.format_sync(client, lines_to_code(lines), { runtime = buffer_runtime(bufnr) })
  if not formatted or formatted == '' then return 1 end

  replace_range(bufnr, line1, line2, formatted)
  return 0
end

function M.format_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then return true end
  local formatted, err = M.format_sync(nil, lines_to_code(lines), { runtime = buffer_runtime(bufnr) })
  if not formatted then return false, err end
  replace_range(bufnr, 1, #lines, formatted)
  return true
end

function M.command(args)
  local line1 = args[1] or 1
  local line2 = args[2] or line1
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  if #lines == 0 then return '' end
  local formatted, err = M.format_sync(nil, lines_to_code(lines), { runtime = buffer_runtime(bufnr) })
  if not formatted then return 'echoerr ' .. vim.fn.string('Campfire format: ' .. tostring(err or 'unknown error')) end
  replace_range(bufnr, line1, line2, formatted)
  return ''
end

return M
