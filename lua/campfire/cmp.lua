-- nvim-cmp completion source for Campfire.
--
-- This module IS the source (a table of `source:method()` fns, as cmp-develop
-- documents). after/plugin/campfire_cmp.lua self-registers it as `campfire` when
-- nvim-cmp is present, so users just add `{ name = 'campfire' }` to their sources
-- — no setup call (lazy-loaders can call require('campfire.cmp').register() once
-- cmp has loaded; it's idempotent). Candidates come from campfire.completion,
-- which prefers nREPL's built-in `completions` op and falls back to cider-nrepl
-- `complete`. Docs/arglists ride inline when the server returns them (cider
-- `extra-metadata`); otherwise resolve() fetches them lazily for the focused
-- item via info/lookup, so the built-in op still gets a documentation window.

local completion = require('campfire.completion')
local runtime = require('campfire.runtime')

local M = {}

-- LSP CompletionItemKind numbers (cmp accepts the raw enum, so we avoid a
-- load-time dependency on cmp). campfire.completion.candidate has already mapped
-- the server's :type to a single char for omnifunc; map both that and the raw
-- type strings so either completion backend lands a sensible icon.
local KIND = {
  f = 3, ['function'] = 3, m = 3, macro = 3, ['special-form'] = 3, -- Function
  v = 6, var = 6, ['local'] = 6, -- Variable
  n = 9, namespace = 9, -- Module
  k = 14, keyword = 14, -- Keyword
  c = 7, class = 7, -- Class
  method = 2, ['static-method'] = 2, -- Method
  field = 5, ['static-field'] = 5, -- Field
  resource = 17, -- File
}
local KIND_TEXT = 1

local function current_client()
  local campfire = require('campfire')
  return campfire.current and campfire.current()
end

-- Build a markdown documentation block from arglists + docstring.
local function doc_markdown(arglists, docstring)
  local parts = {}
  if arglists and arglists ~= '' then
    parts[#parts + 1] = '```clojure\n' .. arglists .. '\n```'
  end
  if docstring and docstring ~= '' then parts[#parts + 1] = docstring end
  if #parts == 0 then return nil end
  return { kind = 'markdown', value = table.concat(parts, '\n\n') }
end

local function to_item(cand, ns)
  return {
    label = cand.word,
    kind = KIND[cand.kind] or KIND_TEXT,
    -- arglists inline beside the label
    labelDetails = cand.menu ~= '' and { detail = ' ' .. cand.menu } or nil,
    detail = cand.menu ~= '' and cand.menu or nil,
    documentation = doc_markdown(cand.menu, cand.info),
    -- stash for resolve() when the server gave no doc (built-in completions op)
    data = { sym = cand.word, ns = ns, has_doc = cand.info ~= '' },
  }
end

function M:is_available()
  local ft = vim.bo.filetype
  return ft == 'clojure' or ft == 'clojurescript' or ft == 'clojurec'
end

-- Clojure symbols carry far more than \k: -, ., /, ?, !, *, +, =, <, >, :, &.
function M:get_keyword_pattern()
  return [[\%(\k\|[-./?!*+=<>:&]\)\+]]
end

function M:get_trigger_characters()
  return { '/', '.', ':' }
end

function M:complete(params, callback)
  local client = current_client()
  if not client then return callback({ items = {}, isIncomplete = false }) end
  local before = params.context.cursor_before_line
  local base = before:sub(params.offset)
  local ns = runtime.ns()
  completion.complete_async(client, base, { ns = ns }, function(cands)
    local items = {}
    for _, c in ipairs(cands) do items[#items + 1] = to_item(c, ns) end
    -- isIncomplete: the server filters by prefix, so re-query as the user types.
    callback({ items = items, isIncomplete = true })
  end)
end

-- Lazily fill the doc window for the focused item when the completion response
-- carried none (the built-in `completions` op returns candidates without docs).
function M:resolve(item, callback)
  if item.documentation or not item.data or item.data.has_doc then
    return callback(item)
  end
  local client = current_client()
  if not client then return callback(item) end
  local ok, data = pcall(require('campfire.info').lookup, item.data.sym, {
    ns = item.data.ns,
    client = client,
  })
  if ok and type(data) == 'table' then
    local arglists = data['arglists-str'] or (data.arglists and table.concat(data.arglists, ' '))
    item.documentation = doc_markdown(arglists, data.doc)
  end
  callback(item)
end

-- Register the source with nvim-cmp. Called automatically from
-- after/plugin/campfire_cmp.lua; lazy-loaders can call it once cmp is loaded.
-- Idempotent (registering twice would yield duplicate candidates) and a no-op
-- returning false when nvim-cmp isn't installed, so it's always safe to call.
function M.register()
  if M._registered then return true end
  local ok, cmp = pcall(require, 'cmp')
  if not ok then return false end
  cmp.register_source('campfire', M)
  M._registered = true
  return true
end

M._to_item = to_item
M._doc_markdown = doc_markdown

return M
