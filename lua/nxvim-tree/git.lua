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

-- classify(code) — a porcelain XY status into { sign, hl }. "??" is untracked; a D in
-- either column is a deletion; an A is an addition; staged-only (X set, Y clear) tints
-- as staged; everything else is a modification.
function M.classify(code)
  if code == "??" then
    return { sign = "+", hl = "NvimTreeGitNew" }
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

-- index(root, entries) -> file_status, dir_dirty. Turn `nx.git.status`'s entry list
-- into the two maps the decorator reads: `abspath -> { sign, hl }` for changed files,
-- and `abspath -> true` for every ancestor directory of a change.
--
-- `root` is the REPOSITORY root, not the tree root: entry paths are repo-relative, and
-- the tree may be rooted at a subdirectory (or above the repo), so joining against
-- anything else would key the map on paths that never match a node.
--
-- `nx.git.status` hands back exactly one entry per path with both porcelain columns
-- filled (an untracked file reads `??`), so the XY code is a plain concatenation —
-- there is nothing to fold or re-spell here.
function M.index(root, entries)
  local file_status, dir_dirty = {}, {}
  for _, e in ipairs(entries or {}) do
    local abs = join(root, e.path)
    file_status[abs] = M.classify(e.index .. e.worktree)
    local p = abs:match("(.*)/[^/]+$") -- propagate the dirty flag to ancestors
    while p and #p >= #root do
      dir_dirty[p] = true
      p = p:match("(.*)/[^/]+$")
    end
  end
  return file_status, dir_dirty
end

-- enable(api) — wire the decorator and the refetch autocmd. Idempotent per tree: the
-- caller (init.build) calls it once when `cfg.git` is on. `api` provides
-- register_decorator(fn), refresh(), and root() (the current tree root path).
function M.enable(api)
  local file_status = {} -- abspath -> { sign, hl }
  local dir_dirty = {} -- abspath -> true (an ancestor of a change)

  api.register_decorator(function(node)
    if node.type == "directory" then
      if dir_dirty[node.path] then
        return { sign_text = "•", sign_hl = "NvimTreeGitDirty" }
      end
    else
      local s = file_status[node.path]
      if s then
        return { sign_text = s.sign, sign_hl = s.hl }
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
      local st = nx.await(nx.git.status(root))
      file_status, dir_dirty = M.index(repo.root, st.entries)
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
