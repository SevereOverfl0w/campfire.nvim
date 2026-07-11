local M = {}

-- Discover source/test dirs declared by the project's build config without
-- relying on the runtime's `classpath` op. Useful for bb (no classpath op),
-- nbb (no cider middleware), and as belt-and-braces fallback when the op
-- response is delayed or missing.
--
-- We scan a small set of well-known config files at the project root and
-- extract vectors held under :paths / :extra-paths / :source-paths /
-- :test-paths. EDN is not parsed properly; we lean on the convention that
-- these vectors carry only string literals. Vectors that don't match are
-- skipped silently.

local CONFIG_FILES = {
  'deps.edn',
  'shadow-cljs.edn',
  'project.clj',
  'nbb.edn',
  'bb.edn',
}

local PATH_KEYS = {
  'paths',
  'source%-paths',
  'test%-paths',
  'extra%-paths',
}

local function read_file(path)
  local fh = io.open(path, 'r')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
end

local function strip_comments(text)
  -- Drop `;` to end-of-line comments. Quick-and-dirty; doesn't honour quoting
  -- but the keys we care about don't contain semicolons in real configs.
  return (text:gsub(';[^\n]*', ''))
end

local function extract_strings(vector_body)
  local out = {}
  for s in vector_body:gmatch('"([^"]+)"') do
    out[#out + 1] = s
  end
  return out
end

local function extract_vectors(text, key)
  local out = {}
  local pattern = ':' .. key .. '%s*%[(.-)%]'
  for body in text:gmatch(pattern) do
    for _, s in ipairs(extract_strings(body)) do
      out[#out + 1] = s
    end
  end
  return out
end

local function resolve(root, rel)
  if not rel or rel == '' then return nil end
  if rel:sub(1, 1) == '/' then return rel end
  return root:gsub('/+$', '') .. '/' .. rel
end

local function dir_exists(path)
  local ok, st = pcall(vim.uv.fs_stat, path)
  return ok and st and st.type == 'directory'
end

function M.from_text(text)
  text = strip_comments(text or '')
  local raw = {}
  for _, key in ipairs(PATH_KEYS) do
    for _, p in ipairs(extract_vectors(text, key)) do
      raw[#raw + 1] = p
    end
  end
  return raw
end

function M.discover(root)
  if not root or root == '' then return {} end
  local seen = {}
  local dirs = {}
  local function add(path)
    if path and not seen[path] and dir_exists(path) then
      seen[path] = true
      dirs[#dirs + 1] = path
    end
  end

  for _, name in ipairs(CONFIG_FILES) do
    local content = read_file(root:gsub('/+$', '') .. '/' .. name)
    if content then
      for _, rel in ipairs(M.from_text(content)) do
        add(resolve(root, rel))
      end
    end
  end

  -- Convention fallbacks: even when the config didn't declare them, a project
  -- root with these dirs almost certainly uses them as source.
  for _, default in ipairs({ 'src', 'test', 'src/main', 'src/test', 'src/main/clojure', 'src/test/clojure' }) do
    add(resolve(root, default))
  end

  return dirs
end

function M.populate(client)
  if not client or not client.root then return end
  client.source_dirs = M.discover(client.root)
end

return M
