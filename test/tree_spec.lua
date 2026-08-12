-- End-to-end tree behaviour: open the explorer over a temp directory and drive it
-- with real keys, asserting on the rendered view buffer. Run with
-- `bemtvi --test-plugin`.
--
-- The view's <CR> activation map is installed synchronously at view-create, so
-- expand/collapse via <CR> is reliable immediately; the *action* maps (a / H / d / …)
-- arrive a tick later, so tests wait on `tree._ready()` before feeding those. The
-- input/confirm prompts both run in command-line mode, so we wait for mode "c" before
-- answering them.

local tree = require("bemtvi-tree")
local model = require("bemtvi-tree.model")
local fs = btv.fs

local ROOT

-- The joined text of the tree view buffer right now (or "" before it exists).
local function buf_text()
  local b = tree.bufnr()
  if not b then
    return ""
  end
  return table.concat(btv.buf.lines(b, 0, -1, false), "\n")
end

-- Wait until the view text contains `needle`, returning the text.
local function wait_contains(t, needle)
  return t:wait_for(function()
    local txt = buf_text()
    return txt:find(needle, 1, true) and txt
  end)
end

-- How many open windows show a buffer whose basename is `name`.
local function count_showing(name)
  local n = 0
  for _, w in ipairs(btv.win.list()) do
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(btv.win.buf(w)), ":t") == name then
      n = n + 1
    end
  end
  return n
end

-- The basename of the focused window's buffer.
local function current_name()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":t")
end

-- Open the tree, wait until it has rendered and its action maps are live, and focus
-- it so buffer-local keys fire.
local function open_ready(t)
  tree.open()
  wait_contains(t, "readme.txt")
  t:wait_for(function()
    return tree._ready()
  end)
  tree.focus()
  t:feed("") -- settle a tick so focus lands before we read/feed action keys
end

