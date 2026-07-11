local capabilities = require('campfire.capabilities')
local runtime = require('campfire.runtime')

local M = {}

local kinds = {
  ['function'] = 'f',
  macro = 'm',
  var = 'v',
  namespace = 'n',
  keyword = 'k',
  class = 'c',
}

function M.context()
  local ok, parser = pcall(vim.treesitter.get_parser, 0, 'clojure')
  if ok and parser then pcall(function() parser:parse() end) end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return line:sub(1, col) .. ' __prefix__ ' .. line:sub(col + 1)
end

function M.request(base, opts)
  opts = opts or {}
  local selected, err = capabilities.view(opts.describe or {}, opts.runtime or 'clj'):require('complete')
  if not selected then return nil, err end
  return {
    op = selected.op or 'complete',
    symbol = base or '',
    prefix = base or '',
    ns = opts.ns,
    ['extra-metadata'] = { 'arglists', 'doc' },
    context = opts.context or M.context(),
    -- non-eval op: route to main so cljs completes against main's compiler-env.
    scope = 'user',
  }
end

function M.candidate(item)
  if type(item) == 'string' then return { word = item } end
  return {
    word = item.candidate or item.word or item.name,
    kind = kinds[item.type] or item.type or '',
    menu = item.arglists and table.concat(item.arglists, ' ') or '',
    info = item.doc or '',
  }
end

function M.extract(message)
  local values = message.completions or message.value or {}
  local out = {}
  for _, item in ipairs(values) do
    out[#out + 1] = M.candidate(item)
  end
  return out
end

function M.complete(client, base, opts)
  opts = opts or {}
  if not client then return {} end
  local request = M.request(base, vim.tbl_extend('force', {
    describe = client.describe,
    ns = opts.ns,
    context = opts.context,
  }, opts.request or {}))
  if not request then return {} end
  local response = client:request_sync(request)
  if response.err then
    vim.notify('Campfire completion: ' .. tostring(response.err), vim.log.levels.WARN)
    return {}
  end
  return M.extract(response)
end

-- Async sibling of M.complete: fires callback(candidates) once the complete op
-- is done, without blocking the UI (request_sync stalls the editor — fine for
-- omnifunc's synchronous contract, wrong for nvim-cmp). Candidates use the same
-- {word,kind,menu,info} shape M.candidate produces. callback({}) on no client,
-- bad request, or an errored response.
function M.complete_async(client, base, opts, callback)
  opts = opts or {}
  if not client then return callback({}) end
  local request = M.request(base, vim.tbl_extend('force', {
    describe = client.describe,
    ns = opts.ns,
    context = opts.context,
  }, opts.request or {}))
  if not request then return callback({}) end
  local items
  client:request(request, function(message)
    if message.completions or message.value then items = M.extract(message) end
    if message.err then items = items or {} end
    for _, status in ipairs(message.status or {}) do
      if status == 'done' then callback(items or {}) end
    end
  end)
end

function M.omnifunc(args)
  local findstart, base = args[1], args[2]
  if findstart == 1 or findstart == '1' then
    local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col('.') - 1)
    local start = before:find('[%w_?!%*%+/%=<%>%.:-]*$') or (#before + 1)
    return start - 1
  end

  local campfire = require('campfire')
  local client
  if campfire.ensure_current then
    client = campfire.ensure_current()
  else
    client = campfire.current()
  end
  return M.complete(client, base, { ns = runtime.ns() })
end

return M
