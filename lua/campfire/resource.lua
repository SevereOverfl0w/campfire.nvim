local M = {}

-- Resolve a classpath-relative source path (as reported by clojure.test / cider
-- info ops, e.g. "demo/core_test.clj") to an absolute on-disk path the user's
-- editor can open. Returns the original input when no resolution is possible.
--
-- Strategy mirrors vim-fireplace#findresource: walk the cached classpath dirs
-- in order, return the first `<dir>/<rel>` that exists. Jar entries are skipped
-- for now — neovim has no native zipfile handler in our paths.

local function is_absolute(path)
  return type(path) == 'string' and path:sub(1, 1) == '/'
end

local function stat_file(path)
  local ok, st = pcall(vim.uv.fs_stat, path)
  return ok and st and st.type == 'file'
end

local function search(dirs, rel)
  if not dirs then return nil end
  for _, dir in ipairs(dirs) do
    if dir ~= '' and dir:sub(-4) ~= '.jar' then
      local candidate = dir:gsub('/+$', '') .. '/' .. rel
      if stat_file(candidate) then return candidate end
    end
  end
end

function M.find(client, rel)
  if not rel or rel == '' or rel == 'NO_SOURCE_FILE' then return rel end
  if is_absolute(rel) and stat_file(rel) then return rel end

  if client then
    -- Memoize per connection: a noisy error/frame dump resolves the same
    -- handful of files thousands of times, each otherwise re-stat'ing every
    -- classpath dir. Misses cache too (→ rel) to skip the repeat walk. The
    -- cache lives on the client, so a reconnect (new client) starts fresh.
    local cache = client._resource_cache
    if not cache then cache = {}; client._resource_cache = cache end
    local cached = cache[rel]
    if cached ~= nil then return cached end
    local hit = search(client.classpath_dirs, rel) or search(client.source_dirs, rel) or rel
    cache[rel] = hit
    return hit
  end

  return rel
end

-- Convert an nREPL/cider source URL to something the editor can open:
--   jar:file:/x.jar!/inner.clj → zipfile://x.jar::inner.clj (the resource hint
--                                when given, else the parsed jar entry)
--   file:/abs/path             → /abs/path
-- Returns nil when there's no recognised file scheme (e.g. Java frames with no
-- source), so callers can fall back or render the line plain.
function M.url_to_path(url, resource_hint)
  if type(url) ~= 'string' or url == '' then return nil end
  local jar, entry = url:match('^jar:file:([^!]+)!/?(.*)$')
  if jar then
    return 'zipfile://' .. jar .. '::' .. (resource_hint or entry or '')
  end
  return url:match('^file://(/.*)$') or url:match('^file:(/.*)$')
end

-- Filter raw classpath entries (as returned by the cider-nrepl `classpath` op)
-- to those usable for source-file resolution: existing directories. Order is
-- preserved so project src/test dirs are tried before deps.
function M.filter_dirs(entries)
  local out = {}
  if type(entries) ~= 'table' then return out end
  for _, entry in ipairs(entries) do
    if type(entry) == 'string' and entry ~= '' and entry:sub(-4) ~= '.jar' then
      local ok, st = pcall(vim.uv.fs_stat, entry)
      if ok and st and st.type == 'directory' then
        out[#out + 1] = entry
      end
    end
  end
  return out
end

return M
