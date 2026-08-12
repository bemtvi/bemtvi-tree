-- The git decorator's two pure halves: the porcelain XY → sign classification, and the
-- `btv.git.status` entry list → file/directory map indexing. Both hermetic (no repo, no
-- `git` binary). Run with `bemtvi --test-plugin`.

local git = require("bemtvi-tree.git")

-- The hl groups are the canonical NvimTree* names so a ported colorscheme themes them.
btv.test.describe("bemtvi-tree.git.classify", function()
  btv.test.it("marks untracked files as new", function()
    btv.test.expect(git.classify("??").hl).to_be("NvimTreeGitNew")
  end)

  btv.test.it("marks a working-tree modification as dirty", function()
    btv.test.expect(git.classify(" M").hl).to_be("NvimTreeGitDirty")
  end)

  btv.test.it("marks a staged-only change as staged", function()
    btv.test.expect(git.classify("M ").hl).to_be("NvimTreeGitStaged")
  end)

  btv.test.it("marks a deletion in either column", function()
    btv.test.expect(git.classify(" D").hl).to_be("NvimTreeGitDeleted")
    btv.test.expect(git.classify("D ").hl).to_be("NvimTreeGitDeleted")
  end)

  btv.test.it("marks an addition", function()
    btv.test.expect(git.classify("A ").hl).to_be("NvimTreeGitNew")
  end)
end)

