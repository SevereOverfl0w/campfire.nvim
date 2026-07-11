local M = {}

local entries = {}
local max_size = 100

-- Whether the open :Last preview tails the newest eval. Armed only by a bare
-- :Last (count 0); a counted :Last pins to that historical entry. show() pins
-- by default, so any other open path (e.g. operator preview) is a snapshot.
local follow = false

function M.configure(opts)
  max_size = (opts and opts.history_size) or max_size
end

function M.start(entry)
  entry.messages = {}
  entry.started_at = vim.loop.hrtime()
  entries[#entries + 1] = entry
  while #entries > max_size do table.remove(entries, 1) end
  return entry
end

function M.record(entry, message)
  entry.messages[#entry.messages + 1] = message
  if message.ns then entry.ns = message.ns end
  if message.ex then entry.ex = message.ex end
end

function M.finish(entry)
  entry.finished_at = vim.loop.hrtime()
  entry.response = require('campfire.client').combine(entry.messages)
  return entry
end

function M.last(count)
  return entries[#entries - (count or 1) + 1]
end

function M.all()
  return entries
end

function M.clear()
  entries = {}
end

local PREFIXES = { out = '; ', err = ';! ', value = '' }

local function append(target, kind, text)
  local prefix = PREFIXES[kind] or ''
  local parts = vim.split(text, '\n', { plain = true })
  while #parts > 1 and parts[#parts] == '' do parts[#parts] = nil end
  for _, line in ipairs(parts) do target[#target + 1] = { kind = kind, text = prefix .. line } end
end

function M.format_chunks(chunks)
  local out = {}
  for _, chunk in ipairs(chunks or {}) do append(out, chunk.kind, chunk.text) end
  return out
end

function M.format_entry(entry)
  local out = {}
  local buf = { out = '', err = '', value = '' }

  local function emit_complete(kind, text)
    local combined = buf[kind] .. text
    local i = 1
    while true do
      local nl = combined:find('\n', i, true)
      if not nl then break end
      out[#out + 1] = { kind = kind, text = (PREFIXES[kind] or '') .. combined:sub(i, nl - 1) }
      i = nl + 1
    end
    buf[kind] = combined:sub(i)
  end

  for _, message in ipairs(entry.messages or {}) do
    if message.err then emit_complete('err', message.err) end
    if message.out then emit_complete('out', message.out) end
    if message.value then emit_complete('value', message.value) end
  end

  for _, kind in ipairs({ 'err', 'out', 'value' }) do
    if buf[kind] ~= '' then
      out[#out + 1] = { kind = kind, text = (PREFIXES[kind] or '') .. buf[kind] }
    end
  end
  return out
end

function M.index_of(entry)
  for i, e in ipairs(entries) do
    if e == entry then return i end
  end
end

local function summary_line(formatted)
  for _, c in ipairs(formatted) do
    if c.kind == 'err' then return c.text, true end
  end
  for _, c in ipairs(formatted) do
    if c.kind == 'value' then return c.text, false end
  end
  for _, c in ipairs(formatted) do
    if c.kind == 'out' then return c.text, false end
  end
  return '', false
end

function M.loclist()
  local items = {}
  for _, entry in ipairs(entries) do
    local text, is_err = summary_line(M.format_entry(entry))
    items[#items + 1] = {
      filename = entry.file ~= '' and entry.file or nil,
      bufnr = (not entry.file or entry.file == '') and vim.fn.bufnr('%') or nil,
      lnum = entry.line or 1,
      col = entry.column or 1,
      -- Vim loclist text fields are NUL-incapable: a Lua string carrying a NUL
      -- (legitimate in eval output) converts to a Blob, and setloclist() then
      -- raises E976. Render NUL as ^@ like Vim does for buffer display; the full
      -- output (NUL-safe in the preview buffer) stays the source of truth.
      text = text:gsub('%z', '^@'),
      type = is_err and 'E' or 'I',
    }
  end
  return items
end

function M.show(entry)
  if not entry then return 'echoerr ' .. vim.fn.string('Campfire: history entry not found') end
  follow = false

  local items = M.format_entry(entry)
  local lines = {}
  for _, item in ipairs(items) do lines[#lines + 1] = item.text end

  local idx = M.index_of(entry)
  if idx then
    vim.fn.setloclist(0, {}, ' ', {
      title = 'Campfire history',
      items = M.loclist(),
      idx = idx,
    })
  end

  local bufnr = vim.fn.bufnr('campfire://last')
  if bufnr == -1 then bufnr = vim.fn.bufnr('campfire://last', true) end
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'clojure'
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  -- Only :pedit when the preview isn't already showing this buffer; re-editing
  -- a displayed nofile buffer reloads it (no backing file) and blanks the lines
  -- just written. When already open the in-place set above is the refresh.
  if vim.fn.bufwinid(bufnr) == -1 then vim.cmd('pedit campfire://last') end
  return ''
end

-- True when the campfire://last preview buffer is displayed in a window of the
-- current tabpage.
local function preview_open()
  local bufnr = vim.fn.bufnr('campfire://last')
  return bufnr ~= -1 and vim.fn.bufwinid(bufnr) ~= -1
end

-- Re-render the last-output preview to the newest entry. No-op unless the
-- preview is open AND in follow mode (opened by a bare :Last); a counted :Last
-- pins to its entry and is left untouched. Call after an eval completes (a new
-- history entry exists). Mirrors vim-fireplace's s:RefreshLast, but fireplace
-- always snaps to newest whereas a counted :Last here stays put.
function M.refresh_preview()
  if not follow or not preview_open() then return end
  M.show(M.last(1))
  follow = true -- show() cleared it; the tail stays armed
end

-- count 0 (bare :Last) tails the newest eval; count N pins to the Nth-newest.
function M.command(args)
  local count = (args and args[1]) or 0
  local cmd = M.show(M.last(count == 0 and 1 or count))
  if count == 0 then follow = true end
  return cmd
end

return M
