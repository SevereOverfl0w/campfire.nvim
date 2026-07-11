local M = {}

-- Each branch yields a *string* (not a keyword) so the probe is portable to
-- squint, whose keywords compile to bare JS strings (`:cljs` -> "cljs", no
-- leading colon) — parse_value reads the quoted string, the one rendering
-- every dialect shares.
--
-- Order disambiguates dialects that carry several feature keys, most specific
-- first: :lg before :clj so let-go reports itself; :org.babashka/nbb (the
-- namespaced key nbb uses, see src/nbb/core.cljs in babashka/nbb — not :nbb)
-- before :cljs so nbb isn't seen as plain cljs; :squint before :cljs so squint
-- (which also carries :cljs) reports itself. Other dialects lack these keys.
M.form = '#?(:bb "bb" :org.babashka/nbb "nbb" :squint "squint" :cljs "cljs" :cljr "cljr" :lg "lg" :clj "clj" :default "unknown")'

local function status_has(message, status)
  for _, item in ipairs(message.status or {}) do
    if item == status then return true end
  end
  return false
end

local function parse_value(raw)
  if type(raw) ~= 'string' then return nil end
  local sym = raw:match('"([%w_-]+)"')
  if not sym or sym == 'unknown' then return nil end
  return sym
end

function M.run(client, session_id, callback)
  if type(session_id) == 'function' then
    callback = session_id
    session_id = client.named and client.named.tooling and client.named.tooling.id
  end
  if not session_id then
    callback('no session for probe')
    return
  end
  local lang
  client:request({
    op = 'eval',
    code = M.form,
    session = session_id,
  }, function(msg)
    if msg.value then lang = parse_value(msg.value) or lang end
    if status_has(msg, 'done') then callback(nil, lang) end
  end)
end

return M
