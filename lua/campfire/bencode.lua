local M = {}

local incomplete = {}

local function is_array(tbl)
  local max = 0
  local count = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end
    max = math.max(max, key)
    count = count + 1
  end
  return max == count
end

local function encode_value(value, out)
  local kind = type(value)
  if kind == 'string' then
    out[#out + 1] = tostring(#value)
    out[#out + 1] = ':'
    out[#out + 1] = value
  elseif kind == 'number' then
    if value % 1 ~= 0 then
      error('cannot bencode non-integer number')
    end
    out[#out + 1] = 'i'
    out[#out + 1] = tostring(value)
    out[#out + 1] = 'e'
  elseif kind == 'boolean' then
    out[#out + 1] = value and 'i1e' or 'i0e'
  elseif kind == 'table' then
    if is_array(value) then
      out[#out + 1] = 'l'
      for i = 1, #value do
        encode_value(value[i], out)
      end
      out[#out + 1] = 'e'
    else
      out[#out + 1] = 'd'
      local keys = vim.tbl_keys(value)
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, key in ipairs(keys) do
        encode_value(tostring(key), out)
        encode_value(value[key], out)
      end
      out[#out + 1] = 'e'
    end
  else
    error('cannot bencode ' .. kind)
  end
end

function M.encode(value)
  local out = {}
  encode_value(value, out)
  return table.concat(out)
end

local function parse(data, pos)
  local tag = data:sub(pos, pos)
  if tag == '' then
    return nil, pos, incomplete
  end
  if tag == 'i' then
    local finish = data:find('e', pos + 1, true)
    if not finish then return nil, pos, incomplete end
    local raw = data:sub(pos + 1, finish - 1)
    if not (raw == '0' or raw:match('^-?[1-9]%d*$')) then error('invalid bencode integer') end
    return tonumber(raw), finish + 1
  end
  if tag == 'l' then
    local list = {}
    local next_pos = pos + 1
    while true do
      local next_tag = data:sub(next_pos, next_pos)
      if next_tag == '' then return nil, pos, incomplete end
      if next_tag == 'e' then return list, next_pos + 1 end
      local value, after, why = parse(data, next_pos)
      if why == incomplete then return nil, pos, incomplete end
      list[#list + 1] = value
      next_pos = after
    end
  end
  if tag == 'd' then
    local dict = {}
    local next_pos = pos + 1
    while true do
      local next_tag = data:sub(next_pos, next_pos)
      if next_tag == '' then return nil, pos, incomplete end
      if next_tag == 'e' then return dict, next_pos + 1 end
      local key, after_key, key_incomplete = parse(data, next_pos)
      if key_incomplete == incomplete then return nil, pos, incomplete end
      if type(key) ~= 'string' then error('invalid bencode dictionary key') end
      local value, after_value, value_incomplete = parse(data, after_key)
      if value_incomplete == incomplete then return nil, pos, incomplete end
      dict[key] = value
      next_pos = after_value
    end
  end
  if tag:match('%d') then
    local colon = data:find(':', pos, true)
    if not colon then return nil, pos, incomplete end
    local raw_len = data:sub(pos, colon - 1)
    if not (raw_len == '0' or raw_len:match('^[1-9]%d*$')) then error('invalid bencode string length') end
    local len = tonumber(raw_len)
    local start = colon + 1
    local finish = start + len - 1
    if #data < finish then return nil, pos, incomplete end
    return data:sub(start, finish), finish + 1
  end
  error('unexpected bencode tag ' .. tag)
end

function M.decode_one(data, pos)
  pos = pos or 1
  local value, next_pos, why = parse(data, pos)
  if why == incomplete then return nil, pos, 'incomplete' end
  return value, next_pos
end

function M.decode(data)
  local value, pos, why = M.decode_one(data, 1)
  if why == 'incomplete' then error('incomplete bencode data') end
  if pos <= #data then error('trailing bencode data') end
  return value
end

function M.decoder()
  local state = { buffer = '' }
  function state:feed(chunk)
    self.buffer = self.buffer .. (chunk or '')
    local messages = {}
    local pos = 1
    while pos <= #self.buffer do
      local value, next_pos, why = M.decode_one(self.buffer, pos)
      if why == 'incomplete' then break end
      messages[#messages + 1] = value
      pos = next_pos
    end
    self.buffer = self.buffer:sub(pos)
    return messages
  end
  return state
end

return M
