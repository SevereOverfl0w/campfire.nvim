-- Self-register Campfire's nvim-cmp source so users only need
-- `{ name = 'campfire' }` in their sources (mirrors cmp-buffer's after/plugin).
-- No-op when nvim-cmp isn't installed; register() is idempotent, so lazy-loaders
-- that call it again after cmp loads won't double-register.
pcall(function()
  require('campfire.cmp').register()
end)
