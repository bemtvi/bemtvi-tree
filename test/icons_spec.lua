-- Icon resolution. Pure lookups, run with `bemtvi --test-plugin`.

local icons = require("bemtvi-tree.icons")

local function file(name)
  return { type = "file", name = name }
end

btv.test.describe("bemtvi-tree.icons", function()
  btv.test.it("resolves by extension", function()
    local _, hl = icons.get(file("main.rs"), { icons = true })
    btv.test.expect(hl).to_be("BtvTreeIconRust")
  end)

  btv.test.it("prefers an exact filename over its extension", function()
    -- Cargo.toml is a .toml file but has its own (rust) icon entry.
    local _, hl = icons.get(file("Cargo.toml"), { icons = true })
    btv.test.expect(hl).to_be("BtvTreeIconRust")
  end)

  btv.test.it("falls back to the default for an unknown kind", function()
    local _, hl = icons.get(file("mystery.zzz"), { icons = true })
    btv.test.expect(hl).to_be("BtvTreeIconDefault")
  end)

  btv.test.it("uses the folder glyph for directories, open vs closed", function()
    local closed_glyph =
      select(1, icons.get({ type = "directory", expanded = false }, { icons = true }))
    local open_glyph =
      select(1, icons.get({ type = "directory", expanded = true }, { icons = true }))
    btv.test.expect(closed_glyph).never.to_be(open_glyph)
  end)

  btv.test.it("register() extends the registry", function()
    icons.register({ zzz = { glyph = "Z", hl = "BtvTreeIconText" } })
    local _, hl = icons.get(file("mystery.zzz"), { icons = true })
    btv.test.expect(hl).to_be("BtvTreeIconText")
  end)

  btv.test.it("renders ASCII markers when icons are off", function()
    local glyph = select(1, icons.get(file("main.rs"), { icons = false }))
    -- The ASCII file marker is a plain blank (no Nerd-Font glyph).
    btv.test.expect(glyph).to_be(" ")
  end)
end)
