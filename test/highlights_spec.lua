-- The highlight contract: the explorer uses the canonical NvimTree* group names, and
-- defines them only as a FALLBACK so a ported colorscheme (e.g. catppuccin-bemtvi,
-- which styles NvimTree*) themes the tree unmodified. Run with `bemtvi --test-plugin`.

local highlights = require("bemtvi-tree.highlights")

-- The structural / git groups a colorscheme is expected to own.
local CANONICAL = {
  "NvimTreeRootFolder",
  "NvimTreeFolderName",
  "NvimTreeOpenedFolderName",
  "NvimTreeEmptyFolderName",
  "NvimTreeFolderIcon",
  "NvimTreeIndentMarker",
  "NvimTreeSymlink",
  "NvimTreeOpenedFile",
  "NvimTreeSpecialFile",
  "NvimTreeImageFile",
  "NvimTreeGitNew",
  "NvimTreeGitDirty",
  "NvimTreeGitStaged",
  "NvimTreeGitDeleted",
}

btv.test.describe("bemtvi-tree.highlights", function()
  btv.test.it("defines the canonical NvimTree* groups", function()
    highlights.apply({})
    for _, name in ipairs(CANONICAL) do
      btv.test.expect(btv.hl.exists(name)).to_be_truthy()
    end
  end)

  -- btv.hl.get returns `fg` as a decimal integer (0xRRGGBB), so compare numerically.
  btv.test.it("does NOT overwrite a group a colorscheme already defined", function()
    -- Simulate the colorscheme defining its NvimTree* color first.
    btv.hl.define(0, "NvimTreeFolderName", { fg = "#abcdef" })
    highlights.apply({})
    -- The fallback must have yielded — the colorscheme's color survives.
    btv.test.expect(btv.hl.get(0, { name = "NvimTreeFolderName" }).fg).to_be(0xabcdef)
  end)

  btv.test.it("honors an explicit user override over the fallback", function()
    highlights.apply({ NvimTreeRootFolder = { fg = "#123456" } })
    btv.test.expect(btv.hl.get(0, { name = "NvimTreeRootFolder" }).fg).to_be(0x123456)
  end)

  -- The sidebar's window chrome (background / cursorline / `~` fillers) is remapped
  -- through the tree window's `winhighlight`. The fallbacks LINK to the editor's own
  -- chrome groups so they follow the theme's light/dark flavour (a hardcoded colour
  -- would go dark under catppuccin-latte). Verify the links, so on a light theme the
  -- tree's fillers/cursorline stay light like the main editor.
  btv.test.it("links window-chrome fallbacks to the editor's themed groups", function()
    highlights.apply({})
    local function link_of(name)
      return btv.hl.get(0, { name = name, link = true }).link
    end
    btv.test.expect(link_of("NvimTreeNormal")).to_be("NormalFloat")
    btv.test.expect(link_of("NvimTreeEndOfBuffer")).to_be("EndOfBuffer")
    btv.test.expect(link_of("NvimTreeCursorLine")).to_be("CursorLine")
    btv.test.expect(link_of("NvimTreeCursorLineNr")).to_be("CursorLineNr")
  end)

  btv.test.it("does NOT overwrite a colorscheme's NvimTreeNormal background", function()
    -- A ported colorscheme (e.g. catppuccin) sets the sidebar bg first; the
    -- fallback must yield so the theme's shade survives regardless of load order.
    btv.hl.define(0, "NvimTreeNormal", { fg = "#cdd6f4", bg = "#222233" })
    highlights.apply({})
    btv.test.expect(btv.hl.get(0, { name = "NvimTreeNormal" }).bg).to_be(0x222233)
  end)

  -- The fallbacks are DERIVED from the active theme (btv.hl.palette), not hardcoded to
  -- one colorscheme's hexes, so the sidebar reads as part of whatever is loaded. Under
  -- the editor's own `bemtvi` scheme that means its One Dark hues.
  btv.test.it("derives its fallback colors from the active colorscheme", function(t)
    -- `hi clear` first: earlier `it`s in this file claim some NvimTree* groups with
    -- explicit `btv.hl.define` colours, and the fallback rightly yields to those.
    t:cmd("hi clear")
    t:cmd("colorscheme bemtvi")
    highlights.apply({})
    local function fg(group)
      return btv.hl.get(0, { name = group, link = false }).fg
    end
    btv.test.expect(fg("NvimTreeFolderName")).to_be(0x61afef) -- One Dark blue
    btv.test.expect(fg("NvimTreeGitNew")).to_be(0x98c379) -- One Dark green
    btv.test.expect(fg("NvimTreeGitDirty")).to_be(0xe5c07b) -- One Dark yellow
    btv.test.expect(fg("NvimTreeGitDeleted")).to_be(0xe06c75) -- One Dark red
    btv.test.expect(fg("NvimTreeIndentMarker")).to_be(0x5c6370) -- One Dark comment grey
    btv.test.expect(fg("BtvTreeIconRust")).to_be(0xd19a66) -- One Dark orange
  end)

  -- The half a plain `btv.hl.exists` guard gets wrong: `:colorscheme` drops only the
  -- OUTGOING scheme's own groups, so a group no theme models (every BtvTreeIcon*, the
  -- staged/ignored git states) still holds the colour derived from the previous theme.
  -- The plugin re-applies on ColorScheme, and the fallback must actually move.
  btv.test.it("re-derives a group no theme models when the theme changes", function(t)
    t:cmd("colorscheme bemtvi")
    highlights.apply({})
    btv.test.expect(btv.hl.get(0, { name = "BtvTreeIconRust", link = false }).fg).to_be(0xd19a66)

    -- Stand in for another theme: move the group the `orange` slot derives from.
    t:cmd("hi clear")
    btv.hl.define(0, "Constant", { fg = "#123456" })
    highlights.apply({})
    btv.test.expect(btv.hl.get(0, { name = "BtvTreeIconRust", link = false }).fg).to_be(0x123456)
  end)
end)
