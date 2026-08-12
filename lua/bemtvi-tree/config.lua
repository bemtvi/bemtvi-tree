-- bemtvi-tree.config — the default configuration and the merge used by setup().
--
-- The config is one flat table (plus three nested sub-tables: `mappings`,
-- `highlights`, `icons`). `defaults()` returns a fresh copy every call so the
-- module-level template is never mutated; `merge(into, opts)` deep-merges a user
-- table over it, validating the few values that have a closed domain so a typo
-- fails loud (per the project's no-silent-stubs rule) instead of mis-rendering.
--
-- Everything here is pure data + validation — no editor state is read or written, so it
-- is trivially unit-testable and the same table drives both the live plugin and the test
-- suite. (`validate` does call `btv.glob`, but that is a pure pattern engine — compiling a
-- glob observes nothing and changes nothing.)

local M = {}

-- The mappable action names, each mapped to a human-readable description. A
-- `mappings` entry's value must be one of these keys (a built-in action), a function
-- (a custom action `fn(tree, api)`, called like a built-in — see keymap.lua), or
-- `false` (disable the key). Kept here so `merge` can
-- reject an unknown action-name string up front (any non-empty string is truthy, so
-- the lookup still works as a membership test).
--
-- The descriptions are the single source of truth for "what does this key do": the
-- keymap installer (keymap.lua) passes each into the map's `desc` as
-- `"bemtvi-tree: <description>"`, which is what bemtvi's built-in keymaps picker
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
  toggle_git_ignored = "Dim/hide git-ignored entries",
  toggle_filters = "Apply/suspend the configured glob filters",
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
  I = "toggle_git_ignored", -- nvim-tree's key for the same toggle
  U = "toggle_filters", -- nvim-tree's key for the same toggle (`filters.custom`)
  ["<"] = "up_root",
  [">"] = "change_root",
  f = "reveal",
  -- The name filter is `<leader>/`, NOT a bare `/`: the tree is an ordinary buffer, so
  -- `/` must stay the editor's own search. (A user who prefers the bare key can still
  -- map `["/"] = "filter"`.)
  ["<leader>/"] = "filter",
  q = "close",
}

