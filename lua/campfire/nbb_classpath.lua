local M = {}

local function parse_bencode_string_value(value)
  -- The nbb classpath fn returns a colon-separated string. Some responses
  -- wrap it in surrounding quotes / whitespace; strip those defensively.
  if type(value) ~= 'string' then return nil end
  local trimmed = vim.trim(value)
  if trimmed:sub(1, 1) == '"' and trimmed:sub(-1) == '"' then
    trimmed = trimmed:sub(2, -2)
  end
  return trimmed
end

-- Split the colon-separated classpath string from nbb.classpath/get-classpath
-- into individual dirs. Empty entries dropped, trailing slashes normalised.
local function split_classpath(raw)
  if not raw or raw == '' then return {} end
  local out = {}
  for entry in raw:gmatch('[^:]+') do
    local cleaned = entry:gsub('/+$', '')
    if cleaned ~= '' then out[#out + 1] = cleaned end
  end
  return out
end

-- Fetch nbb's runtime classpath once at connect and cache on the client. nbb's
-- classpath isn't dynamic in practice; we don't refresh. Fires on main since
-- nbb is single-session. Fire-and-forget: prep's nbb branch tolerates an
-- unpopulated cache by routing to scratch-prime.
--
-- (nbb.classpath/get-classpath) is the public function; (find-file-on-classpath)
-- isn't sci-resolvable from the REPL even though it exists in the codebase, so
-- a server-side probe isn't available — we mirror the classpath client-side and
-- do per-query fs_stat against it.
function M.fetch_async(client, callback)
  if not client or client.lang ~= 'nbb' then
    if callback then callback() end
    return
  end
  client:request({
    op = 'eval',
    code = '(nbb.classpath/get-classpath)',
    scope = 'user',
  }, function(msg)
    if msg.value then
      local raw = parse_bencode_string_value(msg.value)
      client.nbb_classpath = split_classpath(raw)
    end
    for _, status in ipairs(msg.status or {}) do
      if status == 'done' then
        if callback then callback() end
        return
      end
    end
  end)
end

-- Test seam.
M._split_classpath = split_classpath
M._parse_string = parse_bencode_string_value

return M
