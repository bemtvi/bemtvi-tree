-- The git presentation, end to end against a REAL repository: the status tints the
-- entry's NAME (never shifting its start column), the sign gutter is pinned open inside a
-- repo and left alone outside one, and git-ignored entries dim or hide per `git_ignored`
-- with the `I` toggle persisting across sessions. Run with `nxvim --test-plugin`.
--
-- The editor itself never shells out to git (it runs gix in-process via `nx.git`); only
-- these fixtures do, the same convention as the nxvim repo's own `tests/git.rs`. `git`
-- must be on PATH — absent, the suite skips loud rather than failing.
--
-- Reading decoration back: the render paints one extmark per styled range under the
-- tree's namespace, so `nx.buf.extmarks(buf, ns, 0, -1, { details = true })` is the
-- ground truth for "what colour is this name, and did anything shift it".

local tree = require("nxvim-tree")
local model = require("nxvim-tree.model")

local ROOT
local have_git = false

-- Run `git` in ROOT with a fixed identity and no host config bleeding in.
local function git(...)
  local r = nx.await(nx.run({
    cmd = "git",
    args = { ... },
    cwd = ROOT,
    env = {
      GIT_CONFIG_GLOBAL = "/dev/null",
      GIT_CONFIG_SYSTEM = "/dev/null",
      GIT_AUTHOR_NAME = "nxvim test",
      GIT_AUTHOR_EMAIL = "test@nxvim",
      GIT_COMMITTER_NAME = "nxvim test",
      GIT_COMMITTER_EMAIL = "test@nxvim",
    },
  }))
  if r.code ~= 0 then
    error("git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(r.stderr))
  end
  return r.stdout
end

local function buf_text()
  local b = tree.bufnr()
  if not b then
    return ""
  end
  return table.concat(nx.buf.lines(b, 0, -1, false), "\n")
end

local function wait_contains(t, needle)
  return t:wait_for(function()
    local txt = buf_text()
    return txt:find(needle, 1, true) and txt
  end)
end

-- The line index (1-based) whose node path ends with `name`, or nil.
local function line_of(name)
  local state = tree.api.state()
  for i, n in ipairs(state and state.flat or {}) do
    if n.path:sub(-#name) == name then
      return i
    end
  end
end

-- Every detailed extmark on the row showing `name`.
local function marks_on(name)
  local state = tree.api.state()
  local i = line_of(name)
  if not i then
    return {}
  end
  local out = {}
  for _, m in ipairs(nx.buf.extmarks(state.view:bufnr(), state.ns, 0, -1, { details = true })) do
    if m[2] == i - 1 then
      out[#out + 1] = { col = m[3], details = m[4] }
    end
  end
  return out
end

-- The hl groups painted over the NAME range of `name`'s row. The name starts after
-- "<guides><glyph> ", so any mark whose start column is at/after the glyph+space is a
-- name-range mark; the guide and icon marks start before it.
local function name_hls(name)
  local state = tree.api.state()
  local i = line_of(name)
  if not i then
    return {}
  end
  local text = nx.buf.lines(state.view:bufnr(), i - 1, i, false)[1] or ""
  -- Where the basename begins in the rendered line (it is the line's tail).
  local base = name:match("[^/]+$")
  local at = text:find(base, 1, true)
  local out = {}
  for _, m in ipairs(marks_on(name)) do
    if at and m.col == at - 1 and m.details and m.details.hl_group then
      out[#out + 1] = m.details.hl_group
    end
  end
  return out
end

-- Open the tree, wait for the first render + the action maps, then focus it.
local function open_ready(t)
  tree.open()
  wait_contains(t, "tracked.txt")
  t:wait_for(function()
    return tree._ready()
  end)
  tree.focus()
  t:feed("")
end

-- Wait until the git module's first status has landed (`tree._git` is published only on a
-- successful discover+status, so this is also the "we are in a repo" signal).
local function wait_git(t)
  return t:wait_for(function()
    local state = tree.api.state()
    return state and state._git and state._git.root
  end)
end

nx.test.describe("nxvim-tree git presentation", function()
  nx.test.before_each(function()
    tree.destroy()
    vim.g.mapleader = " "
    ROOT = nx.test.tempdir()
    have_git = nx.await(nx.run({ cmd = "git", args = { "--version" } })).code == 0
    if not have_git then
      return
    end
    -- A repo with: a committed+modified file, an untracked file, an ignored file, and a
    -- wholly-ignored directory (which the engine reports COLLAPSED, as one entry).
    nx.await(nx.fs.write(model.join(ROOT, "tracked.txt"), "a\n"))
    -- A committed file left ALONE: the clean baseline the "nothing shifted" comparison
    -- measures against (`.gitignore` can't serve — it's a dotfile, hidden by default).
    nx.await(nx.fs.write(model.join(ROOT, "clean.txt"), "untouched\n"))
    nx.await(nx.fs.write(model.join(ROOT, ".gitignore"), "*.log\nbuild\n"))
    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("commit", "-q", "-m", "initial")
    nx.await(nx.fs.write(model.join(ROOT, "tracked.txt"), "a\nb\n")) -- now modified
    nx.await(nx.fs.write(model.join(ROOT, "fresh.txt"), "new\n")) -- untracked
    nx.await(nx.fs.write(model.join(ROOT, "noise.log"), "x\n")) -- ignored
    nx.await(nx.fs.mkdir(model.join(ROOT, "build")))
    nx.await(nx.fs.write(model.join(ROOT, "build/out.o"), "x")) -- ignored via its dir
    tree.setup({ root = ROOT, watch = false, toggle_key = false, git = true })
  end)

  nx.test.after_each(function()
    tree.destroy()
  end)

  -- The core of the request: status shows as the NAME's colour. A modified file's name
  -- carries NvimTreeGitDirty, an untracked one NvimTreeGitNew — and the name still starts
  -- at exactly the same column as a clean file's, because nothing was inserted.
  nx.test.it("tints the entry NAME by git status without moving it", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    open_ready(t)
    wait_git(t)
    t:wait_for(function()
      local hls = name_hls("tracked.txt")
      return hls[1] and hls
    end)
    nx.test.expect(name_hls("tracked.txt")).to_contain("NvimTreeGitDirty")
    nx.test.expect(name_hls("fresh.txt")).to_contain("NvimTreeGitNew")

    -- The name's start column is identical on a changed row and a clean one: the status
    -- rides colour + the gutter, never an inserted character.
    local state = tree.api.state()
    local function name_col(name)
      local i = line_of(name)
      local text = nx.buf.lines(state.view:bufnr(), i - 1, i, false)[1] or ""
      return text:find(name:match("[^/]+$"), 1, true)
    end
    nx.test.expect(name_col("tracked.txt")).to_be(name_col("clean.txt"))
    nx.test.expect(name_col("fresh.txt")).to_be(name_col("clean.txt"))
    -- …and the clean file carries no git tint at all.
    nx.test.expect(name_hls("clean.txt")).never.to_contain("NvimTreeGitDirty")
  end)

  -- The changed states still carry their gutter sign (the user asked to keep it), and the
  -- gutter is PINNED OPEN so it can't slide the tree sideways as statuses come and go.
  nx.test.it("keeps the gutter sign and reserves the gutter inside a repo", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    open_ready(t)
    wait_git(t)
    local signed = t:wait_for(function()
      for _, m in ipairs(marks_on("tracked.txt")) do
        if m.details and m.details.sign_text then
          return m.details.sign_text
        end
      end
    end)
    nx.test.expect(signed).to_be("~")

    local win = tree.api.state().view:winid()
    t:wait_for(function()
      return nx.wo[win].signcolumn == "yes"
    end)
    -- One always-present column ("yes" is how `yes:1` reads back).
    nx.test.expect(nx.wo[win].signcolumn).to_be("yes")
  end)

  -- …but ONLY inside a repo: outside one no sign can ever appear, so reserving the column
  -- would just waste a column of a narrow sidebar. The tree keeps the editor's default.
  nx.test.it("leaves the gutter at the default outside a git repo", function(t)
    tree.destroy()
    local plain = nx.test.tempdir()
    nx.await(nx.fs.write(model.join(plain, "tracked.txt"), "hi"))
    tree.setup({ root = plain, watch = false, toggle_key = false, git = true })
    open_ready(t)
    -- Give the git module's discover every chance to reject (ENOREPO) and settle.
    t:wait_for(function()
      return tree.api.state().view:winid()
    end)
    for _ = 1, 20 do
      t:feed("")
    end
    nx.test.expect(tree.api.state()._git).to_be(nil)
    nx.test.expect(nx.wo[tree.api.state().view:winid()].signcolumn).never.to_be("yes")
  end)

  -- The decorator needs NO opt-in: a bare setup() inside a repository already colours the
  -- tree. (Every other test here passes `git = true` explicitly; this one is the guard that
  -- the DEFAULT carries it, so a user who never read the option list still gets status.)
  nx.test.it("decorates by default, with no `git` option at all", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    tree.destroy()
    tree.setup({ root = ROOT, watch = false, toggle_key = false })
    nx.test.expect(tree.config.git).to_be(true)
    open_ready(t)
    wait_git(t)
    t:wait_for(function()
      local hls = name_hls("tracked.txt")
      return hls[1] and hls
    end)
    nx.test.expect(name_hls("tracked.txt")).to_contain("NvimTreeGitDirty")
    nx.test.expect(name_hls("noise.log")).to_contain("NvimTreeGitIgnored")
  end)

  -- The repository's own `.git` reads as ignored: dimmed with everything else, and dropped
  -- by `git_ignored = "hide"`. It shows at all only because dotfiles are visible by
  -- default — which is precisely why it needs the treatment.
  nx.test.it("dims the .git directory and hides it with the ignored entries", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    open_ready(t)
    wait_git(t)
    wait_contains(t, ".git/")
    -- Wait for the GROUP, not for "any highlight": a directory row already carries
    -- NvimTreeFolderName before the decorator's first repaint lands.
    t:wait_for(function()
      for _, h in ipairs(name_hls(".git")) do
        if h == "NvimTreeGitIgnored" then
          return true
        end
      end
    end)
    nx.test.expect(name_hls(".git")).to_contain("NvimTreeGitIgnored")

    t:feed("I") -- → hide
    local hidden = t:wait_for(function()
      local txt = buf_text()
      return not txt:find(".git/", 1, true) and txt
    end)
    nx.test.expect(hidden).never.to_contain(".git/")
    nx.test.expect(hidden).to_contain("tracked.txt")
  end)

  -- With the decorator opted out there is no ignored set to act on, so `I` must not
  -- pretend: it warns and leaves the mode alone rather than persisting a preference the
  -- user can never see take effect.
  nx.test.it("leaves git_ignored alone when `git = false`", function(t)
    tree.destroy()
    tree.setup({ root = ROOT, watch = false, toggle_key = false, git = false })
    open_ready(t)
    t:feed("I")
    for _ = 1, 20 do
      t:feed("")
    end
    nx.test.expect(tree.config.git_ignored).to_be("dim")
    nx.test.expect(tree._session().git_ignored).to_be("dim")
  end)

  -- …and `git = false` is a real opt-out: no status is ever fetched, so nothing is tinted
  -- and no repo state is published (which is also what keeps the gutter unreserved).
  nx.test.it("opts out of git entirely with `git = false`", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    tree.destroy()
    tree.setup({ root = ROOT, watch = false, toggle_key = false, git = false })
    open_ready(t)
    -- Give a status every chance to land had one been fetched at all.
    for _ = 1, 20 do
      t:feed("")
    end
    nx.test.expect(tree.api.state()._git).to_be(nil)
    nx.test.expect(name_hls("tracked.txt")).never.to_contain("NvimTreeGitDirty")
    nx.test.expect(name_hls("noise.log")).never.to_contain("NvimTreeGitIgnored")
  end)

  -- Ignored entries dim by default — including every file under a collapsed ignored
  -- directory, which is what `is_ignored`'s prefix walk buys.
  nx.test.it("dims git-ignored entries, directory and descendants alike", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    open_ready(t)
    wait_git(t)
    t:wait_for(function()
      local hls = name_hls("noise.log")
      return hls[1] and hls
    end)
    nx.test.expect(name_hls("noise.log")).to_contain("NvimTreeGitIgnored")
    nx.test.expect(name_hls("build")).to_contain("NvimTreeGitIgnored")
    -- An ignored entry gets NO gutter sign (dimming is the whole signal).
    for _, m in ipairs(marks_on("noise.log")) do
      nx.test.expect(m.details and m.details.sign_text).to_be(nil)
    end

    -- Expand the ignored directory: its contents are ignored too, via the collapsed entry.
    tree.api.state() -- (the tree is focused; move onto build/ and open it)
    local i = line_of("build")
    tree.api.state().view:set_cursor(i)
    t:feed("<CR>")
    wait_contains(t, "out.o")
    nx.test.expect(name_hls("out.o")).to_contain("NvimTreeGitIgnored")
  end)

  -- `I` flips dim → hide → dim, and hiding drops the ignored rows from the tree without
  -- touching the tracked ones. It is a render-time filter, so it needs no fs re-read.
  nx.test.it("toggles ignored entries between dimmed and hidden with I", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    open_ready(t)
    wait_git(t)
    wait_contains(t, "noise.log")

    t:feed("I")
    local hidden = t:wait_for(function()
      local txt = buf_text()
      return not txt:find("noise.log", 1, true) and txt
    end)
    nx.test.expect(hidden).never.to_contain("noise.log")
    nx.test.expect(hidden).never.to_contain("build")
    -- The real entries are untouched.
    nx.test.expect(hidden).to_contain("tracked.txt")
    nx.test.expect(hidden).to_contain("fresh.txt")
    nx.test.expect(tree.config.git_ignored).to_be("hide")

    -- And back again.
    t:feed("I")
    nx.test.expect(wait_contains(t, "noise.log")).to_contain("noise.log")
    nx.test.expect(tree.config.git_ignored).to_be("dim")
  end)

  -- The toggle is a preference, so it rides the session snapshot exactly like the dotfile
  -- toggle: a fresh session's config merge would otherwise reset it to the default.
  nx.test.it("persists the ignored-mode toggle across a rebuild", function(t)
    if not have_git then
      return nx.notify("skip: git not on PATH")
    end
    open_ready(t)
    wait_git(t)
    t:feed("I")
    t:wait_for(function()
      return tree.config.git_ignored == "hide"
    end)
    nx.test.expect(tree._session().git_ignored).to_be("hide")

    -- A new session re-merges from the defaults ("dim"); the snapshot brings it back.
    tree.setup({ root = ROOT, watch = false, toggle_key = false, git = true })
    nx.test.expect(tree.config.git_ignored).to_be("dim")
    tree._restore(tree._session())
    t:wait_for(function()
      return tree.config.git_ignored == "hide"
    end)
    nx.test.expect(tree.config.git_ignored).to_be("hide")
  end)
end)
