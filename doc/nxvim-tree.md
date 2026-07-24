<!-- DO NOT EDIT doc/nxvim-tree.txt BY HAND. It is generated from this file by
panvimdoc — run `scripts/gen-vimdoc.sh` after editing. -->

A fast, dockable, fully-featured file explorer for nxvim — the official tree.

It is built entirely on the native `nx.*` plugin API (ADR 0002): no buffer-mutation hacks, no
bespoke rendering loop. The tree's lines are owned by a read-only `nx.view` surface, the filesystem
work goes through the promise `nx.fs` API (with a per-directory watch for live refresh), files open
in the main editor via `nx.open`, and every glyph, guide, and git sign is an extmark. That is the
point: a real explorer, written the way a plugin author would write it.

```
 ~/code/sample
 󰜺 src/
 ├ 󰏗 lib.rs
 └ 󰏗 main.rs
 󰈙 Cargo.toml
 󰍔 notes.md
 󰈙 readme.txt
```

<!-- Passed through verbatim so `:help nxvim-tree` lands on this page
     (panvimdoc derives per-section tags but no bare project tag). -->
```vimdoc
                                                                   *nxvim-tree*
```

# Features

- Lazy, watched tree — directories scandir on first expand; each
  expanded directory gets its own `nx.fs` watch that auto-refreshes it
  on disk changes. Only what is visible is watched, so a huge collapsed
  subtree costs nothing (toggle with `watch`).
- Open anywhere — `<CR>` / `o` opens in the main window; `s` / `v` / `t`
  in a split, vsplit, or tab.
- Mouse — single-click a directory to expand/collapse it, double-click a
  file to open it, right-click any entry for a context menu, and the
  wheel scrolls the sidebar. All configurable like any other key.
- Full file ops — create (`a`), rename (`r`), delete (`d`, confirmed),
  cut (`x`), copy (`c`), paste (`p`), yank path (`y`).
- Navigation — expand/collapse (`l` / `h`), expand-all / collapse-all
  (`E` / `W`), jump to parent (`P`), change root in/out (`>` / `<`),
  reveal the current file (`f`).
- Name filter — `/` narrows to matches and their ancestors; `<Esc>`
  clears.
- Icons — Nerd-Font glyphs per extension and filename, with an ASCII
  fallback (`icons = false`) for plain terminals.
- Git status (opt-in) — `git = true` colours changed entries and marks
  dirty directories, refreshed on save.
- Follow (opt-in) — `follow = true` keeps the tree cursor on the file
  you are editing.
- Extensible — custom icons, per-node decorators, rebindable and added
  keys, and an `on_attach` hook.

# Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
nx.plugins({
  {
    "davidrios/nxvim-tree",
    config = function()
      require("nxvim-tree").setup({})
    end,
  },
})
```

Then run `:PluginSync` to clone it, and press `<leader>e` (or run `:Tree`).

# Configuration

`setup()` takes an optional table; the defaults are:

```lua
require("nxvim-tree").setup({
  root = nil,        -- tree root (default: the cwd at first open)
  position = "left", -- dock side: "left" | "right"
  width = 32,        -- sidebar columns
  hidden = false,    -- show dotfiles?
  watch = true,      -- auto-refresh on filesystem changes
  follow = false,    -- reveal the active file as you switch buffers
  git = false,       -- colour entries by git status
  dirs_first = true, -- sort directories ahead of files
  icons = true,      -- Nerd-Font glyphs (false → ASCII markers)
  toggle_key = "<leader>e", -- global toggle keymap (false to skip)
  open_on_start = false,    -- open the tree as soon as setup() runs
  persist = true,    -- restore the sidebar across a session
  mappings = { … },  -- key → action (see Key bindings)
  highlights = {},   -- highlight-group overrides
  icon_overrides = {},      -- extra icons, merged into the registry
  on_attach = nil,   -- fn(api, bufnr): run once the tree buffer exists
})
```

`setup()` is re-runnable — calling it again is a full reconfigure (merged fresh from the defaults),
re-applying config, highlights, and commands without mounting a second tree.

Out-of-domain values fail LOUD rather than mis-rendering: a `position` that is not `"left"` or
`"right"`, a non-positive `width`, or a mapping naming an action that does not exist all raise from
`setup()`.

# Persistence

With `persist = true` (the default) the sidebar rides a workspace session: on restart nxvim-tree
reopens it in its dock, at the same root, with the same directories expanded and the cursor back on
the same node. The editor round-trips only a stable id and the view's dock slot; the plugin keeps
the actual snapshot (root, expanded dirs, cursor) in its own isolated `nx.shada` slice and rebuilds
the content in an `nx.view.on_restore` handler. A stale snapshot whose directory has since vanished
degrades gracefully — the missing dir is skipped, never a failed restore.

It takes effect when the session itself is captured, which is a launch-time choice:

```lua
nx.shada.save_layout(true) -- opt the layout into the session capture
```

```sh
nxvim --workspace .        # run session-scoped (captures + restores)
```

Without those the persist id simply rides along and nothing is restored, exactly like any other
window. Set `persist = false` to opt out entirely.

# Commands

```
:Tree          toggle the sidebar
:TreeOpen      open + focus the sidebar
:TreeClose     hide the sidebar
:TreeRefresh   re-scan the whole tree
:TreeReveal    reveal the file in the current window
```

# Key bindings

All bindings are buffer-local on the tree and fully configurable through `opts.mappings` — a
`key → action` table. A value is a built-in action name, a function `fn(tree, api)` for a custom
action, or `false` to disable a default:

```lua
require("nxvim-tree").setup({
  mappings = {
    ["."] = "change_root", -- add a binding
    s = false,             -- disable the default split-open
    ["g?"] = function(_tree, api) api.reveal() end, -- custom
  },
})
```

The defaults:

```
<CR> / o   select         a       create
l          expand         r       rename
h          collapse       d       delete
s          open_split     x       cut
v          open_vsplit    c       copy
t          open_tab       p       paste
E          expand_all     y       yank_path
W          collapse_all   R       refresh
P          parent         H       toggle_hidden
>          change_root    f       reveal
<          up_root        /       filter
q          close          <Esc>   clear_filter
```

Every mappable action, with what it does (the same descriptions the keymaps carry as their `desc`,
so `<leader>fk` and the which-key popup read them):

```
select            Open a file / toggle a directory
open_split        Open the file in a horizontal split
open_vsplit       Open the file in a vertical split
open_tab          Open the file in a new tab
expand            Expand the directory under the cursor
collapse          Collapse the directory (or jump to the parent)
expand_all        Recursively expand every directory
collapse_all      Collapse everything back to the root
parent            Move the cursor to the parent directory's node
create            Create a file (trailing "/" → directory)
rename            Rename the entry under the cursor
delete            Delete the entry (confirms)
cut               Mark the entry to be moved on the next paste
copy              Mark the entry to be copied on the next paste
paste             Move/copy the marked entry under the cursor's dir
clear_clipboard   Forget a pending cut/copy
yank_path         Yank the absolute path to the " and + registers
refresh           Re-scan the whole tree
toggle_hidden     Show/hide dotfiles
change_root       Make the directory under the cursor the new root
up_root           Make the parent of the current root the new root
reveal            Reveal the file open in the main window
filter            Prompt for a name filter
clear_filter      Drop an active filter
close             Hide the tree and return to the editor
mouse_click       Single left-click: toggle the dir under the pointer
mouse_open        Double left-click: open the file under the pointer
mouse_menu        Right-click: a context menu for the node
```

That list is also available at runtime as `require("nxvim-tree.config").ACTIONS`, a
`name → description` map.

# Mouse

The mouse is on by default:

```
<LeftMouse>     mouse_click   single click: expand / collapse a directory
<2-LeftMouse>   mouse_open    double click: open a file in the editor
<RightMouse>    mouse_menu    context menu for the node under the pointer
```

Files do not open on a single click, so a stray click never opens a buffer. The wheel scrolls the
sidebar.

The context menu is context-aware — open / split / tab for a file, expand / new / set-root for a
directory, and the file ops (rename, delete, cut, copy, paste, copy-path) where they apply. It is
built from the same actions as the keys, so it always matches your bindings. It needs the tree
focused, since a right-click does not focus a window: left-click into the sidebar first, or it is
already focused after any other interaction.

Turn the mouse off — or remap it — like any other key:

```lua
require("nxvim-tree").setup({
  mappings = {
    ["<LeftMouse>"] = false,
    ["<2-LeftMouse>"] = false,
    ["<RightMouse>"] = false,
    -- … or open files on a single click too:
    -- ["<LeftMouse>"] = "select",
  },
})
```

# Extending

The plugin is built to be extended without forking it.

## Icons

Extend the extension / filename registry:

```lua
require("nxvim-tree").register_icons({
  conf = { glyph = "\u{e615}", hl = "NxTreeIconDefault" },
  name = { [".env"] = { glyph = "\u{f462}", hl = "NxTreeIconText" } },
})
```

The same table can be passed at setup time as `icon_overrides`.

## Decorators

Add a sign, highlight, or virtual text per node. A decorator is
`fn(node) -> { sign_text=, sign_hl=, hl=, virt_text= }` (or `nil`), merged into every visible line's
decoration on each render. The built-in git module is just a decorator:

```lua
require("nxvim-tree").register_decorator(function(node)
  if node.name == "TODO.md" then
    return { virt_text = { { "  ←", "WarningMsg" } } }
  end
end)
```

## Actions

Bind a key to `fn(tree, api)`, run inside the async error-surfacing wrapper (so it may `nx.await`
freely, and a rejection becomes a notification rather than an unhandled error):

```lua
require("nxvim-tree").register_action("gx", function(_tree, api)
  local node = api.node()       -- the node under the cursor
  if node then nx.ui.open(node.path) end
end)
```

`api` is the helper bundle handed to every action and to the git module:

```
api.render(opts)            re-render the visible lines
api.run(body)               run an async body, surfacing rejections
api.reveal(path, opts)      expand to and land on a path
api.refresh()               re-scan the whole tree
api.close()                 hide the sidebar
api.set_root(path)          rebuild rooted at path
api.register_decorator(fn)  add a decorator
api.root()                  the current root path (nil if unbuilt)
api.state()                 the tree state
api.node()                  the node under the cursor
```

## on_attach

Run once when the tree buffer exists, for buffer-scoped maps and options:

```lua
require("nxvim-tree").setup({
  on_attach = function(api, bufnr) end,
})
```

# Highlights

The explorer uses the canonical `NvimTree*` highlight group names from nvim-tree.lua — so a ported
colorscheme that already styles those groups (e.g. catppuccin's nvim-tree integration) themes the
tree unmodified.

```
NvimTreeNormal             the sidebar background (via winhighlight)
NvimTreeEndOfBuffer        the `~` fillers
NvimTreeCursorLine         the highlighted current row
NvimTreeCursorLineNr       its line number
NvimTreeRootFolder         the root header line
NvimTreeFolderName         a closed directory name
NvimTreeOpenedFolderName   an expanded directory name
NvimTreeEmptyFolderName    a directory with no children
NvimTreeFolderIcon         the folder glyph
NvimTreeIndentMarker       the tree guide lines
NvimTreeSymlink            a symlink name
NvimTreeOpenedFile         a file currently open in a buffer
NvimTreeSpecialFile        README / Makefile / Cargo.toml …
NvimTreeImageFile          image files
NvimTreeCutHL              a node marked to be moved
NvimTreeCopiedHL           a node marked to be copied
NvimTreeLiveFilterValue    the active "/filter" tag
NvimTreeGitNew             untracked / added
NvimTreeGitDirty           modified (and the dirty-directory dot)
NvimTreeGitStaged          staged-only
NvimTreeGitDeleted         deleted
```

A plain file's name is left unhighlighted so it inherits the window's `Normal`, exactly as in
nvim-tree.

These groups are defined only as a FALLBACK — a colorscheme (or your `opts.highlights` override)
that defines them wins, regardless of load order. The four window-chrome groups link to the
editor's own chrome (`NormalFloat`, `EndOfBuffer`, `CursorLine`, `CursorLineNr`) so they follow the
active theme's light/dark flavour:

```lua
require("nxvim-tree").setup({
  highlights = { NvimTreeRootFolder = { fg = "#f9e2af", bold = true } },
})
```

Per-extension icon colors have no NvimTree equivalent (nvim-tree colors icons via
nvim-web-devicons), so those live under the plugin's own `NxTreeIcon*` namespace — `NxTreeIconRust`,
`NxTreeIconLua`, `NxTreeIconMd`, … — and can likewise be overridden.

# Git status

With `git = true` the tree shells out to `git status --porcelain` through `nx.run` (a promise, so
nothing blocks), builds a path → status map, and paints a gutter sign per changed file plus a dirty
dot on every directory that contains a change. It re-fetches on `BufWritePost`.

```
+   untracked / added      NvimTreeGitNew
~   modified               NvimTreeGitDirty
✓   staged-only            NvimTreeGitStaged
-   deleted                NvimTreeGitDeleted
•   a directory containing a change
```

A non-git directory (or a missing `git`) simply leaves the tree unmarked; with `git = false` — the
default — none of it runs.

# Module API

Beyond `setup()` and the extensibility registries, the module exposes the lifecycle directly, for
scripting and for your own keymaps:

```
require("nxvim-tree").toggle()       toggle the sidebar
                    .open()          open + focus (building if needed)
                    .close()         hide it, focus back to the editor
                    .focus()         focus the tree (alias of open)
                    .refresh()       re-scan, preserving expansion
                    .set_root(path)  rebuild rooted at path
                    .reveal(path, o) expand to a path and land on it
                    .destroy()       tear it down; next open rebuilds
                    .bufnr()         the view's buffer number, or nil
                    .api             the helper bundle (see Actions)
```

`reveal()` defaults to the file in the current window and focuses the sidebar; pass
`{ focus = false }` to move the cursor but bounce focus back to the editor (what `follow` does).

# Trying it locally

This repo ships a runnable demo:

```sh
NXVIM_CONFIG=examples nxvim examples/sample/readme.txt
```

(run from the repo root — the demo config in `examples/init.lua` loads the plugin straight from this
checkout).

# Tests

```sh
nxvim --test-plugin .
```

The suite covers the config merge and validation, the model (lazy load, sort, hidden filter, refresh
identity), icon and git classification, and the end-to-end flows — render, expand/collapse, hidden
toggle, filter, create, delete, open, change-root, and the mouse click and right-click-menu gestures
— driven with real keys over a temp filesystem.
