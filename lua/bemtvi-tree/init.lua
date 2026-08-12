-- bemtvi-tree — a dockable, extensible file explorer for bemtvi, built entirely on the
-- native `btv.*` plugin API (ADR 0002): no buffer-mutation API, no native widget.
--
-- It composes the editor's content + filesystem primitives — `btv.view` (the
-- read-only, mountable line surface), `btv.fs` (the promise filesystem: readdir,
-- mutation, per-directory watch), `btv.open(path, { where = "main" })` (open a file in the
-- MAIN editor, not the sidebar), `btv.dock` (the edge panel it lives in), `btv.ui`
-- (prompts / confirms), and extmarks (icons, guides, decorator signs). The tree's
-- lines are OWNED by the view — the plugin never mutates a buffer.
--
-- Module map (one concern each):
--   config.lua      defaults + validated merge
--   highlights.lua  the highlight palette (fallback-applied)
--   icons.lua       extension/name → glyph registry
--   model.lua       the node tree, lazy scandir-on-expand, flatten-to-visible
--   render.lua      visible nodes → view lines + extmark decoration
--   actions.lua     open / navigate / create / rename / delete / cut / copy / paste …
--   keymap.lua      install the configured bindings on the tree buffer
--   git.lua         the git-status decorator (on by default; `git = false` opts out)
-- This file owns the singleton tree state, the open/close/toggle lifecycle, the
-- root-change + reveal flows, the auto-refresh watch and follow autocmd, the
-- cross-session persistence (a `persist`-id view + `btv.view.on_restore`, snapshotting
-- root/expanded/cursor/hidden into the plugin's own `btv.shada` slice), the public extensibility
-- registries, and `setup()`.
--
-- Quick start (init.lua):
--   require("bemtvi-tree").setup({ width = 32 })
--   -- then <leader>e or :Tree toggles the sidebar.

local config = require("bemtvi-tree.config")
local highlights = require("bemtvi-tree.highlights")
local icons = require("bemtvi-tree.icons")
local model = require("bemtvi-tree.model")
local render_mod = require("bemtvi-tree.render")
local actions = require("bemtvi-tree.actions")
local keymap = require("bemtvi-tree.keymap")

local M = {}

-- The effective configuration (rebuilt from defaults on every setup() — see setup).
-- `_decorators` is the live decorator list the render reads; it lives on config so a
-- decorator registered before the first open still applies. `icon_overrides` /
-- `highlights` are consumed at setup time.
M.config = config.defaults()
M.config._decorators = {}

local tree = nil -- the singleton tree state, built lazily on first open
local hl_applied = false
local autocmds_wired = false
local restore_wired = false

-- ----- cross-session persistence ---------------------------------------------
-- The tree rides the workspace session via the core persisted-view mechanism: its view is
-- minted with a stable `persist` id, so a restore reserves the sidebar's dock slot; the
-- plugin keeps the actual snapshot (root + expanded dirs + cursor + the dotfile toggle) in
-- its own isolated shada slice (`btv.shada.plugin()`), and rebuilds the view from it in the
-- `btv.view.on_restore` handler wired by setup(), adopting the reserved window. Gated by
-- `config.persist` (default true). Restore takes effect for a session-scoped launch
-- (`--workspace` + `btv.shada.save_layout(true)`) — otherwise the persist id just rides
-- along and the WINDOW isn't restored, exactly like any other window. The dotfile toggle
-- is the exception: it is a preference rather than window state, so setup() applies the
-- saved value to the config on every launch, whatever build path opens the sidebar.
--
-- `btv.view.on_restore` is a PULL: registering the handler (in setup(), below) also drains
-- any slot core already reserved for us, so this restores correctly even though we load
-- LATE — asynchronously, via `btv.plugins({ config = … })` — on a tick after core's one-shot
-- boot dispatch. Core holds the reserved slot (deferring orphan collapse) until every eager
-- plugin load settles, so a late registration reliably still claims it.
local PERSIST_ID = "bemtvi-tree"
local SESSION_KEY = "session"
-- Resolved ONCE here, on the module's own stack, so it always attributes to this plugin
-- file — never to some async/deferred caller whose stack no longer carries it.
local store = btv.shada.plugin()

-- The snapshot a restoring session left in the store, captured at setup() time — BEFORE an
-- `open_on_start` build (or any first render) can overwrite the store with a fresh,
-- collapsed snapshot. The `on_restore` handler (which now drains our reserved slot the moment
-- we register it, at setup()) reads THIS, not the live store, so a pre-restore open can't
-- clobber what we restore from.
local pending_restore = nil
local restore_captured = false

local function persist_enabled()
  return M.config.persist ~= false
end

-- ----- async helper ----------------------------------------------------------

-- Run an async body (which may btv.await fs/ui promises), surfacing any rejection as a
-- notification instead of an unhandled promise error.
local function run(body)
  btv.async(body)():catch(function(e)
    local msg = type(e) == "table" and e.message or e
    btv.notify("bemtvi-tree: " .. tostring(msg), 4)
  end)
end

-- Reconcile the per-directory watch set after each render (forward-declared so the
-- render wrapper can call it; defined below alongside the watch helpers).
local reconcile_watches
-- Keep the sign gutter permanently open on the tree window — but ONLY inside a git
-- repository, which is why this is driven by the git module's first successful status
-- rather than set with the rest of the window chrome at build time.
--
-- The gutter is where the git status signs land. Left at the editor's `signcolumn=auto`
-- default, the column materializes the moment the first sign appears and collapses when the
-- last one goes, sliding the whole sidebar — every icon and filename — one column sideways
-- as you edit. Reserving it is what makes the name's start column genuinely fixed, which is
-- the point of the whole git presentation. Outside a repo no sign can ever appear, so
-- reserving there would only waste a column: the tree keeps the editor's default.
-- (`"yes"` is one always-present column — the same thing as `yes:1`, which the option
-- normalizes to `"yes"` when read back.)
local function reserve_gutter()
  local win = tree and tree.view:winid()
  if win then
    btv.wo[win].signcolumn = "yes"
  end
end
-- The session-snapshot helpers the render wrapper persists through (defined below in the
-- "session snapshot" section, forward-declared here so render can reach them).
local expanded_paths, write_session

local function render(opts)
  if tree then
    render_mod.render(tree, opts)
    reconcile_watches()
    -- Recompute the expanded-dir snapshot here (structural changes only flow through a
    -- render) and persist it; cursor moves patch the cursor field separately and reuse
    -- this cached list. Forward-declared write_session/expanded_paths — see below.
    tree._expanded = expanded_paths(tree)
    write_session()
  end
end

-- The helper bundle handed to every action / the git module. The closures read the
-- live `tree` upvalue, so a single api object stays valid across rebuilds.
local api = {
  run = run,
  render = render,
  set_root = function(path)
    M.set_root(path)
  end,
  reveal = function(path, opts)
    M.reveal(path, opts)
  end,
  refresh = function()
    M.refresh()
  end,
  close = function()
    M.close()
  end,
  register_decorator = function(fn)
    M.register_decorator(fn)
  end,
  -- The current tree root path, or nil when the tree isn't built (git uses this).
  root = function()
    return tree and tree.root.path
  end,
  -- Publish the git module's repo state — `{ root, ignored }` — onto the tree. Being
  -- called at all means we ARE inside a repository, which is what gates the reserved
  -- gutter (see reserve_gutter). The ignored set is read by the render's hide filter and
  -- the decorator.
  set_git_state = function(state)
    if not tree then
      return
    end
    tree._git = state
    reserve_gutter()
  end,
  -- Introspection for custom actions: the tree state and the node under the cursor.
  state = function()
    return tree
  end,
  node = function()
    return tree and actions.current(tree)
  end,
}
M.api = api

-- ----- the auto-refresh watch ------------------------------------------------

-- The watch is per-EXPANDED-directory, not one recursive watch over the whole tree:
-- `tree._watches` maps a directory path → `{ node, handle, stopped }` for every
-- directory whose contents are currently visible. A collapsed subtree — however large
-- — costs nothing, and on macOS (a kqueue backend that opens one fd per watched path)
-- a recursive whole-tree watch would exhaust file descriptors. `reconcile_watches`
-- (run after every render) diffs the desired set against the live one.

-- Stop and forget the watch on `path` (if any). Sets `stopped` so an in-flight arm or a
-- queued event for that path becomes a no-op.
local function unwatch_dir(path)
  local entry = tree and tree._watches[path]
  if not entry then
    return
  end
  entry.stopped = true
  tree._watches[path] = nil
  if entry.handle then
    pcall(function()
      entry.handle:stop()
    end)
  end
end

-- Arm a non-recursive watch on directory `node`; on each change re-scandir just that
-- directory (its own children) and re-render. Best-effort — a build with no native
-- watcher (browser/serverless) rejects the first pull, surfaced once via run's catch,
-- degrading to manual refresh. The arm is async, so the directory may be collapsed
-- before it lands: `entry.stopped` guards both the late arm and any queued event.
local function watch_dir(node)
  if tree._watches[node.path] then
    return
  end
  local entry = { node = node, handle = nil, stopped = false }
  tree._watches[node.path] = entry
  run(function()
    local w = btv.fs.watch(node.path, { recursive = false })
    if entry.stopped then -- collapsed (or root changed) before the watch armed
      pcall(function()
        w:stop()
      end)
      return
    end
    entry.handle = w
    for _ in btv.await_each(w) do
      if entry.stopped then
        break
      end
      model.load(tree, node) -- re-scandir this one directory, preserving subtrees
      render({ restore_cursor = false })
    end
  end)
end

-- reconcile_watches() — make the live watch set match the visible directories: watch
-- every expanded+loaded directory (root downward), drop watches for any directory that
-- is no longer expanded (collapsed, or pruned by a refresh/root change). Idempotent and
-- cheap (a walk of the loaded model + a set diff); called at the end of every render.
function reconcile_watches()
  if not tree or not tree.config.watch then
    return
  end
  local desired = {}
  local function walk(node)
    if node.type == "directory" and node.expanded and node.loaded then
      desired[node.path] = node
      for _, c in ipairs(node.children) do
        walk(c)
      end
    end
  end
  walk(tree.root)

  for path in pairs(tree._watches) do
    if not desired[path] then
      unwatch_dir(path)
    end
  end
  for path, node in pairs(desired) do
    if not tree._watches[path] then
      watch_dir(node)
    end
  end
end

-- Stop every directory watch (root change, destroy).
local function stop_all_watches()
  if not tree then
    return
  end
  for path in pairs(tree._watches) do
    unwatch_dir(path)
  end
end

-- Run `fn` once the view's backing buffer exists (its bufnr arrives a tick after the
-- create/mount ops drain). `btv.wait_for` polls between ticks until then.
local function when_buf(fn)
  btv.wait_for(function()
    return tree and tree.view:bufnr()
  end)
    :next(fn)
    :catch(function() end)
