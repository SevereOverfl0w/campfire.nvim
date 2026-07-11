local eval = require('campfire.eval')
local history = require('campfire.history')

local M = {}

local NS = vim.api.nvim_create_namespace('campfire-eval-virt')

local HL_KIND = {
  value = 'CampfireValue',
  out   = 'CampfireOut',
  err   = 'CampfireErr',
}

local highlights_set = false
local function ensure_highlights()
  if highlights_set then return end
  highlights_set = true
  vim.cmd([[
    hi default link CampfireValue Constant
    hi default link CampfireOut Comment
    hi default link CampfireErr WarningMsg
  ]])
end

local overlays = {}

local function key(buf, line) return buf .. ':' .. line end

local function max_lines()
  return tonumber(vim.g.campfire_eval_virt_max_lines) or 20
end

local function build_virt_lines(o)
  local cap = max_lines()
  local lines = {}
  for _, item in ipairs(history.format_chunks(o.chunks)) do
    if #lines >= cap then break end
    local hl = HL_KIND[item.kind] or 'Normal'
    lines[#lines + 1] = { { item.text, hl } }
  end
  if #lines >= cap then
    lines[cap] = { { '; … truncated', 'Comment' } }
  end
  return lines
end

local function place_extmark(o, virt_lines)
  if not vim.api.nvim_buf_is_valid(o.buf) then return end
  local total = vim.api.nvim_buf_line_count(o.buf)
  local line = math.min(o.line, total - 1)
  if line < 0 then line = 0 end
  o.mark_id = vim.api.nvim_buf_set_extmark(o.buf, NS, line, 0, {
    id = o.mark_id,
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
end

local function render(o) place_extmark(o, build_virt_lines(o)) end

local function set_pending(o)
  place_extmark(o, { { { ';…', 'Comment' } } })
end

local function flush_line_buf(o, kind)
  local rest = o.line_buf[kind]
  if rest and rest ~= '' then
    o.chunks[#o.chunks + 1] = { kind = kind, text = rest }
    o.line_buf[kind] = ''
  end
end

local function append_stream(o, kind, text)
  if text == nil or text == '' then return end
  local combined = (o.line_buf[kind] or '') .. text
  local last_nl = combined:find('\n[^\n]*$')
  if last_nl then
    o.chunks[#o.chunks + 1] = { kind = kind, text = combined:sub(1, last_nl - 1) }
    o.line_buf[kind] = combined:sub(last_nl + 1)
  elseif combined:sub(-1) == '\n' then
    o.chunks[#o.chunks + 1] = { kind = kind, text = combined:sub(1, -2) }
    o.line_buf[kind] = ''
  else
    o.line_buf[kind] = combined
  end
end

local function on_message(o, message)
  if o.timer then
    pcall(function() o.timer:stop() end)
    pcall(function() o.timer:close() end)
    o.timer = nil
  end
  if message.out then append_stream(o, 'out', message.out) end
  if message.err then append_stream(o, 'err', message.err) end
  if message.value then append_stream(o, 'value', message.value) end
  if vim.tbl_contains(message.status or {}, 'done') then
    flush_line_buf(o, 'out')
    flush_line_buf(o, 'err')
    flush_line_buf(o, 'value')
  end
  vim.schedule(function() render(o) end)
end

local function save_state()
  return {
    reg = vim.fn.getreg('"'),
    regtype = vim.fn.getregtype('"'),
    reg0 = vim.fn.getreg('0'),
    reg0type = vim.fn.getregtype('0'),
    clipboard = vim.o.clipboard,
    selection = vim.o.selection,
    mark_tick = vim.fn.getpos("'`"),
    mark_line = vim.fn.getpos("''"),
  }
end

local function restore_state(state)
  vim.fn.setreg('"', state.reg, state.regtype)
  vim.fn.setreg('0', state.reg0, state.reg0type)
  vim.o.clipboard = state.clipboard
  vim.o.selection = state.selection

  if state.mark_tick[2] == 0 then
    pcall(vim.cmd, [[delmarks `]])
  else
    vim.fn.setpos("'`", state.mark_tick)
  end

  if state.mark_line[2] == 0 then
    pcall(vim.cmd, [[delmarks ']])
  else
    vim.fn.setpos("''", state.mark_line)
  end
end

local function mark(name)
  local pos = vim.fn.getpos(name)
  if pos[2] == 0 then return nil end
  return { line = pos[2], column = pos[3] }
end

local function ordered(start_pos, end_pos)
  if start_pos.line < end_pos.line then return start_pos, end_pos end
  if start_pos.line > end_pos.line then return end_pos, start_pos end
  if start_pos.column <= end_pos.column then return start_pos, end_pos end
  return end_pos, start_pos
end

local function selection_marks()
  local start_pos = mark("'[") or mark("'<")
  local end_pos = mark("']") or mark("'>")
  if not start_pos or not end_pos then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return { line = line, column = 1 }, { line = line, column = #vim.api.nvim_get_current_line() }
  end
  return ordered(start_pos, end_pos)
end

local function selected_text(kind)
  local start_pos, end_pos = selection_marks()
  if kind == 'line' then
    local lines = vim.api.nvim_buf_get_lines(0, start_pos.line - 1, end_pos.line, false)
    return table.concat(lines, '\n'), start_pos, end_pos
  end

  local lines = vim.api.nvim_buf_get_text(0, start_pos.line - 1, start_pos.column - 1, end_pos.line - 1, end_pos.column, {})
  return table.concat(lines, '\n'), start_pos, end_pos
end

function M.extract(kind)
  local state = save_state()
  vim.o.selection = 'inclusive'
  vim.o.clipboard = vim.o.clipboard:gsub('unnamedplus', ''):gsub('unnamed', '')

  local ok, result = pcall(function()
    if type(kind) == 'number' then
      -- cpp: innermost enclosing form under the cursor (fireplace parity),
      -- via tree-sitter with a reader fallback. See campfire.form.
      local region = require('campfire.form').form_at_cursor()
      if not region then error('Campfire: no form under cursor') end
      return region
    end

    local code, start_pos, end_pos = selected_text(kind == 'line' and 'line' or 'char')
    return {
      code = code,
      file = vim.api.nvim_buf_get_name(0),
      line = start_pos.line,
      column = start_pos.column,
      end_line = end_pos.line,
      end_column = end_pos.column,
    }
  end)
  restore_state(state)
  if not ok then error(result) end
  return result
end

local function resolve_client()
  return require('campfire').ensure_current()
end

local function strip_local(opts)
  opts.end_line = nil
  opts.end_column = nil
  return opts
end

function M.eval(kind)
  local opts = M.extract(kind)
  strip_local(opts)
  local client, err = resolve_client()
  if not client then error(err or 'Campfire: no live nREPL connection') end
  opts.ns = require('campfire.runtime').ns()
  opts.bufnr = vim.api.nvim_get_current_buf()
  local handle, eerr = eval.with_prep(client, opts)
  if eerr then error(eerr) end
  eval.foreground(client, handle, { echo = true })
  return ''
end

function M.eval_replace(kind)
  local function err_echo(msg) vim.api.nvim_echo({ { msg, 'ErrorMsg' } }, true, {}) end

  local ok, opts = pcall(M.extract, kind)
  if not ok or not opts or not opts.code or opts.code == '' then
    err_echo('Campfire: no form to evaluate')
    return
  end

  local client, cerr = resolve_client()
  if not client then
    err_echo(cerr or 'Campfire: no live nREPL connection')
    return
  end

  local runtime = require('campfire.runtime')
  local buf = vim.api.nvim_get_current_buf()
  local start_row = opts.line - 1
  local start_col = opts.column - 1
  local end_row = opts.end_line - 1
  local end_col = opts.end_column

  local state = { value = nil, err = {}, done = false }
  local handle, eerr = eval.with_prep(client, {
    code = opts.code,
    file = opts.file,
    line = opts.line,
    column = opts.column,
    ns = runtime.ns(),
    bufnr = buf,
    silent = true,
  }, function(message)
    if message.value then state.value = (state.value or '') .. message.value end
    if message.err then state.err[#state.err + 1] = message.err end
    if vim.tbl_contains(message.status or {}, 'done') then state.done = true end
  end)
  if not handle then
    vim.schedule(function() vim.api.nvim_err_writeln(eerr or 'Campfire: eval failed') end)
    return
  end

  vim.wait(5000, function() return state.done end, 10)
  if not state.done then
    pcall(function() client:interrupt(handle.id) end)
    err_echo('Campfire: eval timeout')
    return
  end
  if #state.err > 0 then
    err_echo((table.concat(state.err, '')):gsub('%s+$', ''))
    return
  end
  if not state.value then
    err_echo('Campfire: no value returned')
    return
  end

  local lines = vim.split((state.value:gsub('%s+$', '')), '\n', { plain = true })
  vim.api.nvim_buf_set_text(buf, start_row, start_col, end_row, end_col, lines)
  vim.api.nvim_win_set_cursor(0, { start_row + 1, start_col })
end

function M.virt_eval(kind)
  ensure_highlights()
  local opts = M.extract(kind)
  local end_line = (opts.end_line or opts.line or 1) - 1
  local buf = vim.api.nvim_get_current_buf()
  local k = key(buf, end_line)

  local prev = overlays[k]
  if prev then
    if prev.timer then
      pcall(function() prev.timer:stop() end)
      pcall(function() prev.timer:close() end)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, NS, prev.mark_id)
    end
    overlays[k] = nil
  end

  local client, cerr = resolve_client()
  if not client then
    local msg = cerr or 'Campfire: no live nREPL connection'
    vim.schedule(function() vim.api.nvim_err_writeln(msg) end)
    return ''
  end

  local o = { buf = buf, line = end_line, chunks = {}, line_buf = {} }
  overlays[k] = o
  o.timer = vim.defer_fn(function()
    o.timer = nil
    if overlays[k] == o and #o.chunks == 0 then set_pending(o) end
  end, 300)

  local opts_silent = vim.deepcopy(opts)
  opts_silent.silent = true
  opts_silent.ns = require('campfire.runtime').ns()
  opts_silent.bufnr = buf
  strip_local(opts_silent)

  local _, eerr = eval.with_prep(client, opts_silent, function(message)
    on_message(o, message)
  end)
  if eerr then
    overlays[k] = nil
    local msg = tostring(eerr)
    vim.schedule(function() vim.api.nvim_err_writeln(msg) end)
    return ''
  end
  o.entry = history.last(1)
  return ''
end

local function nearest_overlay()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local best, best_dist
  for _, o in pairs(overlays) do
    if o.buf == buf then
      local d = math.abs(o.line - row)
      if not best_dist or d < best_dist then best, best_dist = o, d end
    end
  end
  return best
end

local function flat_lines(o)
  local out = {}
  for _, item in ipairs(history.format_chunks(o.chunks)) do out[#out + 1] = item.text end
  return out
end

function M.goto_virt()
  local o = nearest_overlay()
  if not o then
    vim.schedule(function() vim.api.nvim_err_writeln('Campfire: no virt overlay in buffer') end)
    return
  end
  local lines = flat_lines(o)
  if #lines == 0 then lines = { '' } end
  vim.lsp.util.open_floating_preview(lines, 'clojure', {
    border = 'rounded',
    focus_id = 'campfire-result',
    max_width = math.max(40, math.floor(vim.o.columns / 2)),
    max_height = math.max(1, math.floor(vim.o.lines / 2)),
  })
end

function M.preview_virt()
  local o = nearest_overlay()
  if not o or not o.entry then
    vim.schedule(function() vim.api.nvim_err_writeln('Campfire: no virt overlay with history entry') end)
    return
  end
  local cmd = history.show(o.entry)
  if cmd and cmd ~= '' then vim.cmd(cmd) end
end

function M.clear(bang)
  if bang then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
      end
    end
    for _, o in pairs(overlays) do
      if o.timer then pcall(function() o.timer:close() end) end
    end
    overlays = {}
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  for k, o in pairs(overlays) do
    if o.buf == buf then
      if o.timer then pcall(function() o.timer:close() end) end
      overlays[k] = nil
    end
  end
end

return M
