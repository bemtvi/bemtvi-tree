-- Config merge + validation. Pure (no editor state), run with `bemtvi --test-plugin`.

local config = require("bemtvi-tree.config")

btv.test.describe("bemtvi-tree.config", function()
  btv.test.it("defaults() hands out an independent copy each call", function()
    local a = config.defaults()
    local b = config.defaults()
    a.width = 999
    a.mappings["zz"] = "refresh"
    btv.test.expect(b.width).never.to_be(999)
    btv.test.expect(b.mappings["zz"]).to_be_nil()
  end)

  btv.test.it("merges scalars and merges mappings key-by-key", function()
    local cfg = config.merge(config.defaults(), {
      width = 40,
      mappings = { ["X"] = "delete", ["a"] = false },
    })
    btv.test.expect(cfg.width).to_be(40)
    -- the user's new key is present…
    btv.test.expect(cfg.mappings["X"]).to_be("delete")
    -- …their disabled default survives as `false`…
    btv.test.expect(cfg.mappings["a"]).to_be(false)
    -- …and the untouched defaults are still there.
    btv.test.expect(cfg.mappings["<CR>"]).to_be("select")
  end)

  btv.test.it("accepts a function as a custom mapping", function()
    local cfg = config.merge(config.defaults(), { mappings = { ["g?"] = function() end } })
    btv.test.expect(type(cfg.mappings["g?"])).to_be("function")
  end)

  btv.test.it("rejects an unknown action name (fails loud)", function()
    btv.test
      .expect(function()
        config.merge(config.defaults(), { mappings = { ["z"] = "does_not_exist" } })
      end)
      .to_error("unknown action")
  end)

  btv.test.it("rejects an invalid position", function()
    btv.test
      .expect(function()
        config.merge(config.defaults(), { position = "middle" })
      end)
      .to_error("position")
  end)

  btv.test.it("rejects a non-positive width", function()
    btv.test
      .expect(function()
        config.merge(config.defaults(), { width = 0 })
      end)
      .to_error("width")
  end)
end)
