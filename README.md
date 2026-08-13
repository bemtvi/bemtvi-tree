# bemtvi-tree

A fast, dockable, fully-featured **file explorer** for
[bemtvi](https://github.com/bemtvi/bemtvi) — the official tree.

It is built entirely on the native `btv.*` plugin API (ADR 0002): no buffer-mutation
hacks, no bespoke rendering loop. The tree's lines are owned by a read-only
`btv.view` surface, the filesystem work goes through the promise `btv.fs` API (with a
per-directory watch for live refresh), files open in the **main editor** via
`btv.open`, and every glyph / guide / git sign is an extmark. That's the point: a real
explorer, written the way a plugin author would write it.

```
 ~/code/sample
 󰜺 src/
 ├ 󰏗 lib.rs
 └ 󰏗 main.rs
 󰈙 Cargo.toml
 󰍔 notes.md
 󰈙 readme.txt
```

- **Lazy, watched tree** — scandir on first expand; only visible directories are watched.
- **Open anywhere** — main window, split, vsplit, or tab.
- **Mouse** — click to expand, double-click to open, right-click for a context menu.
- **Full file ops** — create, rename, delete, cut, copy, paste, yank path.
- **Name filter** (`<leader>/`, leaving a bare `/` to the editor's own search),
  **Nerd-Font icons** (with an ASCII fallback), opt-in **follow**, and cross-session
  **persistence**.
- **Dotfiles shown** by default (`H`, or `hidden = false`, hides them) — the repository's
  own `.git` dims as ignored rather than sitting in the listing.
- **Git status** (on by default; `git = false` opts out) — an entry's *name* is coloured by
  its status (added / modified / staged / deleted / ignored) with a matching gutter sign.
  Nothing is inserted between the icon and the name, and inside a repo the sign gutter is
  held open, so the filename's column never moves. Ignored entries (and `.git`) dim, or
  hide with `I`.
- **Glob filters** — `filters = { "*.o", "node_modules", "/vendor" }` hides entries by
  gitignore-style glob (`btv.glob`), anchored with a leading `/`; `U` suspends and
  re-applies the whole set live.
- **Extensible** — custom icons, per-node decorators, rebindable keys, `on_attach`.

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
btv.plugins({
  {
    "bemtvi/bemtvi-tree",
    config = function()
      require("bemtvi-tree").setup({})
    end,
  },
})
```

Then run `:PluginSync` to clone it, and press `<leader>e` (or run `:Tree`).

## Documentation

Full docs — every `setup()` option, session persistence, the commands, the complete
key and mouse bindings, the extension seams (icons, decorators, actions, `on_attach`),
the `NvimTree*` highlight groups, and the module API — live in the help file. The same
source renders both on GitHub and in the editor:

- In editor: `:help bemtvi-tree`
- On GitHub: [doc/bemtvi-tree.md](./doc/bemtvi-tree.md) (the help source)

## Trying it locally

```sh
BEMTVI_CONFIG=examples bemtvi examples/sample/readme.txt
```

(run from the repo root — the demo config in `examples/init.lua` loads the plugin
straight from this checkout).

## Development

```sh
bemtvi --test-plugin .
```

The suite covers the config merge/validation, the model (lazy load, sort, hidden
filter, refresh identity), icon and git classification, and the end-to-end flows
(render, expand/collapse, hidden toggle, filter, create, delete, open, change-root,
and the mouse gestures) driven with real keys.

The vimdoc `doc/bemtvi-tree.txt` is **generated** from `doc/bemtvi-tree.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand.

## License

MIT © David Rios