-- `btv.git.status` hands back exactly one entry per PATH, with repo-relative paths and
-- both porcelain columns filled. `index()` turns that into the maps the decorator
-- reads — the absolute-path keying and the ancestor walk.
btv.test.describe("bemtvi-tree.git.index", function()
  local ROOT = "/repo"

  btv.test.it("keys files on the repo root, not on a relative path", function()
    local files = git.index(ROOT, { { path = "src/main.rs", index = " ", worktree = "M" } })
    btv.test.expect(files["/repo/src/main.rs"].hl).to_be("NvimTreeGitDirty")
    btv.test.expect(files["src/main.rs"]).to_be(nil)
  end)

  btv.test.it("marks an untracked '??' entry as new", function()
    local files = git.index(ROOT, { { path = "new.txt", index = "?", worktree = "?" } })
    btv.test.expect(files["/repo/new.txt"].hl).to_be("NvimTreeGitNew")
    btv.test.expect(files["/repo/new.txt"].sign).to_be("+")
  end)

  btv.test.it("reads a staged-and-modified 'MM' entry as dirty", function()
    -- The engine folds a path's two halves, so both columns arrive on one entry; an
    -- unstaged edit on top of a staged one is dirty, not staged-only.
    local files = git.index(ROOT, { { path = "a.txt", index = "M", worktree = "M" } })
    btv.test.expect(files["/repo/a.txt"].hl).to_be("NvimTreeGitDirty")
  end)

  btv.test.it("tints a rename by which column it lands in", function()
    -- A STAGED rename is "R " — staged-only, so it tints as staged. An UNSTAGED rename
    -- (" R", which bemtvi detects and git's own porcelain does not) differs from the
    -- index, so it reads as a modification. Neither is a special case in classify; this
    -- pins the behaviour now that renames actually reach us.
    local staged = git.index(ROOT, { { path = "new.txt", index = "R", worktree = " " } })
    btv.test.expect(staged["/repo/new.txt"].hl).to_be("NvimTreeGitStaged")

    local unstaged = git.index(ROOT, { { path = "new.txt", index = " ", worktree = "R" } })
    btv.test.expect(unstaged["/repo/new.txt"].hl).to_be("NvimTreeGitDirty")
  end)

  btv.test.it("keeps a staged-only change staged", function()
    local files = git.index(ROOT, { { path = "a.txt", index = "M", worktree = " " } })
    btv.test.expect(files["/repo/a.txt"].hl).to_be("NvimTreeGitStaged")
  end)

  btv.test.it("marks every ancestor directory of a change dirty, up to the repo root", function()
    local _, dirs = git.index(ROOT, { { path = "a/b/c.txt", index = " ", worktree = "M" } })
    btv.test.expect(dirs["/repo/a/b"]).to_be(true)
    btv.test.expect(dirs["/repo/a"]).to_be(true)
    btv.test.expect(dirs["/repo"]).to_be(true)
    -- and nothing above it
    btv.test.expect(dirs["/"]).to_be(nil)
  end)

  btv.test.it("leaves a clean tree with no marks", function()
    local files, dirs = git.index(ROOT, {})
    btv.test.expect(next(files)).to_be(nil)
    btv.test.expect(next(dirs)).to_be(nil)
  end)
end)

-- Git-ignored entries (`!!`, from `btv.git.status{ ignored = true }`) are the one status
-- that is NOT a change: they carry a dim name and no gutter sign, they must not dirty
-- their ancestors, and — because the engine collapses a wholly-ignored directory into a
-- single entry — membership is a PREFIX test, not a lookup.
btv.test.describe("bemtvi-tree.git ignored", function()
  local ROOT = "/repo"

  btv.test.it("classifies '!!' as ignored, with no sign", function()
    btv.test.expect(git.classify("!!").hl).to_be("NvimTreeGitIgnored")
    -- No gutter glyph: a sign on every file in a `target/` is noise.
    btv.test.expect(git.classify("!!").sign).to_be(nil)
  end)

  btv.test.it("indexes ignored paths apart from changes, dirtying no ancestors", function()
    local files, dirs, ignored = git.index(ROOT, {
      { path = "target", index = "!", worktree = "!" },
      { path = "deep/noise.log", index = "!", worktree = "!" },
    })
    btv.test.expect(ignored["/repo/target"]).to_be(true)
    btv.test.expect(ignored["/repo/deep/noise.log"]).to_be(true)
    -- NOT a change: no file_status entry, and no dirty dot anywhere up the chain
    -- (otherwise every clean repo with a `target/` would show a dirty root).
    btv.test.expect(next(files)).to_be(nil)
    btv.test.expect(next(dirs)).to_be(nil)
  end)

  btv.test.it("still indexes real changes alongside ignored entries", function()
    local files, dirs, ignored = git.index(ROOT, {
      { path = "target", index = "!", worktree = "!" },
      { path = "src/main.rs", index = " ", worktree = "M" },
    })
    btv.test.expect(ignored["/repo/target"]).to_be(true)
    btv.test.expect(files["/repo/src/main.rs"].hl).to_be("NvimTreeGitDirty")
    btv.test.expect(dirs["/repo/src"]).to_be(true)
    btv.test.expect(ignored["/repo/src/main.rs"]).to_be(nil)
  end)

  btv.test.it("resolves a collapsed ignored directory for every descendant", function()
    local _, _, ignored = git.index(ROOT, { { path = "target", index = "!", worktree = "!" } })
    -- The directory itself, and files at any depth beneath it — the engine reported the
    -- directory ONCE, so each descendant has to resolve through its ancestors.
    btv.test.expect(git.is_ignored(ignored, "/repo/target", ROOT)).to_be(true)
    btv.test.expect(git.is_ignored(ignored, "/repo/target/debug", ROOT)).to_be(true)
    btv.test.expect(git.is_ignored(ignored, "/repo/target/debug/deps/x.o", ROOT)).to_be(true)
    -- A sibling is untouched, and a name that merely SHARES the prefix is not a
    -- descendant (the walk splits on "/", so "targetlike" can never match "target").
    btv.test.expect(git.is_ignored(ignored, "/repo/src/main.rs", ROOT)).to_be(false)
    btv.test.expect(git.is_ignored(ignored, "/repo/targetlike/x.o", ROOT)).to_be(false)
  end)

  -- The repository's own `.git` is never in a status listing, but it is exactly as
  -- uninteresting as an ignored path — so `index` seeds it, which both dims it and lets
  -- `git_ignored = "hide"` drop it along with the rest. (It rides `ignored` rather than a
  -- render special-case so `is_ignored`'s prefix walk covers everything inside it too.)
  btv.test.it("indexes the repository's own .git as ignored", function()
    local _, _, ignored = git.index(ROOT, {})
    btv.test.expect(ignored["/repo/.git"]).to_be(true)
    btv.test.expect(git.is_ignored(ignored, "/repo/.git", ROOT)).to_be(true)
    btv.test.expect(git.is_ignored(ignored, "/repo/.git/refs/heads/main", ROOT)).to_be(true)
    -- Only the REPO's own: a `.git` name deeper in the tree is not this repo's.
    btv.test.expect(git.is_ignored(ignored, "/repo/src/.gitignore", ROOT)).to_be(false)
  end)

  btv.test.it("never climbs past the repo root", function()
    -- An entry named like the repo's PARENT must not make the repo's own files ignored.
    local ignored = { ["/"] = true, ["/repo"] = true }
    btv.test.expect(git.is_ignored(ignored, "/repo/src/main.rs", "/repo/src")).to_be(false)
  end)
end)
