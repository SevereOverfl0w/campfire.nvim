local M = {}

local SIGIL = { E = 'E', W = 'W', I = 'I', N = 'N' }

function M.item(data)
  return {
    filename = data.filename or '',
    lnum = tonumber(data.lnum) or 0,
    col = tonumber(data.col) or 0,
    type = data.type or 'E',
    text = data.text or '',
  }
end

-- Render an absolute path as a project-friendly short form: prefer cwd-
-- relative, fall back to home-relative (`~/...`), then the raw path.
function M.short_path(path)
  if not path or path == '' then return '' end
  if path:sub(1, 1) ~= '/' then return path end
  local rel = vim.fn.fnamemodify(path, ':.')
  if rel and rel ~= path and rel ~= '' then return rel end
  local home = vim.fn.fnamemodify(path, ':~')
  return home or path
end

-- Vim re-invokes textfunc on every redraw, and getqflist({items=1}) copies the
-- whole list each call — O(n) per redraw line on a big list. The items only
-- change when the list's changedtick bumps, so cache the last fetch keyed by
-- (kind, id, tick): a redraw that doesn't mutate the list reuses it, and a cheap
-- changedtick query gates the expensive items copy.
local fetch_cache = { key = nil, items = nil }

local function fetch_items(info)
  local tick = info.quickfix == 1
    and vim.fn.getqflist({ id = info.id, changedtick = 0 }).changedtick
    or vim.fn.getloclist(info.winid or 0, { id = info.id, changedtick = 0 }).changedtick
  local key = string.format('%d:%d:%d', info.quickfix, info.id, tick)
  if fetch_cache.key == key then return fetch_cache.items end
  local query = { id = info.id, items = 1 }
  local items = info.quickfix == 1
    and vim.fn.getqflist(query).items
    or vim.fn.getloclist(info.winid or 0, query).items
  fetch_cache.key, fetch_cache.items = key, items
  return items
end

-- Quickfix textfunc — Vim calls this with {quickfix, id, start_idx, end_idx,
-- winid?}. Returns one rendered line per index. Wired per-list in M.set so
-- it only affects Campfire's lists; the default formatter still handles
-- other lists (greps, LSP diagnostics, etc).
function M.textfunc(info)
  local list = fetch_items(info)
  local lines = {}
  for i = info.start_idx, info.end_idx do
    local it = list[i]
    if not it then
      lines[#lines + 1] = ''
    elseif it.type == '' then
      -- Continuation line (expected/actual/error detail): render verbatim so
      -- a multi-line failure reads naturally, with no sigil or location.
      lines[#lines + 1] = it.text or ''
    else
      local name = ''
      if it.bufnr and it.bufnr ~= 0 then
        local fname = vim.api.nvim_buf_get_name(it.bufnr)
        if fname ~= '' then name = M.short_path(fname) end
      end
      local sigil = SIGIL[it.type] or '·'
      if name == '' then
        lines[#lines + 1] = string.format('%s | %s', sigil, it.text or '')
      elseif (it.lnum or 0) > 0 then
        lines[#lines + 1] = string.format('%s %s:%d | %s', sigil, name, it.lnum, it.text or '')
      else
        lines[#lines + 1] = string.format('%s %s | %s', sigil, name, it.text or '')
      end
    end
  end
  return lines
end

function M.set(items, title)
  local qf = vim.tbl_map(M.item, items or {})
  vim.fn.setqflist({}, ' ', {
    title = title or 'Campfire',
    items = qf,
    quickfixtextfunc = "v:lua.require'campfire.quickfix'.textfunc",
  })
  return vim.fn.getqflist({ id = 0 }).id
end

-- Notify qf-opening plugins (vim-qf, etc.) that a Campfire list finished
-- populating. setqflist() doesn't fire QuickFixCmdPost itself, so emit it as if
-- the list came from :cgetexpr — which is how we populate it — letting those
-- plugins auto-open on their own terms. Kept separate from M.set so a streamed
-- list (tests) fires this once, when done, rather than on every live update —
-- otherwise a mid-stream auto-open yanks the cursor while results trickle in.
function M.populated()
  pcall(vim.api.nvim_exec_autocmds, 'QuickFixCmdPost', { pattern = 'cgetexpr', modeline = false })
end

-- Replace the items of an existing Campfire list in place (by id), for live
-- updates as results stream in. Doesn't create a new list or re-fire the
-- auto-open autocmd, so the window isn't reopened/refocused on every update.
function M.replace(id, items)
  vim.fn.setqflist({}, 'r', {
    id = id,
    items = vim.tbl_map(M.item, items or {}),
    quickfixtextfunc = "v:lua.require'campfire.quickfix'.textfunc",
  })
end

-- Append items to an existing Campfire list (by id), action 'a'. Used for live
-- streaming so each update marshals only the new items instead of the whole
-- list (a replace is O(total) per chunk → O(n²) over a chatty run). The list's
-- quickfixtextfunc, set at creation, is preserved by 'a'.
function M.append(id, items)
  if not items or #items == 0 then return end
  vim.fn.setqflist({}, 'a', {
    id = id,
    items = vim.tbl_map(M.item, items),
  })
end

return M