end

-- ----- session snapshot ------------------------------------------------------

-- expanded_paths(tree) — the absolute paths of every currently-expanded, loaded
-- directory (root downward). Order is a pre-order walk, so an ancestor always precedes
-- its descendants — exactly the order `restore_expansion` re-opens them in. (The root
-- is always expanded, so it heads the list.)
function expanded_paths(t)
  local out = {}
  local function walk(node)
    if node.type == "directory" and node.expanded and node.loaded then
      out[#out + 1] = node.path
      for _, c in ipairs(node.children) do
        walk(c)
      end
    end
  end
  walk(t.root)
  return out
end

-- write_session() — stash the current snapshot in this plugin's shada slice, so a restart
-- can rebuild the sidebar. Cheap and eager (an in-memory set; the disk write rides shada's
-- own cadence), called on every structural change and cursor move. `tree._expanded` is
-- recomputed only on the (rarer) structural renders and reused here so a cursor move
-- doesn't re-walk the model. A no-op when persistence is off or the tree isn't built.
function write_session()
  if not (tree and persist_enabled()) then
    return
  end
  store:set(SESSION_KEY, {
    root = tree.root.path,
    expanded = tree._expanded or { tree.root.path },
    cursor = tree._cursor_path,
    -- The dotfile toggle is session state, not static config: `H` flips it, and the next
    -- session's setup() would otherwise re-merge the configured default over the user's
    -- choice. Normalized to a real boolean so `false` persists as `false`, not as an
    -- absent key (which build() reads as "no saved preference").
    hidden = tree.config.hidden == true,
    -- Same story for the `I` toggle: a runtime preference the next session's config merge
    -- would otherwise reset. Stored as its string mode, so an unknown future value is
    -- simply ignored on the way back in rather than silently read as a boolean.
    git_ignored = tree.config.git_ignored,
    -- And the `U` toggle. Only the on/off switch persists, never the `filters` list
    -- itself: the patterns are config the user edits, and a stale copy in shada would
    -- outrank an edited setup() until they noticed.
    filters_enabled = tree.config.filters_enabled ~= false,
  })
end

-- node_at_path(tree, path) — the model node at absolute `path`, found by descending
-- from the root through `find_child`, or nil if any segment is missing / unloaded.
-- Callers descend only into ancestors they have already expanded (loaded), so the walk
-- never needs an off-tick fs read.
local function node_at_path(t, path)
  if path == t.root.path then
    return t.root
  end
  local base = t.root.path
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  if path:sub(1, #base) ~= base then
    return nil
  end
  local node = t.root
  for seg in path:sub(#base + 1):gmatch("[^/]+") do
    if not node.loaded then
      return nil
    end
    node = model.find_child(node, seg)
    if not node then
      return nil
    end
  end
  return node
end

-- restore_expansion(tree, paths) — re-open the saved directory set. `paths` is sorted
-- shallowest-first (lexicographic order puts an ancestor path, a prefix, before its
-- descendants) so each directory's parent is loaded before we descend to it. A directory
-- that has since vanished on disk (its scandir rejects) is skipped, not fatal — a stale
-- snapshot degrades to a partially-expanded tree, never a failed restore. Awaits; call
-- inside btv.async.
local function restore_expansion(t, paths)
  if not pcall(function()
    model.expand(t, t.root)
  end) then
    return
  end
  table.sort(paths)
  for _, p in ipairs(paths) do
    if p ~= t.root.path then
      local node = node_at_path(t, p)
      if node and node.type == "directory" then
        pcall(function()
          model.expand(t, node)
        end)
      end
    end
  end
end

-- place_cursor(tree, path) — land the tree cursor on the node for `path` if it is
-- currently visible (its ancestors expanded). Focuses the view — callers bounce focus
-- back to the editor afterwards.
local function place_cursor(t, path)
  if not path then
    return
  end
  for i, n in ipairs(t.flat) do
    if n.path == path then
      t.view:set_cursor(i)
      return
    end
  end
end

-- ----- build / lifecycle -----------------------------------------------------

-- Build the tree on first open: mint the view, mount it in the configured dock side,
-- load + render the root, install the bindings + on_attach + git, arm the watch, then
-- land focus back in the editor.
--
-- `opts` drives the cross-session restore path (from the `on_restore` handler):
--   opts.place    — `place(view)` adopts the reserved restore window instead of opening a
--                   fresh dock (the session already restored the dock geometry);
--   opts.restore  — the saved snapshot `{ root, expanded, cursor, hidden }`; the model is
--                   rooted there, its saved directories + cursor are re-opened, and the
--                   dotfile toggle is restored.
-- Absent ⇒ a fresh open rooted at the configured root / cwd, expanding only the root.
local function build(opts)
  opts = opts or {}
  local restore = opts.restore
  if not hl_applied then
    highlights.apply(M.config.highlights)
    hl_applied = true
  end

  -- Restore the dotfile toggle before the root loads, so the very first scandir already
  -- applies the saved filter (no visible flip). `H` toggles `config.hidden` in place, so
  -- this writes back to the same field — a snapshot predating this state has no `hidden`
  -- key and leaves the configured default alone.
  if restore and type(restore.hidden) == "boolean" then
    M.config.hidden = restore.hidden
  end
  if restore and config.GIT_IGNORED_MODES[restore.git_ignored] then
    M.config.git_ignored = restore.git_ignored
  end
  if restore and type(restore.filters_enabled) == "boolean" then
    M.config.filters_enabled = restore.filters_enabled
  end

  tree = {
    root = model.root((restore and restore.root) or M.config.root or vim.fn.getcwd()),
    ns = btv.ns.create("bemtvi-tree"),
    flat = {},
    filter = nil,
    config = M.config,
    -- The persist id opts the view into cross-session restore (unless config.persist is
    -- off); the owning namespace is auto-resolved from this plugin file. On the restore
    -- path we re-create with the SAME id so the sidebar keeps riding future sessions.
    view = btv.view.create({
      name = "bemtvi-tree",
      filetype = "btvtree",
      persist = persist_enabled() and PERSIST_ID or nil,
    }),
    _clipboard = nil,
    _watches = {}, -- path → { node, handle, stopped }, reconciled after each render
    _expanded = nil, -- cached expanded-dir snapshot (recomputed each structural render)
    _cursor_path = nil, -- the node under the cursor, tracked for the session snapshot
    -- `{ root, ignored }` once the git module's first status lands (nil outside a repo,
    -- or before it does): the repo root + git-ignored path set. Read by the render's
    -- hide-ignored filter; its arrival is also what reserves the sign gutter.
    _git = nil,
  }
  tree.view:on_select(function()
    run(function()
      actions.select(tree, api)
    end)
  end)
  -- Adopt the reserved restore slot, or open a fresh dock.
  if opts.place then
    opts.place(tree.view)
  else
    tree.view:mount({ dock = M.config.position, size = M.config.width })
  end

  -- Sidebar chrome (like nvim-tree): a darker window background and hidden `~`
  -- fillers, plus a highlighted current row. The background remap rides the DOCK
  -- (keyed by side, not a window id) so it survives the dock being parked/revealed
  -- across `:NvimTreeToggle` and the restore path; `cursorline` is a window option,
  -- so it must ride the tree window itself once its id settles (a tick after mount).
  local WINHL = "Normal:NvimTreeNormal,EndOfBuffer:NvimTreeEndOfBuffer,"
    .. "CursorLine:NvimTreeCursorLine,CursorLineNr:NvimTreeCursorLineNr"
  btv.dock.opt(M.config.position).winhighlight = WINHL
  btv.wait_for(
    function()
      return tree.view:winid()
    end,
    { tries = 100, interval = 10, message = "bemtvi-tree: window never appeared for chrome setup" }
  )
    :next(function(win)
      -- Also set the remap on the window directly, so a restore slot that isn't a
      -- dock still gets the darker background.
      btv.wo[win].winhighlight = WINHL
      btv.wo[win].cursorline = true
      -- A repo whose status already landed (a rebuild inside a live session) re-pins the
      -- gutter here, since this fresh window starts at the default `signcolumn`.
      if tree._git then
        reserve_gutter()
      end
    end)
    :catch(function() end)

  run(function()
    if restore then
      restore_expansion(tree, restore.expanded or {})
      render({ restore_cursor = false })
      place_cursor(tree, restore.cursor) -- focuses the view…
      btv.layer.main() -- …so bounce focus back to the editor
    else
      model.expand(tree, tree.root)
      render({ restore_cursor = false })
    end
  end)

  when_buf(function()
    local buf = tree.view:bufnr()
    keymap.install(tree, api)
    if M.config.git then
      require("bemtvi-tree.git").enable(api)
    end
    if type(M.config.on_attach) == "function" then
      M.config.on_attach(api, buf)
    end
    -- Track the cursor for the session snapshot: a plain j/k motion flows through no
    -- render, so we patch the cursor field here (buffer-local, so it only fires on the
    -- tree) and re-persist, reusing the expanded-dir list cached at the last render.
    btv.on("CursorMoved", { buffer = buf }, function()
      if not tree then
        return
      end
      local line = tree.view:line()
      local node = line and tree.flat[line]
      tree._cursor_path = node and node.path or nil
      write_session()
    end)
    -- The watch set is armed by reconcile_watches() in render (the initial render
    -- already ran); nothing to arm here.
    tree._maps_installed = true -- a readiness signal (the action maps are live)
  end)

  btv.layer.main()
end

-- toggle() — build + mount on first use, then toggle the dock's visibility.
function M.toggle()
  if tree == nil then
    build()
  else
    btv.dock.toggle(M.config.position)
  end
end

-- open() — open + focus the sidebar (build if needed).
function M.open()
  if tree == nil then
    build()
  else
    btv.dock.show(M.config.position)
    tree.view:focus()
  end
end

-- close() — hide the sidebar and return focus to the editor.
function M.close()
  if tree then
    btv.dock.hide(M.config.position)
    btv.layer.main()
  end
end

-- focus() — move focus into the tree (building it if needed).
function M.focus()
  M.open()
end

-- refresh() — re-scan the whole tree (preserving expansion) and re-render.
function M.refresh()
  if tree then
    run(function()
      model.refresh(tree, tree.root)
      render({ restore_cursor = true })
    end)
  end
end

-- set_root(path) — rebuild the model rooted at `path`, keeping the same view. Drops
-- the old root's watches; the render below re-arms the new tree via reconcile_watches.
-- Clears the filter and any pending clipboard.
function M.set_root(path)
  if not tree then
    return
  end
  stop_all_watches()
  tree.root = model.root(path)
  tree.filter = nil
  tree._clipboard = nil
  run(function()
    model.expand(tree, tree.root)
    render({ restore_cursor = false })
  end)
  btv.notify("bemtvi-tree: root → " .. tree.root.path)
end

-- destroy() — tear the tree down completely (stop every watch, drop the view buffer,
-- forget the singleton). The next open() rebuilds from scratch. Primarily for tests
-- and for a hard reset.
function M.destroy()
  if tree then
    stop_all_watches()
    pcall(function()
      tree.view:close()
    end)
    tree = nil
  end
end

-- reveal(path, opts) — open the tree (building it if needed), expand the directories
-- along `path` (default: the file in the current window), land the cursor on its
-- node, and (by default) focus the sidebar. `opts.focus = false` moves the cursor but
-- bounces focus back to the editor (used by `follow`). A no-op for a path outside the
-- root.
function M.reveal(path, opts)
  opts = opts or {}
  local focus = opts.focus ~= false
  if tree == nil then
    build()
  end
  run(function()
    local target = path
    if not target or target == "" then
      target = vim.fn.expand("%:p")
    end
    if not target or target == "" then
      if focus then
        btv.notify("bemtvi-tree: no file to reveal", 3)
      end
      return
    end

    local base = tree.root.path
    if base:sub(-1) ~= "/" then
      base = base .. "/"
    end
    if target:sub(1, #base) ~= base then
      if focus then
        btv.notify("bemtvi-tree: " .. target .. " is outside the tree root", 3)
      end
      return
    end

    local segments = {}
    for seg in target:sub(#base + 1):gmatch("[^/]+") do
      segments[#segments + 1] = seg
    end
    if #segments == 0 then
      return
    end

    tree.filter = nil
    if not tree.root.loaded then
      model.load(tree, tree.root)
    end
    tree.root.expanded = true
    local node = tree.root
    for i, seg in ipairs(segments) do
      local child = model.find_child(node, seg)
      if not child then
        node = nil
        break
      end
      if i < #segments and child.type == "directory" then
        model.expand(tree, child)
      end
      node = child
    end

    render({ restore_cursor = false })
    if not node then
      if focus then
        btv.notify("bemtvi-tree: " .. target .. " not found under the root", 3)
      end
      return
    end
    for i, n in ipairs(tree.flat) do
      if n == node then
        tree.view:set_cursor(i) -- this focuses the view…
        if not focus then
          btv.layer.main() -- …so bounce focus back when following.
        end
        return
      end
    end
  end)
end

-- bufnr() — the view's backing buffer number (or nil before the tree is built /
-- mounted). An introspection handle for add-ons and tests.
function M.bufnr()
  return tree and tree.view:bufnr()
end

-- _ready() — true once the tree is built AND its buffer-local action maps are
-- installed. The buffer exists (and the <CR> map works) a tick before the action
-- maps do; tests wait on this before feeding action keys (a / H / d / …).
function M._ready()
  return tree ~= nil and tree._maps_installed == true
end

-- _watched_paths() — the directory paths the auto-refresh watch currently covers (one
-- per expanded, visible directory). Empty when the tree isn't built or `watch` is off.
-- Introspection for tests (asserting the watch is per-directory, not whole-tree).
function M._watched_paths()
  local out = {}
  if tree then
    for path in pairs(tree._watches) do
      out[#out + 1] = path
    end
  end
  return out
end

-- _session() — the snapshot this plugin last stashed in its shada slice (`{ root,
-- expanded, cursor, hidden }`), or nil. Introspection for tests that the persistence writes.
function M._session()
  return store:get(SESSION_KEY)
end

-- _pending_restore() — the snapshot captured at setup() that `on_restore` will rebuild
-- from (nil when there is nothing to restore). Introspection for tests / diagnostics.
function M._pending_restore()
  return pending_restore
end

-- _restore(snap) — rebuild the tree from a saved snapshot as `on_restore` does, but
-- mounting a fresh dock (no reserved slot). The content-rebuild half of the restore path,
-- exercisable in-process; the window-adoption half is covered by the server session tests.
function M._restore(snap)
  M.destroy()
  build({ restore = snap })
end

-- ----- extensibility registries ----------------------------------------------

-- register_decorator(fn) — `fn(node) -> { sign_text=, sign_hl=, hl=, virt_text= }` (or
-- nil), merged into every visible line's decoration each render.
function M.register_decorator(fn)
  M.config._decorators[#M.config._decorators + 1] = fn
  render({ restore_cursor = false })
end

-- register_icons(map) — extend the extension/name → glyph table (see icons.lua).
function M.register_icons(map)
  icons.register(map)
  render({ restore_cursor = false })
end

-- register_action(key, fn) — bind a buffer-local `key` to `fn(tree, api)`, run inside
-- the async error-surfacing wrapper. Persists into the live mappings so a later
-- rebuild keeps it.
function M.register_action(key, fn)
  M.config.mappings[key] = fn
  if tree and tree.view:bufnr() then
    btv.keymap.set("n", key, function()
      run(function()
        fn(tree, api)
      end)
    end, { buffer = tree.view:bufnr(), desc = "bemtvi-tree: Custom action" })
  end
end

-- ----- autocmds (wired once) -------------------------------------------------

-- BufEnter housekeeping while the tree is open: keep the NvimTreeOpenedFile highlight
-- fresh as you switch buffers, and — when `follow` is on — reveal the active file.
-- Wired once; the handler reads the live config so toggling `follow` needs no
-- re-register. Ignores the tree's own buffer (set_cursor focuses it → BufEnter) to
-- avoid a feedback loop.
local function wire_autocmds()
  if autocmds_wired then
    return
  end
  autocmds_wired = true
  btv.on("BufEnter", {}, function()
    if not tree or not tree.view:winid() then
      return
    end
    local cur = btv.win.buf(btv.win.current())
    if cur == tree.view:bufnr() then
      return
    end
    if tree.config.follow then
      local name = vim.fn.expand("%:p")
      if name and name ~= "" then
        M.reveal(name, { focus = false }) -- reveal renders, refreshing the opened-file tint
        return
      end
    end
    render({ restore_cursor = false }) -- refresh the opened-file highlight
  end)

  -- Re-derive the fallback highlights whenever the theme changes. `:colorscheme` drops
  -- only the OUTGOING scheme's own groups, so without this every group the incoming
  -- theme doesn't model (all the icons, the staged/ignored git states, the cut/copy
  -- marks — no colorscheme's nvim-tree integration covers them) keeps the colour
  -- derived from the previous theme: a dark-flavour palette left standing on a light
  -- one. `highlights.apply` yields to a theme that DOES style a group, so re-applying
  -- here never fights the colorscheme; it fires after the theme's own highlight calls.
  btv.on("ColorScheme", {}, function()
    highlights.apply(M.config.highlights)
  end)
end

-- Register the cross-session restore handler (wired once). After a session restore core
-- reserves the sidebar's slot; `btv.view.on_restore` is a PULL, so this registration itself
-- dispatches here — synchronously, right here in setup() — with the persist id and a `place`
-- that adopts the reserved window. We rebuild the tree from our own shada snapshot into that
-- window. Declining a foreign id (`id ~= PERSIST_ID`) returns WITHOUT calling `place`, which
-- leaves that slot unclaimed for its real owner — core marks a slot claimed only once `place`
-- runs.
--
-- Because the pull fires at registration, restore now happens BEFORE the `open_on_start`
-- branch in setup() (which is why setup() wires this first). `M.destroy()` stays as the
-- ordering-agnostic guard: it drops any sidebar already up — an earlier `open_on_start`, or a
-- prior setup() — so the restored one always wins without a duplicate dock, no matter which
-- ran first. No-op when persistence is off — then no slot is ever reserved and this never
-- fires.
local function wire_restore()
  if restore_wired or not persist_enabled() then
    return
  end
  restore_wired = true
  btv.view.on_restore(function(id, place)
    if id ~= PERSIST_ID then
      return
    end
    M.destroy() -- drop any sidebar already up (the restored one wins); usually a no-op now
    build({ place = place, restore = pending_restore })
  end)
end

-- ----- setup -----------------------------------------------------------------

-- setup(opts) — merge config, apply highlights + icon overrides, register the commands
-- and the toggle keymap. Re-runnable: a second call re-merges from defaults (so it is
-- a full reconfigure, not a partial patch) and re-applies, but keeps the singleton if
-- already built. See config.lua for the full option list and the mappable actions.
function M.setup(opts)
  M.config = config.merge(config.defaults(), opts)
  M.config._decorators = {}

  -- Snapshot the restore state up front (shada is already loaded here, plugins aren't yet
  -- built), so a later open_on_start build can't overwrite it before on_restore reads it.
  if persist_enabled() and not restore_captured then
    pending_restore = store:get(SESSION_KEY)
    restore_captured = true
  end
  -- The dotfile toggle is a preference, not per-window state, so the saved value beats the
  -- configured default on EVERY build — not just the `on_restore` one. Applied here (the
  -- merge above just reset the field) so a plain `:Tree` in a session whose sidebar wasn't
  -- part of the restored layout still honours the last `H`.
  if persist_enabled() and pending_restore and type(pending_restore.hidden) == "boolean" then
    M.config.hidden = pending_restore.hidden
  end
  if
    persist_enabled()
    and pending_restore
    and config.GIT_IGNORED_MODES[pending_restore.git_ignored]
  then
    M.config.git_ignored = pending_restore.git_ignored
  end
  if
    persist_enabled()
    and pending_restore
    and type(pending_restore.filters_enabled) == "boolean"
  then
    M.config.filters_enabled = pending_restore.filters_enabled
  end
  hl_applied = false
  highlights.apply(M.config.highlights)
  hl_applied = true
  if next(M.config.icon_overrides) then
    icons.register(M.config.icon_overrides)
  end

  -- A live tree adopts the new config (so :Tree, dock side, mappings stay sane).
  if tree then
    tree.config = M.config
  end

  btv.command("Tree", function()
    M.toggle()
  end, { desc = "Toggle the bemtvi-tree file explorer" })
  btv.command("TreeOpen", function()
    M.open()
  end, { desc = "Open + focus the bemtvi-tree file explorer" })
  btv.command("TreeClose", function()
    M.close()
  end, { desc = "Close the bemtvi-tree file explorer" })
  btv.command("TreeRefresh", function()
    M.refresh()
  end, { desc = "Re-scan the bemtvi-tree file explorer" })
  btv.command("TreeReveal", function()
    M.reveal()
  end, { desc = "Reveal the current file in bemtvi-tree" })

  local key = M.config.toggle_key
  if key then
    btv.keymap.set("n", key, function()
      M.toggle()
    end, { desc = "Toggle bemtvi-tree" })
  end

  wire_autocmds()
  wire_restore()

  if M.config.open_on_start then
    M.open()
  end

  return M
end

return M