btv.test.describe("bemtvi-tree", function()
  btv.test.before_each(function()
    tree.destroy()
    -- The filter is bound to `<leader>/`, and `btv.keymap.set` bakes the leader in force
    -- at INSTALL time (which is the tree build, below/later — not now). Pin it to space
    -- so the tests can feed a stable `" /"` instead of depending on vim's `\` default.
    vim.g.mapleader = " "
    ROOT = btv.test.tempdir()
    btv.await(fs.write(model.join(ROOT, "readme.txt"), "hi"))
    btv.await(fs.mkdir(model.join(ROOT, "src")))
    btv.await(fs.write(model.join(ROOT, "src/main.rs"), ""))
    btv.await(fs.write(model.join(ROOT, ".secret"), ""))
    tree.setup({ root = ROOT, watch = false, toggle_key = false })
  end)

  btv.test.after_each(function()
    tree.destroy()
  end)

  -- Dotfiles are SHOWN by default: a file explorer that silently omits `.gitignore`,
  -- `.env`, `.github/` … hides exactly the files an editor session is usually there for.
  -- `H` (and `hidden = false`) is the opt-out.
  btv.test.it("renders the root's entries, directories suffixed and dotfiles shown", function(t)
    tree.open()
    local txt = wait_contains(t, "readme.txt")
    btv.test.expect(txt).to_contain("src/")
    btv.test.expect(txt).to_contain(".secret")
  end)

  btv.test.it("hides dotfiles with `hidden = false`", function(t)
    tree.destroy()
    tree.setup({ root = ROOT, watch = false, toggle_key = false, hidden = false })
    tree.open()
    local txt = wait_contains(t, "readme.txt")
    btv.test.expect(txt).to_contain("src/")
    btv.test.expect(txt).never.to_contain(".secret")
  end)

  btv.test.it("expands a directory on <CR>", function(t)
    open_ready(t)
    t:feed("j") -- onto src/ (line 2)
    t:feed("<CR>") -- expand
    btv.test.expect(wait_contains(t, "main.rs")).to_contain("main.rs")
  end)

  btv.test.it("collapses an expanded directory on <CR>", function(t)
    open_ready(t)
    t:feed("j"):feed("<CR>")
    wait_contains(t, "main.rs")
    t:feed("<CR>") -- cursor was kept on src/ → this collapses it
    local gone = t:wait_for(function()
      return not buf_text():find("main.rs", 1, true)
    end)
    btv.test.expect(gone).to_be_truthy()
  end)

  btv.test.it("toggles hidden files with H", function(t)
    open_ready(t)
    btv.test.expect(buf_text()).to_contain(".secret") -- shown by default
    t:feed("H")
    local gone = t:wait_for(function()
      local txt = buf_text()
      return not txt:find(".secret", 1, true) and txt
    end)
    btv.test.expect(gone).never.to_contain(".secret")
    t:feed("H")
    btv.test.expect(wait_contains(t, ".secret")).to_contain(".secret")
  end)

  btv.test.it("filters by name with <leader>/ and clears with <Esc>", function(t)
    open_ready(t)
    t:feed(" /") -- <leader>/ (mapleader is pinned to space in before_each)
    t:wait_for(function()
      return t:mode() == "c"
    end)
    t:feed("readme<CR>")
    local filtered = t:wait_for(function()
      local txt = buf_text()
      return txt:find("readme.txt", 1, true) and not txt:find("src/", 1, true) and txt
    end)
    btv.test.expect(filtered).to_contain("readme.txt")
    btv.test.expect(filtered).never.to_contain("src/")
    -- Clear the filter; src/ comes back.
    t:feed("<Esc>")
    btv.test.expect(wait_contains(t, "src/")).to_contain("src/")
  end)

  -- The tree buffer is an ordinary buffer, so a bare `/` must stay the EDITOR's search —
  -- the name filter lives on `<leader>/`. Both open cmdline mode, so the assertion is on
  -- what the search actually does: it moves the cursor to the matching row and leaves the
  -- tree fully rendered, where the filter would have pruned non-matching rows away.
  btv.test.it("leaves a bare / to the editor's own buffer search, not the filter", function(t)
    open_ready(t)
    local before = buf_text()
    t:feed("/")
    t:wait_for(function()
      return t:mode() == "c"
    end)
    t:feed("main<CR>") -- searches for main.rs — which is NOT visible (src/ is collapsed)
    t:feed("")
    -- A filter on "main" would have pruned readme.txt; the search leaves every row.
    btv.test.expect(buf_text()).to_be(before)
    btv.test.expect(buf_text()).to_contain("readme.txt")

    -- And the search really is live in this buffer: expand src/, then `/` onto main.rs
    -- lands the cursor on its row.
    t:feed("j") -- onto src/
    t:feed("<CR>") -- expand it
    wait_contains(t, "main.rs")
    t:feed("gg")
    t:feed("/")
    t:wait_for(function()
      return t:mode() == "c"
    end)
    t:feed("main.rs<CR>")
    local line = t:wait_for(function()
      local l = tree.api.state().view:line()
      local node = l and tree.api.state().flat[l]
      return node and node.path:find("main.rs", 1, true) and l
    end)
    btv.test.expect(line).to_be_truthy()
  end)

  btv.test.it("creates a file with `a`", function(t)
    open_ready(t) -- cursor on the root → creates in the root directory
    t:feed("a")
    t:wait_for(function()
      return t:mode() == "c"
    end)
    t:feed("brand_new.txt<CR>")
    btv.test.expect(wait_contains(t, "brand_new.txt")).to_contain("brand_new.txt")
    btv.test.expect(btv.await(fs.exists(model.join(ROOT, "brand_new.txt")))).to_be_truthy()
  end)

  -- The action maps carry a human-readable `desc` (config.ACTIONS), so bemtvi's
  -- keymaps picker / which-key can answer "what does `a` do?" with a real phrase
  -- rather than the internal action name.
  btv.test.it("gives each action map a friendly buffer-local desc", function(t)
    open_ready(t)
    local buf = tree.bufnr()
    local by_lhs = {}
    for _, m in ipairs(btv.keymap.buf_get(buf, "n")) do
      by_lhs[m.lhs] = m.desc
    end
    btv.test.expect(by_lhs["a"]).to_be('bemtvi-tree: Create a file (trailing "/" → directory)')
    btv.test.expect(by_lhs["d"]).to_be("bemtvi-tree: Delete the entry (confirms)")
  end)

  btv.test.it("deletes a file with `d` after confirming", function(t)
    open_ready(t)
    -- root(1) → src/(2) → .secret(3) → readme.txt(4): dotfiles are shown by default, so
    -- the dotfile sorts between the directory and the plain file.
    t:feed("j"):feed("j"):feed("j")
    t:feed("d")
    t:wait_for(function()
      return t:mode() == "c"
    end)
    t:feed("y") -- confirm
    local gone = t:wait_for(function()
      return not buf_text():find("readme.txt", 1, true)
    end)
    btv.test.expect(gone).to_be_truthy()
    btv.test.expect(btv.await(fs.exists(model.join(ROOT, "readme.txt")))).to_be_falsy()
  end)

  btv.test.it("opens a file in the main editor on <CR>", function(t)
    open_ready(t)
    t:feed("j"):feed("<CR>") -- expand src/
    wait_contains(t, "main.rs")
    -- move onto main.rs (root=1, src=2, main.rs=3) and open it
    t:feed("j"):feed("<CR>")
    local opened = t:wait_for(function()
      local name = vim.fn.expand("%:p")
      return name:find("main.rs", 1, true) and name
    end)
    btv.test.expect(opened).to_contain("main.rs")
  end)

  -- A split/tab open must carve the new window out of the MAIN editor, not the tree
  -- dock. The cross to main is queued and only lands after the queued split command
  -- runs, so opening the split in the same tick would split the dock; the action yields
  -- a tick so the focus lands first. A dock split would duplicate the tree buffer into a
  -- second window — so "exactly one window shows the tree buffer" is the regression check.
  btv.test.it("opens a split in the main editor with `s`, never splitting the dock", function(t)
    open_ready(t)
    t:feed("j"):feed("<CR>") -- expand src/
    wait_contains(t, "main.rs")
    t:feed("j") -- onto main.rs
    t:feed("s") -- open in a horizontal split
    local opened = t:wait_for(function()
      local name = vim.fn.expand("%:p")
      return name:find("main.rs", 1, true) and name
    end)
    btv.test.expect(opened).to_contain("main.rs")

    local treebuf = tree.bufnr()
    local showing = 0
    for _, w in ipairs(btv.win.list()) do
      if btv.win.buf(w) == treebuf then
        showing = showing + 1
      end
    end
    btv.test.expect(showing).to_be(1)
  end)

  -- Opening a file that is already shown in a main-editor window must JUMP to that
  -- window ('switchbuf'), not reload a duplicate into the focused one. The action
  -- passes `btv.open(..., { reuse = true })`; the regression is a second window
  -- ending up on the same file (and the other file getting clobbered).
  btv.test.it("jumps to an already-open window instead of duplicating it on <CR>", function(t)
    open_ready(t)
    local main_rs = model.join(ROOT, "src/main.rs")
    local readme = model.join(ROOT, "readme.txt")

    -- Lay out two main-editor windows: A shows main.rs, B (focused) shows readme.txt.
    btv.open(main_rs, { where = "main" }) -- cross to the editor
    t:wait_for(function()
      return current_name() == "main.rs" and true
    end)
    t:feed(":only<CR>") -- collapse to a single main window (window A = main.rs)
    t:feed(":vsplit<CR>") -- window B, still on main.rs…
    t:feed(":edit " .. readme .. "<CR>") -- …now on readme.txt (the current window)
    t:wait_for(function()
      return current_name() == "readme.txt" and count_showing("main.rs") == 1 and true
    end)

    -- Reveal main.rs in the tree (focuses the sidebar, cursor on its node) and open it.
    -- reuse must FOCUS window A, leaving window B (readme.txt) untouched — never
    -- reloading main.rs into window B (which would clobber readme.txt).
    tree.reveal(main_rs)
    t:wait_for(function()
      return vim.api.nvim_get_current_buf() == tree.bufnr() and true
    end)
    t:feed("<CR>")
    local jumped = t:wait_for(function()
      return current_name() == "main.rs" and count_showing("readme.txt") == 1 and true
    end)
    btv.test.expect(jumped).to_be_truthy()
    btv.test.expect(count_showing("main.rs")).to_be(1) -- no duplicate window
    btv.test.expect(count_showing("readme.txt")).to_be(1) -- readme.txt not clobbered
  end)

  -- The header and opened files are normalized relative to the cwd: with the cwd set to
  -- the root, the header is the cwd's basename (not the absolute path) and an opened file
  -- carries a cwd-relative buffer name. Restores the cwd so later tests are unaffected.
  btv.test.it("shows the root and opens files relative to the cwd", function(t)
    local prev = vim.fn.getcwd()
    vim.cmd("cd " .. ROOT)
    -- `:cd` drains at end-of-tick; wait until getcwd mirrors the new dir before reading it.
    -- The editor canonicalizes the cwd, so on macOS the tempdir's `/var/folders` symlink
    -- resolves to `/private/var/...` and getcwd never equals ROOT verbatim — accept either
    -- the tempdir path or its realpath, and use whatever getcwd actually reports downstream.
    local root_real = btv.await(fs.realpath(ROOT))
    local cwd = t:wait_for(function()
      local c = vim.fn.getcwd()
      return (c == ROOT or c == root_real) and c
    end)
    tree.destroy()
    tree.setup({ root = cwd, watch = false, toggle_key = false })
    open_ready(t)

    local header = btv.buf.lines(tree.bufnr(), 0, 1, false)[1]
    btv.test.expect(header).to_contain(vim.fn.fnamemodify(cwd, ":t"))
    btv.test.expect(header).never.to_contain(cwd)

    t:feed("j"):feed("<CR>") -- expand src/
    wait_contains(t, "main.rs")
    t:feed("j"):feed("<CR>") -- open main.rs
    -- The opened buffer's stored name is cwd-relative, not the absolute path.
    local name = t:wait_for(function()
      local n = vim.fn.expand("%")
      return n ~= "" and n:find("main.rs", 1, true) and n
    end)
    btv.test.expect(name).to_be("src/main.rs")

    vim.cmd("cd " .. prev)
  end)

  -- The combination the bundled example uses (git + follow + open_on_start) must
  -- build cleanly — git.enable shells out, follow wires an autocmd, open_on_start
  -- opens during setup. A non-git tempdir leaves the tree unmarked but errorless.
  btv.test.it("builds with git + follow + open_on_start (the example config)", function(t)
    tree.destroy()
    tree.setup({
      root = ROOT,
      watch = false,
      toggle_key = false,
      git = true,
      follow = true,
      open_on_start = true,
    })
    btv.test.expect(wait_contains(t, "readme.txt")).to_contain("readme.txt")
  end)

  -- A re-render (watch fire, refresh, BufEnter) must repaint the decoration — the
  -- indent guides, icon/name highlights, and git signs — in the SAME tick it replaces
  -- the lines, never a tick later, or the tree flashes undecorated on every update.
  -- With the buffer already mounted the marks go on synchronously: wipe the namespace,
  -- re-render, and assert the marks are back without yielding a tick.
  btv.test.it("repaints decoration synchronously on re-render (no flicker)", function(t)
    open_ready(t)
    local state = tree.api.state()
    local buf = state.view:bufnr()
    -- The first render decorated the lines.
    t:wait_for(function()
      return #btv.buf.extmarks(buf, state.ns, 0, -1) > 0
    end)
    -- Wipe the decoration and re-render; the marks must reappear in this same chunk.
    btv.buf.clear_namespace(buf, state.ns, 0, -1)
    require("bemtvi-tree.render").render(state, { restore_cursor = false })
    btv.test.expect(#btv.buf.extmarks(buf, state.ns, 0, -1)).never.to_be(0)
  end)

  -- The auto-refresh watch is per-EXPANDED-directory, not one recursive watch over the
  -- whole tree: only directories whose contents are visible are watched, so a large
  -- collapsed subtree costs nothing (and on macOS — where the backend is kqueue, one fd
  -- per watched path — a recursive whole-tree watch would exhaust file descriptors).
  -- Expanding a directory arms its watch; collapsing it drops the watch again.
  btv.test.it("watches only expanded directories, arming/dropping on expand/collapse", function(t)
    tree.destroy()
    tree.setup({ root = ROOT, watch = true, toggle_key = false })
    open_ready(t)

    local src = model.join(ROOT, "src")
    local function watched()
      local set = {}
      for _, p in ipairs(tree._watched_paths()) do
        set[p] = true
      end
      return set
    end

    -- Initially only the root is expanded → only the root is watched; src/ is collapsed.
    t:wait_for(function()
      local w = watched()
      return w[ROOT] and not w[src]
    end)

    -- Expand src/ → its watch arms.
    t:feed("j"):feed("<CR>")
    wait_contains(t, "main.rs")
    t:wait_for(function()
      return watched()[src]
    end)

    -- Collapse src/ → its watch drops; the root's stays.
    t:feed("<CR>")
    t:wait_for(function()
      local w = watched()
      return w[ROOT] and not w[src]
    end)
    btv.test.expect(watched()[src]).to_be_falsy()
  end)

  -- The per-directory watch isn't just placed — it fires: a file created on disk
  -- directly inside an expanded directory re-scans that one directory and shows up
  -- without any manual refresh. (Sleeps a beat first to let the native watcher actually
  -- arm before the write, mirroring the server's own fs-watch test.)
  btv.test.it("auto-refreshes an expanded directory on a disk change", function(t)
    tree.destroy()
    tree.setup({ root = ROOT, watch = true, toggle_key = false })
    open_ready(t)
    t:feed("j"):feed("<CR>") -- expand src/
    wait_contains(t, "main.rs")

    local src = model.join(ROOT, "src")
    t:wait_for(function() -- the src/ watch handle exists in Lua…
      for _, p in ipairs(tree._watched_paths()) do
        if p == src then
          return true
        end
      end
    end)
    t:sleep(200) -- …give the native backend a beat to actually arm before we change disk

    btv.await(fs.write(model.join(ROOT, "src/extra.rs"), ""))
    btv.test.expect(wait_contains(t, "extra.rs")).to_contain("extra.rs")
  end)

  -- Mouse support. The editor's native <LeftMouse> default places the view cursor on
  -- the clicked node *before* the mapped body runs (covered by the server's own
  -- mouse.rs), so the click actions read `current(tree)` like any keyboard action. We
  -- drive them the same way: move the cursor with a real motion, then invoke the body
  -- the config wires to the mouse key. A double click fires mouse_click then mouse_open.
  local actions = require("bemtvi-tree.actions")

  btv.test.it("wires the default left-click mappings", function()
    local d = require("bemtvi-tree.config").defaults()
    btv.test.expect(d.mappings["<LeftMouse>"]).to_be("mouse_click")
    btv.test.expect(d.mappings["<2-LeftMouse>"]).to_be("mouse_open")
  end)

  btv.test.it("single-clicks a directory to expand and collapse it (mouse_click)", function(t)
    open_ready(t)
    local state = tree.api.state()
    t:feed("j") -- cursor onto src/ (a real click lands here via the native default)
    actions.mouse_click(state, tree.api) -- single click expands the directory
    btv.test.expect(wait_contains(t, "main.rs")).to_contain("main.rs")
    actions.mouse_click(state, tree.api) -- a second single click collapses it
    local gone = t:wait_for(function()
      return not buf_text():find("main.rs", 1, true)
    end)
    btv.test.expect(gone).to_be_truthy()
  end)

  btv.test.it("single-click on a file does NOT open it (mouse_click)", function(t)
    open_ready(t)
    local state = tree.api.state()
    t:feed("j"):feed("j") -- root(1) → src/(2) → readme.txt(3)
    actions.mouse_click(state, tree.api) -- a single click on a file is a no-op
    t:feed("") -- settle a tick
    -- Focus never left the tree: the active buffer is not the file.
    btv.test.expect(vim.fn.expand("%:p"):find("readme.txt", 1, true)).to_be_nil()
  end)

  btv.test.it("double-clicks a file to open it in the main editor (mouse_open)", function(t)
    open_ready(t)
    local state = tree.api.state()
    t:feed("j") -- onto src/
    actions.mouse_click(state, tree.api) -- expand it (the double-click's first press)
    wait_contains(t, "main.rs")
    t:feed("j") -- onto main.rs (root1 src2 main.rs3)
    actions.mouse_open(state, tree.api) -- the second press opens the file
    local opened = t:wait_for(function()
      local name = vim.fn.expand("%:p")
      return name:find("main.rs", 1, true) and name
    end)
    btv.test.expect(opened).to_contain("main.rs")
  end)

  -- A double click on a DIRECTORY must toggle it exactly once: the first press
  -- (mouse_click) expands it, the second (mouse_open, file-only) ignores it. The two
  -- gestures never both act on one node, so the directory ends up expanded, not flicked
  -- open-then-shut.
  btv.test.it("double-click on a directory toggles it once (gestures don't overlap)", function(t)
    open_ready(t)
    local state = tree.api.state()
    t:feed("j") -- onto src/
    actions.mouse_click(state, tree.api) -- first press: expand
    actions.mouse_open(state, tree.api) -- second press: file-only → ignores the dir
    btv.test.expect(wait_contains(t, "main.rs")).to_contain("main.rs")
  end)

  -- Right-click context menu. A mapped <RightMouse> does NOT move the cursor, so
  -- mouse_menu resolves the clicked node from btv.getmousepos() and pops an btv.ui.select
  -- of operations for it. menu_for builds that list (context-dependent), and the chosen
  -- entry dispatches a built-in action — so we check both the composition and one full
  -- pop-and-run flow.

  -- Find the node for a name in the current flat list (the render's userdata order).
  local function node_named(name)
    for _, n in ipairs(tree.api.state().flat) do
      if n.name == name or n.name:match("[^/]+$") == name then
        return n
      end
    end
  end

  -- The set of labels menu_for offers for `node`.
  local function menu_labels(node)
    local labels = {}
    for _, it in ipairs(actions._menu_for(tree.api.state(), node)) do
      labels[it.label] = true
    end
    return labels
  end

  btv.test.it("wires <RightMouse> to the context menu", function()
    local d = require("bemtvi-tree.config").defaults()
    btv.test.expect(d.mappings["<RightMouse>"]).to_be("mouse_menu")
  end)

  btv.test.it("offers file ops for a file and dir ops for a directory", function(t)
    open_ready(t)
    local file = menu_labels(node_named("readme.txt"))
    btv.test.expect(file["Open"]).to_be_truthy()
    btv.test.expect(file["Open in split"]).to_be_truthy()
    btv.test.expect(file["Rename…"]).to_be_truthy()
    btv.test.expect(file["Delete…"]).to_be_truthy()
    btv.test.expect(file["Expand"]).to_be_falsy() -- a file is not expandable

    local dir = menu_labels(node_named("src"))
    btv.test.expect(dir["Expand"]).to_be_truthy()
    btv.test.expect(dir["New file / directory…"]).to_be_truthy()
    btv.test.expect(dir["Set as root"]).to_be_truthy()
    btv.test.expect(dir["Open in split"]).to_be_falsy() -- you don't "open" a directory
  end)

  btv.test.it("omits rename/delete on the root and shows paste only with a clipboard", function(t)
    open_ready(t)
    local state = tree.api.state()
    local root = menu_labels(state.root)
    btv.test.expect(root["Rename…"]).to_be_falsy() -- the root has no parent to rename within
    btv.test.expect(root["Delete…"]).to_be_falsy()
    btv.test.expect(root["Paste"]).to_be_falsy() -- nothing on the clipboard yet

    state._clipboard = { node = node_named("readme.txt"), op = "copy" }
    btv.test.expect(menu_labels(state.root)["Paste"]).to_be_truthy()
  end)

  btv.test.it("every menu entry names a real action (no dangling dispatch)", function(t)
    open_ready(t)
    local state = tree.api.state()
    state._clipboard = { node = node_named("readme.txt"), op = "copy" } -- surface Paste too
    for _, node in ipairs({ state.root, node_named("src"), node_named("readme.txt") }) do
      for _, it in ipairs(actions._menu_for(state, node)) do
        btv.test.expect(type(actions[it.action])).to_be("function")
      end
    end
  end)

  -- The full gesture: right-click src/ → the menu pops → confirming its first entry
  -- ("Expand") expands the clicked directory. The cursor starts on the root, so the op
  -- landing on src/ proves the menu used the CLICKED cell (getmousepos), not the cursor.
  btv.test.it("pops the menu on right-click and runs the chosen op on the clicked node", function(t)
    open_ready(t)
    local state = tree.api.state()
    state.view:set_cursor(1) -- cursor on the root, not on src/
    -- Stand in for the server's mouse mirror: a right-click on src/ (flat line 2). The
    -- real signal is identical — getmousepos() reads exactly this mirror.
    btv._mouse_pos = { winid = state.view:winid(), line = 2 }
    tree.api.run(function()
      actions.mouse_menu(state, tree.api)
    end)
    t:feed("", { settle = 2 }) -- let the set_cursor + select-open ops drain
    -- `btv.ui.select` opens NOSELECT (like the completion popup / wildmenu): with nothing
    -- highlighted a bare <CR> is inert, by design. Navigate onto the first entry
    -- ("Expand"), then confirm it — the two beats a keyboard user performs (a click on
    -- the row does both at once).
    t:feed("j")
    t:feed("<CR>")
    btv.test.expect(wait_contains(t, "main.rs")).to_contain("main.rs")
  end)

  btv.test.it("changes the root with `>` and ascends with `<`", function(t)
    open_ready(t)
    t:feed("j") -- onto src/
    t:feed(">") -- src becomes the root
    -- The header is now the src path and main.rs is a top-level entry.
    local txt = wait_contains(t, "main.rs")
    btv.test.expect(txt).to_contain(model.join(ROOT, "src"))
    btv.test.expect(txt).never.to_contain("readme.txt")
    -- Ascend back to the original root.
    t:feed("<")
    btv.test.expect(wait_contains(t, "readme.txt")).to_contain("readme.txt")
  end)

  -- Cross-session persistence: the plugin stashes a snapshot (root + expanded dirs +
  -- cursor) in its own shada slice on every structural change / cursor move, and rebuilds
  -- the sidebar from it on restore. This drives the CONTENT half of that path in-process
  -- (the window-adoption half is covered by the server session tests): expand a dir, read
  -- back the saved snapshot, then rebuild from it and assert the dir comes back open.
  btv.test.it("persists the expanded set + cursor and restores them across a rebuild", function(t)
    open_ready(t)
    t:feed("j") -- move the cursor onto src/
    t:feed("<CR>") -- expand src/
    wait_contains(t, "main.rs")

    -- The snapshot records the root, src/ among the expanded dirs, and the cursor's node.
    local snap = tree._session()
    btv.test.expect(type(snap)).to_be("table")
    btv.test.expect(snap.root).to_be(ROOT)
    btv.test.expect(snap.expanded).to_contain(model.join(ROOT, "src"))
    btv.test.expect(snap.cursor).to_be(model.join(ROOT, "src"))

    -- Rebuilding from that snapshot (the content half of on_restore) brings src/ back
    -- expanded — main.rs shows without a manual expand.
    tree._restore(snap)
    btv.test.expect(wait_contains(t, "main.rs")).to_contain("main.rs")
  end)

  -- The dotfile toggle (H) is session state too, not just static config: it flips
  -- `config.hidden`, and a fresh session's setup() re-merges that field back to the
  -- configured default. So the snapshot has to carry it, or a restore silently drops
  -- the user's choice.
  btv.test.it("persists the hidden-files toggle and restores it across a rebuild", function(t)
    open_ready(t)
    t:feed("H") -- dotfiles are shown by default, so this HIDES them
    t:wait_for(function()
      return not buf_text():find(".secret", 1, true)
    end)
    btv.test.expect(tree._session().hidden).to_be(false)

    -- A new session re-merges the config from the defaults, so `hidden` is back to true
    -- here — the snapshot is what has to bring the toggle back.
    tree.setup({ root = ROOT, watch = false, toggle_key = false })
    btv.test.expect(tree.config.hidden).to_be(true)
    tree._restore(tree._session())
    t:wait_for(function()
      return buf_text():find("readme.txt", 1, true) and not buf_text():find(".secret", 1, true)
    end)
    btv.test.expect(buf_text()).never.to_contain(".secret")

    -- And toggling back on persists the on state (not just "false once written").
    tree.focus()
    t:wait_for(function()
      return tree._ready()
    end)
    t:feed("H")
    wait_contains(t, ".secret")
    btv.test.expect(tree._session().hidden).to_be(true)
  end)

  -- ----- glob filters (btv.glob) ---------------------------------------------
  --
  -- `filters` is a list of shell/gitignore-style globs matched by `btv.glob` against each
  -- entry's path relative to the tree root. The two matching rules the option documents
  -- get a test each: separator-less patterns hit the basename at any depth, patterns with
  -- a separator are anchored at the root.

  btv.test.it("hides entries matching a separator-less filter glob, at any depth", function(t)
    tree.destroy()
    btv.await(fs.write(model.join(ROOT, "notes.bak"), ""))
    btv.await(fs.write(model.join(ROOT, "src/main.bak"), ""))
    tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = { "*.bak" } })
    open_ready(t)
    t:feed("j"):feed("<CR>") -- expand src/
    wait_contains(t, "main.rs")

    local txt = buf_text()
    btv.test.expect(txt).to_contain("readme.txt")
    btv.test.expect(txt).to_contain("main.rs")
    btv.test.expect(txt).never.to_contain("notes.bak") -- root level
    btv.test.expect(txt).never.to_contain("main.bak") -- and nested, with no `**/` needed
  end)

  -- Both `vendor` directories render as the same text, so these two assert on the model's
  -- flat node PATHS instead of the buffer text — the anchor's whole point is telling two
  -- identically-named entries apart.
  local function vendor_tree(t, filters)
    tree.destroy()
    btv.await(fs.mkdir(model.join(ROOT, "vendor")))
    btv.await(fs.write(model.join(ROOT, "vendor/dep.rs"), ""))
    btv.await(fs.mkdir(model.join(ROOT, "src/vendor")))
    btv.await(fs.write(model.join(ROOT, "src/vendor/keep.rs"), ""))
    tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = filters })
    open_ready(t)
    -- Expand every directory (`E`) so a surviving subtree really is in the flat list;
    -- a collapsed one would look "filtered" without being.
    t:feed("E")
    t:wait_for(function()
      return #(tree.api.state().flat or {}) > 4
    end)
    local paths = {}
    for _, n in ipairs(tree.api.state().flat) do
      paths[n.path] = true
    end
    return paths
  end

  -- A LEADING "/" anchors to the tree root (gitignore's rule), and matching a directory
  -- takes its whole subtree — so `/vendor` needs no `/**` tail and, unlike the bare name,
  -- leaves a nested `vendor/` alone.
  btv.test.it("anchors a filter glob written with a leading slash", function(t)
    local paths = vendor_tree(t, { "/vendor" })
    -- The root's vendor/ is gone, and its child with it…
    btv.test.expect(paths[model.join(ROOT, "vendor")]).to_be_nil()
    btv.test.expect(paths[model.join(ROOT, "vendor/dep.rs")]).to_be_nil()
    -- …while src/vendor/ — the same NAME, a different path — survives the anchor.
    btv.test.expect(paths[model.join(ROOT, "src/vendor")]).to_be(true)
    btv.test.expect(paths[model.join(ROOT, "src/vendor/keep.rs")]).to_be(true)
  end)

  -- The unanchored spelling of the same name hits at every depth instead.
  btv.test.it("matches a bare filter name at any depth", function(t)
    local paths = vendor_tree(t, { "vendor" })
    btv.test.expect(paths[model.join(ROOT, "vendor")]).to_be_nil()
    btv.test.expect(paths[model.join(ROOT, "src/vendor")]).to_be_nil()
    btv.test.expect(paths[model.join(ROOT, "src/vendor/keep.rs")]).to_be_nil()
    btv.test.expect(paths[model.join(ROOT, "src/main.rs")]).to_be(true)
  end)

  -- `U` suspends and re-applies the set. It is a render-time filter over already-loaded
  -- nodes, so the hidden entries come back with no filesystem round-trip — and the
  -- on/off choice persists across a rebuild like `H` does.
  btv.test.it("toggles the filters with `U` and persists the choice", function(t)
    tree.destroy()
    btv.await(fs.write(model.join(ROOT, "notes.bak"), ""))
    tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = { "*.bak" } })
    open_ready(t)
    btv.test.expect(buf_text()).never.to_contain("notes.bak")

    t:feed("U") -- suspend
    wait_contains(t, "notes.bak")
    btv.test.expect(tree.config.filters_enabled).to_be(false)
    btv.test.expect(tree._session().filters_enabled).to_be(false)

    -- A rebuild re-merges the config (filters_enabled back to true); the snapshot is
    -- what has to bring the suspension back.
    local saved = tree._session()
    tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = { "*.bak" } })
    btv.test.expect(tree.config.filters_enabled).to_be(true)
    tree._restore(saved)
    wait_contains(t, "notes.bak")
  end)

  -- The `filters` list itself is config, never persisted: a snapshot from a session that
  -- had filters must not keep filtering after the user edits them out of setup().
  btv.test.it("persists the filters switch but never the patterns", function(t)
    tree.destroy()
    btv.await(fs.write(model.join(ROOT, "notes.bak"), ""))
    tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = { "*.bak" } })
    open_ready(t)
    btv.test.expect(buf_text()).never.to_contain("notes.bak")
    local saved = tree._session()
    btv.test.expect(saved.filters).to_be_nil()

    tree.setup({ root = ROOT, watch = false, toggle_key = false }) -- filters removed
    tree._restore(saved)
    wait_contains(t, "notes.bak")
  end)

  -- `U` over an empty set would flip (and persist) a switch that suppresses the filters
  -- the day some get configured, so it refuses instead.
  btv.test.it("refuses to toggle filters when none are configured", function(t)
    open_ready(t)
    t:feed("U")
    t:feed("")
    btv.test.expect(tree.config.filters_enabled).to_be(true)
  end)

  -- An invalid glob is a setup() mistake, reported from setup() rather than swallowed
  -- until the next repaint.
  btv.test.it("rejects a bad filter glob from setup()", function()
    btv.test
      .expect(function()
        tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = { "a{b" } })
      end)
      .to_error("filters")
    btv.test
      .expect(function()
        tree.setup({ root = ROOT, watch = false, toggle_key = false, filters = { 7 } })
      end)
      .to_error("filters[1]")
  end)

  -- A stale snapshot naming a directory since deleted on disk must not sink the whole
  -- restore: the missing dir is skipped, the rest of the tree still renders.
  btv.test.it("tolerates a stale snapshot whose expanded dir has vanished", function(t)
    open_ready(t)
    tree._restore({
      root = ROOT,
      expanded = { ROOT, model.join(ROOT, "does-not-exist"), model.join(ROOT, "src") },
      cursor = model.join(ROOT, "src"),
    })
    -- src/ still expands (main.rs shows); the bogus path was silently skipped.
    btv.test.expect(wait_contains(t, "main.rs")).to_contain("main.rs")
  end)

  -- Sidebar chrome (like nvim-tree): the tree window remaps Normal→NvimTreeNormal
  -- (its own darker background) and turns on `cursorline` to highlight the row. The
  -- background remap rides the dock (so it survives parking/restore); cursorline is
  -- a window option on the tree window itself.
  btv.test.it("gives the sidebar a dark background (winhighlight) and cursorline", function(t)
    open_ready(t)
    local view = tree.api.state().view
    local win = t:wait_for(function()
      return view:winid()
    end)
    -- The window option is applied a tick after mount (winid settles cross-tick).
    t:wait_for(function()
      return btv.wo[win].cursorline == true
    end)
    btv.test.expect(btv.wo[win].cursorline).to_be_truthy()
    -- The dock carries the Normal→NvimTreeNormal remap (read back from its opt cache;
    -- the default tree position is "left").
    local whl = btv.dock.opt("left").winhighlight or ""
    btv.test.expect(whl:find("Normal:NvimTreeNormal", 1, true)).to_be_truthy()
    btv.test.expect(whl:find("EndOfBuffer:NvimTreeEndOfBuffer", 1, true)).to_be_truthy()
  end)
end)
