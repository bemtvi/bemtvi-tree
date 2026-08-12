-- bemtvi-tree.highlights — the highlight palette and a fallback-only applier.
--
-- The structural / git / state groups use the canonical **NvimTree\*** names from
-- nvim-tree.lua, on purpose: a ported colorscheme that styles those names (e.g.
-- catppuccin's nvim-tree integration) themes the explorer UNMODIFIED. We only define
-- them as a FALLBACK — an explicit user override wins, and otherwise the default goes
-- in through `btv.hl.fallback`, which yields to a colorscheme that already styles the
-- group regardless of load order.
--
-- The per-extension *icon* colors have no NvimTree equivalent (upstream nvim-tree
-- colors icons through nvim-web-devicons, not its own groups), so those stay under
-- the plugin's own `BtvTreeIcon*` namespace — a colorscheme never needs to know them,
-- and a power user can still override them.
--
-- Fallback colors are DERIVED from the active theme via `btv.hl.palette()` rather than
-- hardcoded, so the sidebar reads as part of whatever colorscheme is loaded: the
-- editor's own `bemtvi` One Dark by default, catppuccin under catppuccin, and a light
-- flavour without a dark-theme hex bleeding through the many groups no theme's
-- nvim-tree integration models (the icons, the staged/ignored git states, the
-- cut/copy marks). That is also why `defaults()` is a function rather than a table:
-- it is re-evaluated on every apply, and `bemtvi-tree` re-applies on `ColorScheme`.
--
-- They are foreground-only (no `bg`) so applying a group to a name range never paints
-- a background strip behind the text.

local M = {}

-- defaults() -> `name -> spec` (the `btv.hl.define` opts table) for the active theme.
function M.defaults()
  local p = btv.hl.palette()
  return {
    -- Window chrome (the sidebar's own background, cursorline, and `~` fillers) —
    -- the canonical NvimTree* names, applied through the tree window's `winhighlight`
    -- remap (`Normal:NvimTreeNormal`, …), not to a name range. The fallbacks LINK to
    -- the editor's own chrome groups so they follow the active theme's light/dark
    -- flavour; a colorscheme that defines these (e.g. catppuccin sets NvimTreeNormal
    -- per-flavour) still wins (see M.apply). Normal→NormalFloat gives the sidebar a
    -- distinct shade like nvim-tree; cursorline / fillers then match the editor exactly.
    NvimTreeNormal = { link = "NormalFloat" }, -- the sidebar background
    NvimTreeEndOfBuffer = { link = "EndOfBuffer" }, -- `~` fillers, themed like the editor
    NvimTreeCursorLine = { link = "CursorLine" }, -- the highlighted current row
    NvimTreeCursorLineNr = { link = "CursorLineNr" },
    -- structure (canonical NvimTree* — themed by a ported colorscheme)
    NvimTreeRootFolder = { fg = p.purple, bold = true }, -- the root header line
    NvimTreeFolderName = { fg = p.blue }, -- a closed directory's name
    NvimTreeOpenedFolderName = { fg = p.blue, bold = true }, -- an expanded directory
    NvimTreeEmptyFolderName = { fg = p.blue }, -- a directory with no children
    NvimTreeFolderIcon = { fg = p.blue }, -- the open/closed folder glyph
    NvimTreeIndentMarker = { fg = p.muted }, -- the tree guide lines
    NvimTreeSymlink = { fg = p.cyan }, -- a symlink's name
    NvimTreeOpenedFile = { fg = p.cyan }, -- a file open in a buffer
    NvimTreeSpecialFile = { fg = p.yellow }, -- README / Makefile / Cargo.toml …
    NvimTreeImageFile = { fg = p.fg }, -- an image file
    NvimTreeCutHL = { fg = p.red, italic = true }, -- a node marked to be moved
    NvimTreeCopiedHL = { fg = p.orange, italic = true }, -- a node marked to be copied
    NvimTreeLiveFilterValue = { fg = p.fg, italic = true }, -- the active "/filter" tag
    -- git (canonical NvimTree* — used by the optional git module)
    NvimTreeGitNew = { fg = p.green }, -- untracked / added
    NvimTreeGitDirty = { fg = p.yellow }, -- modified (and the dirty-dir dot)
    NvimTreeGitStaged = { fg = p.cyan }, -- staged-only
    NvimTreeGitDeleted = { fg = p.red }, -- deleted
    -- git-ignored: dimmed + italic, and the one status with no gutter sign (see git.lua).
    -- Deliberately the same muted grey as the tree guides — an ignored `target/` should
    -- recede rather than compete with the real entries.
    NvimTreeGitIgnored = { fg = p.muted, italic = true },
    -- per-extension icon colors (plugin-private; nvim-tree colors icons via devicons)
    BtvTreeIconDefault = { fg = p.muted },
    BtvTreeIconRust = { fg = p.orange },
    BtvTreeIconLua = { fg = p.blue },
    BtvTreeIconJs = { fg = p.yellow },
    BtvTreeIconTs = { fg = p.blue },
    BtvTreeIconJson = { fg = p.yellow },
    BtvTreeIconToml = { fg = p.orange },
    BtvTreeIconMd = { fg = p.fg },
    BtvTreeIconPy = { fg = p.yellow },
    BtvTreeIconGo = { fg = p.cyan },
    BtvTreeIconC = { fg = p.blue },
    BtvTreeIconShell = { fg = p.green },
    BtvTreeIconHtml = { fg = p.orange },
    BtvTreeIconCss = { fg = p.blue },
    BtvTreeIconImage = { fg = p.purple },
    BtvTreeIconText = { fg = p.fg },
    BtvTreeIconGit = { fg = p.red },
    BtvTreeIconLock = { fg = p.muted },
  }
end

-- apply(overrides) — define each group as a fallback (see the module header). An
-- entry in `overrides` is applied unconditionally; an unrecognized override name is
-- still honored (a plugin may color its own extra group). Idempotent, and safe to
-- re-run on `ColorScheme` — `btv.hl.fallback` re-derives a group nothing else owns
-- while leaving a theme's (or the user's) own definition alone.
function M.apply(overrides)
  overrides = overrides or {}
  local defaults = M.defaults()
  for name, spec in pairs(defaults) do
    if overrides[name] then
      btv.hl.define(0, name, overrides[name])
    else
      btv.hl.fallback(name, spec)
    end
  end
  for name, spec in pairs(overrides) do
    if not defaults[name] then
      btv.hl.define(0, name, spec)
    end
  end
end

return M
