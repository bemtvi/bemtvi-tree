-- nxvim-tree.config — the default configuration and the merge used by setup().
--
-- The config is one flat table (plus three nested sub-tables: `mappings`,
-- `highlights`, `icons`). `defaults()` returns a fresh copy every call so the
-- module-level template is never mutated; `merge(into, opts)` deep-merges a user
-- table over it, validating the few values that have a closed domain so a typo
-- fails loud (per the project's no-silent-stubs rule) instead of mis-rendering.
--
-- Everything here is pure data + validation — no editor calls — so it is trivially
-- unit-testable and the same table drives both the live plugin and the test suite.

local M = {}

-- The mappable action names, each mapped to a human-readable description. A
-- `mappings` entry's value must be one of these keys (a built-in action), a function
-- (a custom action `fn(api)`), or `false` (disable the key). Kept here so `merge` can
-- reject an unknown action-name string up front (any non-empty string is truthy, so
-- the lookup still works as a membership test).
--
-- The descriptions are the single source of truth for "what does this key do": the
-- keymap installer (keymap.lua) passes each into the map's `desc` as
-- `"nxvim-tree: <description>"`, which is what nxvim's built-in keymaps picker
-- (`<leader>fk`) and the which-key popup surface. Keep them a short verb phrase so
-- those help surfaces read cleanly.
M.ACTIONS = {
  select = "Open a file / toggle a directory",
  mouse_click = "Single left-click: toggle the directory under the pointer",
  mouse_open = "Double left-click: open the file under the pointer",
  mouse_menu = "Right-click: a context menu for the node under the pointer",
  open_split = "Open the file in a horizontal split",
  open_vsplit = "Open the file in a vertical split",
  open_tab = "Open the file in a new tab",
  expand = "Expand the directory under the cursor",
  collapse = "Collapse the directory (or jump to the parent)",
  expand_all = "Recursively expand every directory",
  collapse_all = "Collapse everything back to the root",
  parent = "Move the cursor to the parent directory's node",
  create = 'Create a file (trailing "/" → directory)',
  rename = "Rename the entry under the cursor",
  delete = "Delete the entry (confirms)",
  cut = "Mark the entry to be moved on the next paste",
  copy = "Mark the entry to be copied on the next paste",
  paste = "Move/copy the marked entry under the cursor's directory",
  clear_clipboard = "Forget a pending cut/copy",
  yank_path = 'Yank the absolute path to the " and + registers',
  refresh = "Re-scan the whole tree",
  toggle_hidden = "Show/hide dotfiles",
  change_root = "Make the directory under the cursor the new root",
  up_root = "Make the parent of the current root the new root",
  reveal = "Reveal the file open in the main window",
  filter = "Prompt for a name filter",
  clear_filter = "Drop an active filter",
  close = "Hide the tree and return to the editor",
}

-- The built-in default key bindings (normal mode, buffer-local on the tree). A user
-- can override any of these via `opts.mappings`, add new keys, or disable a default
-- by mapping it to `false`.
local DEFAULT_MAPPINGS = {
  ["<CR>"] = "select",
  o = "select",
  ["<LeftMouse>"] = "mouse_click", -- single click: toggle the directory under the pointer
  ["<2-LeftMouse>"] = "mouse_open", -- double click: open the file under the pointer
  ["<RightMouse>"] = "mouse_menu", -- right click: context menu for the node under the pointer
  l = "expand",
  h = "collapse",
  s = "open_split",
  v = "open_vsplit",
  t = "open_tab",
  E = "expand_all",
  W = "collapse_all",
  P = "parent",
  a = "create",
  r = "rename",
  d = "delete",
  x = "cut",
  c = "copy",
  p = "paste",
  ["<Esc>"] = "clear_filter",
  y = "yank_path",
  R = "refresh",
  H = "toggle_hidden",
  ["<"] = "up_root",
  [">"] = "change_root",
  f = "reveal",
  ["/"] = "filter",
  q = "close",
}

-- The default configuration. `defaults()` hands out a deep copy.
local DEFAULTS = {
  root = nil, -- tree root path (default: the editor's cwd at first open)
  position = "left", -- which dock side: "left" | "right"
  width = 32, -- sidebar columns
  hidden = false, -- show dotfiles?
  watch = true, -- auto-refresh on filesystem changes
  follow = false, -- auto-reveal the file in the active window as you switch buffers
  git = false, -- enable the built-in git-status decorator
  dirs_first = true, -- sort directories ahead of files (else pure alpha)
  icons = true, -- render Nerd-Font glyphs (false → ASCII +/- markers)
  toggle_key = "<leader>e", -- the global toggle keymap (false to skip)
  open_on_start = false, -- open the tree as soon as setup() runs
  persist = true, -- restore the sidebar (root + expanded dirs + cursor) across a session
  mappings = DEFAULT_MAPPINGS,
  highlights = {}, -- highlight-group overrides, keyed by group name
  icon_overrides = {}, -- extra icons, merged into the icon registry (see icons.lua)
  on_attach = nil, -- fn(api, bufnr): run once the tree buffer exists (custom maps)
}

local POSITIONS = { left = true, right = true }

-- Deep-copy a plain data table (the config is data, never functions-in-arrays).
local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = copy(val)
  end
  return out
end
M.copy = copy

-- defaults() — a fresh, independent copy of the default config.
function M.defaults()
  return copy(DEFAULTS)
end

-- validate(cfg) — fail loud on an out-of-domain value. Called by merge after the
-- merge so it sees the effective config. Raises (level 3 → the setup() caller).
local function validate(cfg)
  if not POSITIONS[cfg.position] then
    error("nxvim-tree: position must be 'left' or 'right', got " .. tostring(cfg.position), 3)
  end
  if type(cfg.width) ~= "number" or cfg.width < 1 then
    error("nxvim-tree: width must be a positive number", 3)
  end
  for key, action in pairs(cfg.mappings) do
    if action ~= false and type(action) ~= "function" and not M.ACTIONS[action] then
      error(
        ("nxvim-tree: mapping %q → unknown action %q (see config.ACTIONS)"):format(
          tostring(key),
          tostring(action)
        ),
        3
      )
    end
  end
end

-- merge(into, opts) — deep-merge `opts` over the config table `into` (mutating and
-- returning it), then validate. `mappings` merges key-by-key (so a user adds/overrides
-- individual keys without redeclaring the whole table); the other sub-tables likewise
-- merge shallowly. Unknown top-level keys are kept (forward-compat for add-ons that
-- stash their own config under a namespaced key).
function M.merge(into, opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("nxvim-tree.setup: opts must be a table", 3)
  end
  for k, v in pairs(opts) do
    if (k == "mappings" or k == "highlights" or k == "icon_overrides") and type(v) == "table" then
      into[k] = into[k] or {}
      for kk, vv in pairs(v) do
        into[k][kk] = vv
      end
    else
      into[k] = v
    end
  end
  validate(into)
  return into
end

return M
