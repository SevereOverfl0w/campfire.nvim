local M = {}

M.builtins = {
  node = {
    form = "(do (require 'cljs.repl.node) (cider.piggieback/cljs-repl (cljs.repl.node/repl-env)))",
  },
  browser = {
    form = "(do (require 'cljs.repl.browser) (cider.piggieback/cljs-repl (cljs.repl.browser/repl-env)))",
  },
  nbb = {
    form = nil,
  },
  figwheel = {
    form = "(do (require 'figwheel-sidecar.repl-api) (figwheel-sidecar.repl-api/start-figwheel!) (figwheel-sidecar.repl-api/cljs-repl))",
  },
  ['figwheel-main'] = {
    form = function(arg)
      if not arg or arg == '' then error('Campfire: <figwheel-main:BUILD> requires a build id') end
      return ("(do (require 'figwheel.main) (figwheel.main/start %s))"):format(arg)
    end,
  },
  shadow = {
    form = function(arg)
      if not arg or arg == '' then error('Campfire: <shadow:BUILD> requires a build id') end
      return ("(do (require 'shadow.cljs.devtools.api) (shadow.cljs.devtools.api/repl %s))"):format(arg)
    end,
  },
}

function M.resolve(name, arg)
  local entry = M.builtins[name]
  if entry == nil then return nil, 'unknown template <' .. name .. '>' end
  if entry.form == nil then return nil, nil end
  if type(entry.form) == 'function' then
    local ok, form = pcall(entry.form, arg)
    if not ok then return nil, form end
    return form, nil
  end
  return entry.form, nil
end

function M.list()
  local names = {}
  for k, _ in pairs(M.builtins) do names[#names + 1] = k end
  table.sort(names)
  return names
end

return M
