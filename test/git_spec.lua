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

-- `nx.git.status` hands back one entry per CHANGE, with repo-relative paths and the
-- index / worktree columns split — not porcelain's merged XY line. `index()` bridges
-- that shape onto the maps the decorator reads.
nx.test.describe("nxvim-tree.git.index", function()
  local ROOT = "/repo"

  nx.test.it("keys files on the repo root, not on a relative path", function()
    local files = git.index(ROOT, { { path = "src/main.rs", index = " ", worktree = "M" } })
    nx.test.expect(files["/repo/src/main.rs"].hl).to_be("NvimTreeGitDirty")
    nx.test.expect(files["src/main.rs"]).to_be(nil)
  end)

  nx.test.it("spells an untracked entry's bare '?' worktree column as porcelain '??'", function()
    -- The engine reports untracked as worktree = "?" with an empty index column; read
    -- literally that is neither "??" nor a known letter, and would misclassify as a
    -- plain modification.
    local files = git.index(ROOT, { { path = "new.txt", index = " ", worktree = "?" } })
    nx.test.expect(files["/repo/new.txt"].hl).to_be("NvimTreeGitNew")
    nx.test.expect(files["/repo/new.txt"].sign).to_be("+")
  end)

  nx.test.it("merges a file's separate staged and unstaged entries into one status", function()
    -- A file staged AND then modified arrives as TWO entries; porcelain would call it
    -- "MM". Merged, the worktree column is set, so it is dirty rather than staged-only.
    -- Asserted in BOTH orders: the engine's iteration order is not ours to rely on, and
    -- a last-entry-wins bug survives one order while corrupting the other.
    local staged_first = git.index(ROOT, {
      { path = "a.txt", index = "M", worktree = " " },
      { path = "a.txt", index = " ", worktree = "M" },
    })
    nx.test.expect(staged_first["/repo/a.txt"].hl).to_be("NvimTreeGitDirty")

    local worktree_first = git.index(ROOT, {
      { path = "a.txt", index = " ", worktree = "M" },
      { path = "a.txt", index = "M", worktree = " " },
    })
    nx.test.expect(worktree_first["/repo/a.txt"].hl).to_be("NvimTreeGitDirty")
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
