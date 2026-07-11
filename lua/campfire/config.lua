local M = {}

local defaults = {
  auto_connect = true,
  auto_connect_timeout = 3000,
  history_size = 100,
  -- Drop a single jumpable location-list entry at the throw site when an
  -- interactive eval errors, so :ll lands there without :Stacktrace.
  eval_error_loclist = true,
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
  options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  return options
end

function M.get()
  return options
end

return M
