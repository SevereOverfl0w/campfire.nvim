local runtime = require('campfire.runtime')

local M = {}

-- tree-sitter-clojure node types. Bracketed collections — the innermost of
-- these enclosing the cursor is what cpp selects (fireplace's "innermost form").
local COLLECTION = {
  list_lit = true, vec_lit = true, map_lit = true, set_lit = true,
  anon_fn_lit = true, read_cond_lit = true,
}

-- Reader prefixes the grammar parses as a wrapper node sitting ABOVE its target
-- (e.g. '(a b) is list_lit <- quoting_lit). A prefix binds to the form it wraps,
-- so once we find the innermost collection we absorb any enclosing wrapper chain
-- upward — the prefix bytes are part of the form to evaluate ('(a b), not (a b)).
local PREFIX_WRAPPER = {
  quoting_lit = true, syn_quoting_lit = true, unquoting_lit = true,
  unquote_splicing_lit = true, derefing_lit = true, var_quoting_lit = true,
  tagged_or_ctor_lit = true,
}

-- Scalars. Selectable as a form only at top level (a bare/prefixed atom with no
-- enclosing collection); inside a collection cpp selects the collection,
-- matching fireplace (va) never grabs a bare word).
local ATOM = {
  sym_lit = true, kwd_lit = true, num_lit = true, str_lit = true,
  char_lit = true, bool_lit = true, nil_lit = true, regex_lit = true,
}

-- A node directly evaluable when it is the top-level form. Excludes comment /
-- dis_expr / meta_lit, so a top-level ; comment or #_ discard yields no form.
local SELECTABLE = {}
for _, set in ipairs({ COLLECTION, PREFIX_WRAPPER, ATOM }) do
  for t in pairs(set) do SELECTABLE[t] = true end
end

local function comment_form(node, buf)
  if node:type() ~= 'list_lit' then return false end
  return vim.startswith(vim.treesitter.get_node_text(node, buf), '(comment')
end

local function absorb_prefix(node)
  while node:parent() and PREFIX_WRAPPER[node:parent():type()] do
    node = node:parent()
  end
  return node
end

-- Walk up from the cursor node to the form node.
--   root=false (cpp): the innermost enclosing collection (with its reader-macro
--     prefixes absorbed), or a top-level atom/prefixed-atom when nothing
--     bracketed encloses the cursor.
--   root=true: the top-level form (direct child of source, or of a rich
--     (comment …) so root inside a comment evals the inner form).
-- Returns the chosen node, or nil when the cursor is outside any evaluable form
-- (whitespace, a ; comment, a bare #_ discard).
local function walk(node, buf, root)
  while node and node:type() ~= 'source' do
    local t = node:type()
    if root then
      local parent = node:parent()
      if not parent or parent:type() == 'source' or comment_form(parent, buf) then
        return SELECTABLE[t] and node or nil
      end
    else
      if COLLECTION[t] then return absorb_prefix(node) end
      local parent = node:parent()
      if not parent or parent:type() == 'source' then
        return SELECTABLE[t] and node or nil
      end
    end
    node = node:parent()
  end
  return nil
end

-- node:range() is 0-indexed with end-exclusive (er, ec); campfire's extract
-- shape is 1-indexed with inclusive end_column. ec is one past the last byte,
-- so end_column = ec is the last byte 1-indexed inclusive. Content comes from
-- the same node so range and text can never disagree.
local function node_region(node, buf)
  local sr, sc, er, ec = node:range()
  return {
    code = vim.treesitter.get_node_text(node, buf),
    file = vim.api.nvim_buf_get_name(buf),
    line = sr + 1, column = sc + 1,
    end_line = er + 1, end_column = ec,
  }
end

-- (region|nil, ts_used). ts_used=false signals the caller to fall back: a
-- buffer whose filetype has no parser returns ok=true, parser=nil (no raise).
local function ts_form(buf, root)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then return nil, false end
  parser:parse()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = vim.treesitter.get_node({ bufnr = buf, pos = { cursor[1] - 1, cursor[2] } })
  local form = walk(node, buf, root)
  return form and node_region(form, buf), true
end

-- No-parser fallback: campfire's own reader, top-level granularity only
-- (runtime exposes no innermost finder). Still prefix/string/comment aware, so
-- strictly better than the old va) grab.
local function fallback_form(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local f = runtime.form_at_line(text, row)
  if not f then return nil end
  local _, nl = f.code:gsub('\n', '\n')
  local last = f.code:match('([^\n]*)$')
  return {
    code = f.code,
    file = vim.api.nvim_buf_get_name(buf),
    line = f.line, column = f.column,
    end_line = f.line + nl,
    end_column = (nl == 0) and (f.column + #f.code - 1) or #last,
  }
end

-- Region of the form under the cursor, for cpp / a no-range :Eval.
--   opts.root - true selects the top-level form, default = innermost.
-- Returns the extract shape {code,file,line,column,end_line,end_column}, or nil
-- when the cursor sits outside any form (whitespace, a ; comment, a bare #_).
function M.form_at_cursor(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local region, ts_used = ts_form(buf, opts.root)
  if ts_used then return region end
  return fallback_form(buf)
end

return M
