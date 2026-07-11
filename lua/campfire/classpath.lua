local resource = require('campfire.resource')

local M = {}

-- Async-fetch the connected runtime's classpath via the cider-nrepl `classpath`
-- op and cache the filtered list of source dirs on the client. No-op when the
-- op isn't advertised. Fire-and-forget: callers shouldn't await the response,
-- so anything that needs a path right now must cope with the cache being
-- absent.
function M.fetch_async(client, callback)
  local ops = client and client.describe and client.describe.ops
  if not ops or not ops['classpath'] then
    if callback then callback() end
    return
  end
  client:request({ op = 'classpath', scope = 'tool' }, function(msg)
    if msg.classpath then
      client.classpath_dirs = resource.filter_dirs(msg.classpath)
    end
    for _, status in ipairs(msg.status or {}) do
      if status == 'done' then
        if callback then callback() end
        return
      end
    end
  end)
end

return M
