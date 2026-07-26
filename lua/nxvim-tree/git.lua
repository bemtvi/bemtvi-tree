-- nxvim-tree.git — the built-in, opt-in git-status decorator (enable with `git = true`).
--
-- Zero coupling with the tree's core: it only uses the decorator seam
-- (`api.register_decorator`) and `api.refresh()`. It reads the repository through the
-- native `nx.git` engine (gix — no `git` binary is spawned), builds a path → status
-- map, and a decorator turns that into a gutter sign per changed file plus a "dirty
-- dot" on directories that contain a change. It re-fetches on `BufWritePost`. With
-- `git = false` (the default) none of this runs, and a non-git directory simply leaves
-- the tree unmarked.
--
-- `nx.git` (not `nx.git_local`) is deliberate: the status must describe the files the
-- tree is SHOWING, so in a daemon / remote session it has to run where those files
-- live. `nx.git` routes to the session's side; `nx.git_local` would always answer about
-- the client's disk and mark the wrong repo.
--
-- Two pure helpers are exported for the test suite: `classify(code)` (a 2-char
-- porcelain-style XY status → { sign, hl }) and `index(root, entries)` (a status entry
-- list → the file/dir maps the decorator reads).

local M = {}

local function join(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

-- classify(code) — a porcelain XY status into { sign, hl }. "??" is untracked; "!!" is
-- git-ignored; a D in either column is a deletion; an A is an addition; staged-only
-- (X set, Y clear) tints as staged; everything else is a modification.
--
-- `hl` tints the entry's NAME (never shifting it); `sign` rides the gutter. Ignored is
-- the one status with NO sign: it describes most of the files in a `target/` and a gutter
-- glyph on every one of them is noise, where dimming the name reads at a glance.
function M.classify(code)
  if code == "??" then
    return { sign = "+", hl = "NvimTreeGitNew" }
  elseif code == "!!" then
    return { hl = "NvimTreeGitIgnored" }
  end
  local x, y = code:sub(1, 1), code:sub(2, 2)
  if x == "D" or y == "D" then
    return { sign = "-", hl = "NvimTreeGitDeleted" }
  elseif x == "A" or y == "A" then
    return { sign = "+", hl = "NvimTreeGitNew" }
  elseif y == " " and x ~= " " then
    return { sign = "✓", hl = "NvimTreeGitStaged" }
  end
  return { sign = "~", hl = "NvimTreeGitDirty" }
end

-- index(root, entries) -> file_status, dir_dirty, ignored. Turn `nx.git.status`'s entry
-- list into the three maps the decorator reads: `abspath -> { sign, hl }` for changed
-- files, `abspath -> true` for every ancestor directory of a change, and
-- `abspath -> true` for each git-ignored path.
--
-- `root` is the REPOSITORY root, not the tree root: entry paths are repo-relative, and
-- the tree may be rooted at a subdirectory (or above the repo), so joining against
-- anything else would key the map on paths that never match a node.
--
-- `nx.git.status` hands back exactly one entry per path with both porcelain columns
-- filled (an untracked file reads `??`, an ignored one `!!`), so the XY code is a plain
-- concatenation — there is nothing to fold or re-spell here.
--
-- Two things make ignored different from every other status:
--   * it does NOT dirty its ancestors — an ignored file is not a change, and marking
--     `target/`'s parents dirty would put a dot on the repo root of every clean repo;
--   * an entry may name a DIRECTORY (the engine collapses a wholly-ignored `target/`
--     into one entry rather than its 50k files), so membership is a prefix test —
--     see `is_ignored`, not a plain lookup.
function M.index(root, entries)
  local file_status, dir_dirty, ignored = {}, {}, {}
  for _, e in ipairs(entries or {}) do
    local abs = join(root, e.path)
    local code = e.index .. e.worktree
    if code == "!!" then
      ignored[abs] = true
    else
      file_status[abs] = M.classify(code)
      local p = abs:match("(.*)/[^/]+$") -- propagate the dirty flag to ancestors
      while p and #p >= #root do
        dir_dirty[p] = true
        p = p:match("(.*)/[^/]+$")
      end
    end
  end
  return file_status, dir_dirty, ignored
end

-- is_ignored(ignored, path, root) — whether `path` is git-ignored, either by naming an
-- ignored entry itself or by living under one. The ancestor walk is what makes a
-- collapsed `target/` cover every file inside it: the engine reports the directory once,
-- and each descendant resolves through its parents. Bounded by `root` (the repository
-- root) so the walk can't climb past the repo, and cheap — path depth, not entry count.
function M.is_ignored(ignored, path, root)
  if ignored[path] then
    return true
  end
  local p = path:match("(.*)/[^/]+$")
  while p and #p >= #root do
    if ignored[p] then
      return true
    end
    p = p:match("(.*)/[^/]+$")
  end
  return false
end

-- enable(api) — wire the decorator and the refetch autocmd. Idempotent per tree: the
-- caller (init.build) calls it once when `cfg.git` is on. `api` provides
-- register_decorator(fn), refresh(), root() (the current tree root path), and
-- set_git_state(state) (publishes the repo root + ignored set back to the tree, which
-- owns the always-reserved gutter and the hide-ignored filter).
function M.enable(api)
  local file_status = {} -- abspath -> { sign, hl }
  local dir_dirty = {} -- abspath -> true (an ancestor of a change)
  local ignored = {} -- abspath -> true (an ignored file OR collapsed directory)
  local repo_root = nil -- the repository root the three maps are keyed against

  -- Every status paints the entry's NAME (`hl`, applied over the name range only) so the
  -- name's start column never moves, plus a gutter sign for the changed states. Ignored
  -- entries — including a DIRECTORY the engine collapsed — get the dim name and no sign.
  api.register_decorator(function(node)
    if repo_root and M.is_ignored(ignored, node.path, repo_root) then
      return { hl = "NvimTreeGitIgnored" }
    end
    if node.type == "directory" then
      if dir_dirty[node.path] then
        return { sign_text = "•", sign_hl = "NvimTreeGitDirty" }
      end
    else
      local s = file_status[node.path]
      if s then
        return { sign_text = s.sign, sign_hl = s.hl, hl = s.hl }
      end
    end
  end)

  local function fetch()
    local root = api.root()
    if not root then
      return
    end
    nx.async(function()
      -- `discover` locates the repository (and rejects ENOREPO when there isn't one);
      -- its root is what the status paths are relative to.
      local repo = nx.await(nx.git.discover(root))
      -- `ignored = true` is what makes a `target/` dimmable at all; the engine collapses
      -- a wholly-ignored directory into ONE entry, so this stays cheap (Phase 1 of
      -- docs/plans/2026-07-25-git-status-in-the-tree.md in the nxvim repo).
      local st = nx.await(nx.git.status(root, { ignored = true }))
      file_status, dir_dirty, ignored = M.index(repo.root, st.entries)
      repo_root = repo.root
      -- Reaching here means we ARE in a repository: hand the tree the repo root (which
      -- pins the always-reserved sign gutter — never in a non-repo, where no sign can
      -- ever appear) and the ignored set (which drives the hide filter).
      api.set_git_state({ root = repo.root, ignored = ignored })
      api.refresh()
    end)():catch(function(e)
      -- A tree rooted outside any repository is an ordinary state for an opt-in
      -- decorator, not an error: leave the tree unmarked and stay quiet. Anything
      -- else (a broken repo, no git engine in a serverless web session) is surfaced.
      local code = type(e) == "table" and e.code or nil
      if code == "ENOREPO" then
        return
      end
      nx.notify("nxvim-tree.git: " .. tostring(type(e) == "table" and e.message or e), 4)
    end)
  end

  nx.on("BufWritePost", {}, fetch)
  fetch() -- initial paint
end

return M