-- The default configuration. `defaults()` hands out a deep copy.
local DEFAULTS = {
  root = nil, -- tree root path (default: the editor's cwd at first open)
  position = "left", -- which dock side: "left" | "right"
  width = 32, -- sidebar columns
  -- Show dotfiles? ON by default — `.gitignore`, `.env`, `.github/` … are files you
  -- edit, and an explorer that silently omits them reads as an incomplete tree. (The
  -- repository's own `.git` is dimmed as ignored instead — see git.lua.) `H` toggles
  -- live, and that choice persists and beats this default on later launches.
  hidden = true,
  watch = true, -- auto-refresh on filesystem changes
  follow = false, -- auto-reveal the file in the active window as you switch buffers
  -- The built-in git-status decorator, ON by default: inside a repository the tree
  -- colours each entry by its status, and outside one it costs a single `discover`
  -- that rejects and stays quiet. Opt out with `git = false`.
  git = true,
  -- What to do with git-ignored entries (needs the decorator above): "dim" renders them
  -- in NvimTreeGitIgnored, "hide" drops them from the tree. The `I` key toggles between
  -- the two live, and the choice persists across sessions like `hidden`.
  git_ignored = "dim", -- "dim" | "hide"
  -- Glob patterns whose matching entries are dropped from the tree, e.g.
  -- `{ "*.o", "node_modules", "/vendor" }`. Empty by default: git already hides the
  -- build output worth hiding (`git_ignored`), and this is for the rest — a vendored
  -- directory that IS tracked, generated files a repo commits.
  --
  -- Matching is `btv.glob` (shell / gitignore syntax, compiled to one cached regex set),
  -- against each entry's path relative to the TREE ROOT, and it follows gitignore's
  -- anchoring rule:
  --
  --   "*.o"          a bare name / pattern matches an entry's BASENAME at any depth
  --   "node_modules"  — so this hits every `node_modules`, however deep
  --   "/vendor"      a LEADING "/" anchors to the tree root: only the root's `vendor`
  --   "/src/*.rs"     — anchored patterns match the whole root-relative path
  --   "docs/*.md"    any other "/" anchors too (it is already a path, not a name)
  --
  -- Matching a directory drops its subtree with it, so `"/vendor"` needs no `/**` tail.
  -- `U` suspends and re-applies the whole set live, and that choice persists across
  -- sessions like `hidden`.
  filters = {},
  -- Are the `filters` above in force? Runtime state, not really config: `U` flips it and
  -- the choice persists, exactly like `hidden`. Set it `false` in setup() to declare a
  -- filter set that starts suspended.
  filters_enabled = true,
  dirs_first = true, -- sort directories ahead of files (else pure alpha)
  icons = true, -- render Nerd-Font glyphs (false → ASCII +/- markers)
  toggle_key = "<leader>e", -- the global toggle keymap (false to skip)
  open_on_start = false, -- open the tree as soon as setup() runs
  persist = true, -- restore the sidebar (root + expanded dirs + cursor + `hidden`) across a session
  mappings = DEFAULT_MAPPINGS,
  highlights = {}, -- highlight-group overrides, keyed by group name
  icon_overrides = {}, -- extra icons, merged into the icon registry (see icons.lua)
  on_attach = nil, -- fn(api, bufnr): run once the tree buffer exists (custom maps)
}

local POSITIONS = { left = true, right = true }
-- The closed domain of `git_ignored`, exported because init.lua validates the value it
-- reads back from the session snapshot against the same set (one source of truth, so a
-- stale/unknown persisted mode is ignored rather than smuggled past `validate`).
M.GIT_IGNORED_MODES = { dim = true, hide = true }
local GIT_IGNORED_MODES = M.GIT_IGNORED_MODES

-- compile_filters(list) -> { anchored = <globset|nil>, plain = <globset|nil> }: the
-- matcher for a `filters` list. One place, so validate's fail-loud compile at setup()
-- and render's matching set can never disagree about what a pattern means. Raises on an
-- invalid pattern (btv.glob's own error, naming it).
--
-- Two sets, because gitignore's anchoring rule is per-pattern while `btv.glob`'s
-- `basename` option is per-set. A LEADING "/" (stripped here) or any other separator
-- means the pattern is a PATH, matched whole against the root-relative path; a bare name
-- is matched against the basename at any depth. Both sets are one compiled regex set, so
-- a node costs at most two passes however many patterns there are — and `btv.glob` caches
-- by pattern + options, so re-compiling an unchanged list is free.
function M.compile_filters(list)
  local anchored, plain = {}, {}
  for _, pat in ipairs(list) do
    if pat:sub(1, 1) == "/" then
      anchored[#anchored + 1] = pat:sub(2)
    elseif pat:find("/", 1, true) then
      anchored[#anchored + 1] = pat
    else
      plain[#plain + 1] = pat
    end
  end
  return {
    anchored = #anchored > 0 and btv.glob.set(anchored, { basename = false }) or nil,
    plain = #plain > 0 and btv.glob.set(plain, { basename = true }) or nil,
  }
end

-- matches_filter(sets, rel) — does the root-relative path `rel` match either set?
function M.matches_filter(sets, rel)
  return (sets.anchored ~= nil and sets.anchored:test(rel))
    or (sets.plain ~= nil and sets.plain:test(rel))
end

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
    error("bemtvi-tree: position must be 'left' or 'right', got " .. tostring(cfg.position), 3)
  end
  if type(cfg.width) ~= "number" or cfg.width < 1 then
    error("bemtvi-tree: width must be a positive number", 3)
  end
  if not GIT_IGNORED_MODES[cfg.git_ignored] then
    error("bemtvi-tree: git_ignored must be 'dim' or 'hide', got " .. tostring(cfg.git_ignored), 3)
  end
  -- `filters` is compiled here, not at first render: `btv.glob` raises on an invalid
  -- pattern, and a bad glob is a setup() mistake that should be reported from setup()
  -- rather than the next repaint. The compile is not wasted — btv.glob caches by
  -- pattern + options, so render's own set is a cache hit.
  if type(cfg.filters) ~= "table" then
    error("bemtvi-tree: filters must be a list of glob patterns", 3)
  end
  for i, pat in ipairs(cfg.filters) do
    if type(pat) ~= "string" or pat == "" or pat == "/" then
      error(("bemtvi-tree: filters[%d] must be a non-empty glob pattern"):format(i), 3)
    end
  end
  if #cfg.filters > 0 then
    local ok, err = pcall(M.compile_filters, cfg.filters)
    if not ok then
      error("bemtvi-tree: filters — " .. tostring(type(err) == "table" and err.message or err), 3)
    end
  end
  for key, action in pairs(cfg.mappings) do
    if action ~= false and type(action) ~= "function" and not M.ACTIONS[action] then
      error(
        ("bemtvi-tree: mapping %q → unknown action %q (see config.ACTIONS)"):format(
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
    error("bemtvi-tree.setup: opts must be a table", 3)
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
