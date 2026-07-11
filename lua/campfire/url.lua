local M = {}

local function decode_path(path)
  path = path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  return path:gsub('^//+', '/')
end

function M.parse(input)
  if type(input) == 'number' or tostring(input):match('^%d+$') then
    return { type = 'tcp', scheme = 'nrepl', host = 'localhost', port = tonumber(input), url = 'nrepl://localhost:' .. tostring(input) }
  end
  local text = tostring(input)
  if not text:match('^%a[%w+.-]*://') and text:match('^[^:/]+:%d+$') then
    local host, port = text:match('^([^:/]+):(%d+)$')
    return { type = 'tcp', scheme = 'nrepl', host = host, port = tonumber(port), url = 'nrepl://' .. text }
  end
  local scheme, rest = text:match('^(%a[%w+.-]*)://(.*)$')
  if not scheme then error('invalid nREPL URL: ' .. text) end
  if scheme == 'nrepl+unix' or scheme == 'nrepl+pipe' then
    local path = rest
    if path:sub(1, 1) ~= '/' then path = '/' .. path end
    return { type = 'pipe', scheme = scheme, path = decode_path(path), url = text }
  end
  -- drawbridge HTTP transport: hand the full URL (userinfo/host/port/path) to
  -- curl untouched; the http transport doesn't decompose it.
  if scheme == 'http' or scheme == 'https' then
    return { type = 'http', scheme = scheme, url = text }
  end
  if scheme ~= 'nrepl' then error('unsupported nREPL URL scheme: ' .. scheme) end
  local authority = rest:match('^[^/]*')
  local host, port = authority:match('^([^:]*):?(%d*)$')
  host = host ~= '' and host or 'localhost'
  port = port ~= '' and tonumber(port) or 7888
  return { type = 'tcp', scheme = scheme, host = host, port = port, url = text }
end

return M
