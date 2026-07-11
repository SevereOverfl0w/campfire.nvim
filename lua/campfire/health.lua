local M = {}

local function call(name, message)
  vim.health[name](message)
end

function M.check()
  call('start', 'campfire')
  if vim.fn.has('nvim') == 1 then
    call('ok', 'Neovim detected')
  else
    call('error', 'Neovim required')
  end

  local ok = pcall(require, 'mini.test')
  if ok then
    call('ok', 'mini.test available')
  else
    call('warn', 'mini.test not found; tests require mini.nvim')
  end

  local none_ok = pcall(require, 'campfire.none_ls')
  if none_ok then call('ok', 'none-ls adapter module loads') end

  if vim.fn.executable('curl') == 1 then
    call('ok', 'curl available (required for http(s) drawbridge connections)')
  else
    call('warn', 'curl not found; http(s) drawbridge connections will fail')
  end
  call('info', 'Start an nREPL and run :Connect nrepl://localhost:7888, '
    .. 'nrepl+unix:///path/to/socket, or https://host/repl (drawbridge)')
end

return M
