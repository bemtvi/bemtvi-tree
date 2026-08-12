-- bemtvi-tree.keymap — install the configured key bindings on the tree buffer.
--
-- `cfg.mappings` is a `key -> action` table (defaults in config.lua). Each value is
-- one of:
--   a string   the name of a built-in action (see actions.lua / config.ACTIONS)
--   a function a custom action, called as `fn(tree, api)` like a built-in
--   false      disable this key (drop a default without redeclaring the table)
--
-- Every binding is buffer-local on the view buffer (so it only fires while the tree
-- is focused) and runs inside `api.run` — the async, error-surfacing wrapper — so an
-- action may freely `btv.await` fs / ui promises and any rejection becomes a notify
-- rather than an unhandled error.

local actions = require("bemtvi-tree.actions")
local config = require("bemtvi-tree.config")

local M = {}

-- install(tree, api) — bind `tree.config.mappings` on the view buffer. Returns false
-- (warned) if the buffer doesn't exist yet (the caller defers until it does).
function M.install(tree, api)
  local buf = tree.view:bufnr()
  if not buf then
    btv.notify("bemtvi-tree: cannot install maps before the view buffer exists", 4)
    return false
  end

  for key, action in pairs(tree.config.mappings) do
    if action ~= false then
      local fn, label
      if type(action) == "function" then
        -- A user's custom action: no built-in description, so name it generically.
        fn, label = action, "Custom action"
      else
        fn = actions[action]
        -- The human description is config.ACTIONS[action]; fall back to the raw
        -- action name if a new action ever lands without one.
        label = config.ACTIONS[action]
        if type(label) ~= "string" then
          label = action
        end
        if not fn then
          btv.notify("bemtvi-tree: no built-in action '" .. tostring(action) .. "'", 4)
        end
      end
      if fn then
        btv.keymap.set("n", key, function()
          api.run(function()
            fn(tree, api)
          end)
        end, { buffer = buf, desc = "bemtvi-tree: " .. label })
      end
    end
  end

  return true
end

return M
