local completion = require('campfire.completion')
local client_mod = require('campfire.client')
local format = require('campfire.format')
local info = require('campfire.info')
local runtime = require('campfire.runtime')

local M = {}

local function current_client()
  local campfire = require('campfire')
  if campfire.ensure_current then return campfire.ensure_current() end
  return campfire.current()
end

local function client_describe()
  local client = current_client()
  return client and client.describe or {}
end

local function line_at(params)
  if not params or not params.content then return nil end
  if params.lsp_params and params.lsp_params.position then
    local position = params.lsp_params.position
    return params.content[position.line + 1], position.character + 1
  end
  local row = params.row or params.line
  if not row then return nil end
  return params.content[row] or params.content[row + 1], params.col or params.column
end

local function symbol_at(line, col)
  if not line then return nil end
  col = tonumber(col) or 1
  for start_col, symbol in line:gmatch('()([%w_?!%*%+/%=<%>%.:-]+)') do
    local end_col = start_col + #symbol - 1
    if col >= start_col and col <= end_col + 1 then return symbol end
    if col + 1 >= start_col and col + 1 <= end_col + 1 then return symbol end
  end
end

function M.symbol(params)
  local line, col = line_at(params)
  local symbol = symbol_at(line, col)
  if symbol and symbol ~= '' then return symbol end
  return params and (params.word or params.word_to_complete) or vim.fn.expand('<cword>')
end

function M.completion(params)
  local client = current_client()
  if not client then return {} end
  local request = completion.request(params and params.word_to_complete or '', {
    describe = client.describe,
    ns = runtime.ns(),
    context = '',
  })
  return request and { request = request } or {}
end

function M.hover(params)
  local word = M.symbol(params)
  local request = info.request(word, { describe = client_describe(), ns = runtime.ns() })
  return request and {
    request = request,
    format = function(data) return info.doc_markdown(word, data) end,
  } or {}
end

function M.signature(params)
  local word = M.symbol(params)
  return { request = info.eldoc_request(word, { describe = client_describe(), ns = runtime.ns() }) }
end

function M.source(params)
  local word = M.symbol(params)
  local request = info.request(word, { describe = client_describe(), ns = runtime.ns() })
  return request and { request = request, locate = info.source_location } or {}
end

function M.formatting(params)
  local content = params and params.content
  if not content then return {} end
  local code = type(content) == 'table' and table.concat(content, '\n') or tostring(content)
  return {
    format = function(client)
      local formatted, err = format.format_sync(client, code, { runtime = runtime.detect({}) })
      if not formatted then return nil, err end
      return formatted
    end,
  }
end

function M.sources()
  local ok, methods = pcall(require, 'null-ls.methods')
  if not ok then return {} end

  return {
    {
      name = 'campfire_completion',
      method = methods.internal.COMPLETION,
      filetypes = { 'clojure' },
      generator = {
        async = true,
        fn = function(params, done)
          local client = current_client()
          if not client then done({}) return end
          local request = completion.request(params.word_to_complete or '', {
            describe = client.describe,
            ns = runtime.ns(),
            context = '',
          })
          if not request then done({}) return end
          local responses = {}
          client:request(request, function(message)
            responses[#responses + 1] = message
            for _, status in ipairs(message.status or {}) do
              if status == 'done' then
                local response = client_mod.combine(responses)
                local items = vim.tbl_map(function(item)
                  return { label = item.word, detail = item.menu, documentation = item.info }
                end, completion.extract(response))
                done({ { items = items, isIncomplete = false } })
              end
            end
          end)
        end,
      },
    },
    {
      name = 'campfire_hover',
      method = methods.internal.HOVER,
      filetypes = { 'clojure' },
      generator = {
        async = true,
        fn = function(params, done)
          local client = current_client()
          local word = M.symbol(params)
          if not client or word == '' then done({}) return end
          local request = info.request(word, { describe = client.describe, ns = runtime.ns() })
          if not request then done({}) return end
          local responses = {}
          client:request(request, function(message)
            responses[#responses + 1] = message
            for _, status in ipairs(message.status or {}) do
              if status == 'done' then
                local response = client_mod.combine(responses)
                done({ info.doc_markdown(word, info.normalize(response)) })
              end
            end
          end)
        end,
      },
    },
    {
      name = 'campfire_formatting',
      method = methods.internal.FORMATTING,
      filetypes = { 'clojure' },
      generator = {
        async = true,
        fn = function(params, done)
          local client = current_client()
          if not client then done({}) return end
          local content = params.content or {}
          local code = type(content) == 'table' and table.concat(content, '\n') or tostring(content)
          local request, err = format.request(code, { describe = client.describe, runtime = runtime.detect({}) })
          if not request then
            vim.schedule(function()
              vim.api.nvim_echo({ { 'Campfire format: ' .. tostring(err), 'WarningMsg' } }, false, {})
            end)
            done({})
            return
          end
          local responses = {}
          client:request(request, function(message)
            responses[#responses + 1] = message
            for _, status in ipairs(message.status or {}) do
              if status == 'done' then
                local response = client_mod.combine(responses)
                local formatted, ferr = format.extract(response)
                if not formatted then
                  vim.schedule(function()
                    vim.api.nvim_echo({ { 'Campfire format: ' .. tostring(ferr or 'unknown error'), 'WarningMsg' } }, false, {})
                  end)
                  done({})
                  return
                end
                local row_end = #content
                local col_end = content[row_end] and #content[row_end] or 0
                done({ { row = 1, col = 1, end_row = row_end, end_col = col_end + 1, text = formatted } })
              end
            end
          end)
        end,
      },
    },
  }
end

function M.adapters()
  return {
    completion = M.completion,
    hover = M.hover,
    signature = M.signature,
    source = M.source,
    formatting = M.formatting,
  }
end

return M
