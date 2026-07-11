local M = {}

local jvm_fallbacks = {
  classpath = true,
  info = true,
  doc = true,
  source = true,
  test = true,
  stacktrace = true,
}

local preferred_ops = {
  complete = { 'complete', 'completions' },
  info = { 'info', 'lookup' },
  eldoc = { 'eldoc', 'info' },
  classpath = { 'classpath' },
  test = { 'test-var-query', 'test', 'test-all' },
  stacktrace = { 'analyze-last-stacktrace', 'stacktrace' },
  macroexpand = { 'macroexpand' },
}

local View = {}
View.__index = View

function M.view(describe, runtime)
  return setmetatable({ describe = describe or {}, runtime = runtime or 'clj' }, View)
end

function View:has(op)
  return self.describe.ops and self.describe.ops[op] ~= nil
end

function View:first(capability)
  for _, op in ipairs(preferred_ops[capability] or { capability }) do
    if self:has(op) then return op end
  end
end

function View:can_fallback(capability)
  return self.runtime == 'clj' and jvm_fallbacks[capability] == true
end

function View:require(capability)
  local op = self:first(capability)
  if op then return { op = op, fallback = false } end
  if self:can_fallback(capability) then return { op = nil, fallback = true } end
  return nil, ('Campfire: %s unavailable for %s runtime'):format(capability, self.runtime)
end

return M
