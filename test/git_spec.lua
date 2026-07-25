-- The git decorator's two pure halves: the porcelain XY → sign classification, and the
-- `nx.git.status` entry list → file/directory map indexing. Both hermetic (no repo, no
-- `git` binary). Run with `nxvim --test-plugin`.

local git = require("nxvim-tree.git")

-- The hl groups are the canonical NvimTree* names so a ported colorscheme themes them.
nx.test.describe("nxvim-tree.git.classify", function()
  nx.test.it("marks untracked files as new", function()
    nx.test.expect(git.classify("??").hl).to_be("NvimTreeGitNew")
  end)

  nx.test.it("marks a working-tree modification as dirty", function()
    nx.test.expect(git.classify(" M").hl).to_be("NvimTreeGitDirty")
  end)

  nx.test.it("marks a staged-only change as staged", function()
    nx.test.expect(git.classify("M ").hl).to_be("NvimTreeGitStaged")
  end)

  nx.test.it("marks a deletion in either column", function()
    nx.test.expect(git.classify(" D").hl).to_be("NvimTreeGitDeleted")
    nx.test.expect(git.classify("D ").hl).to_be("NvimTreeGitDeleted")
  end)

  nx.test.it("marks an addition", function()
    nx.test.expect(git.classify("A ").hl).to_be("NvimTreeGitNew")
  end)
end)

-- `nx.git.status` hands back exactly one entry per PATH, with repo-relative paths and
-- both porcelain columns filled. `index()` turns that into the maps the decorator
-- reads — the absolute-path keying and the ancestor walk.
nx.test.describe("nxvim-tree.git.index", function()
  local ROOT = "/repo"

  nx.test.it("keys files on the repo root, not on a relative path", function()
    local files = git.index(ROOT, { { path = "src/main.rs", index = " ", worktree = "M" } })
    nx.test.expect(files["/repo/src/main.rs"].hl).to_be("NvimTreeGitDirty")
    nx.test.expect(files["src/main.rs"]).to_be(nil)
  end)

  nx.test.it("marks an untracked '??' entry as new", function()
    local files = git.index(ROOT, { { path = "new.txt", index = "?", worktree = "?" } })
    nx.test.expect(files["/repo/new.txt"].hl).to_be("NvimTreeGitNew")
    nx.test.expect(files["/repo/new.txt"].sign).to_be("+")
  end)

  nx.test.it("reads a staged-and-modified 'MM' entry as dirty", function()
    -- The engine folds a path's two halves, so both columns arrive on one entry; an
    -- unstaged edit on top of a staged one is dirty, not staged-only.
    local files = git.index(ROOT, { { path = "a.txt", index = "M", worktree = "M" } })
    nx.test.expect(files["/repo/a.txt"].hl).to_be("NvimTreeGitDirty")
  end)

  nx.test.it("tints a rename by which column it lands in", function()
    -- A STAGED rename is "R " — staged-only, so it tints as staged. An UNSTAGED rename
    -- (" R", which nxvim detects and git's own porcelain does not) differs from the
    -- index, so it reads as a modification. Neither is a special case in classify; this
    -- pins the behaviour now that renames actually reach us.
    local staged = git.index(ROOT, { { path = "new.txt", index = "R", worktree = " " } })
    nx.test.expect(staged["/repo/new.txt"].hl).to_be("NvimTreeGitStaged")

    local unstaged = git.index(ROOT, { { path = "new.txt", index = " ", worktree = "R" } })
    nx.test.expect(unstaged["/repo/new.txt"].hl).to_be("NvimTreeGitDirty")
  end)

  nx.test.it("keeps a staged-only change staged", function()
    local files = git.index(ROOT, { { path = "a.txt", index = "M", worktree = " " } })
    nx.test.expect(files["/repo/a.txt"].hl).to_be("NvimTreeGitStaged")
  end)

  nx.test.it("marks every ancestor directory of a change dirty, up to the repo root", function()
    local _, dirs = git.index(ROOT, { { path = "a/b/c.txt", index = " ", worktree = "M" } })
    nx.test.expect(dirs["/repo/a/b"]).to_be(true)
    nx.test.expect(dirs["/repo/a"]).to_be(true)
    nx.test.expect(dirs["/repo"]).to_be(true)
    -- and nothing above it
    nx.test.expect(dirs["/"]).to_be(nil)
  end)

  nx.test.it("leaves a clean tree with no marks", function()
    local files, dirs = git.index(ROOT, {})
    nx.test.expect(next(files)).to_be(nil)
    nx.test.expect(next(dirs)).to_be(nil)
  end)
end)
