# nxvim-tree

A fast, dockable, fully-featured **file explorer** for
[nxvim](https://github.com/davidrios/nxvim) — the official tree.

It is built entirely on the native `nx.*` plugin API (ADR 0002): no buffer-mutation
hacks, no bespoke rendering loop. The tree's lines are owned by a read-only
`nx.view` surface, the filesystem work goes through the promise `nx.fs` API (with a
per-directory watch for live refresh), files open in the **main editor** via
`nx.open`, and every glyph / guide / git sign is an extmark. That's the point: a real
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
- **Name filter**, **Nerd-Font icons** (with an ASCII fallback), opt-in **git status**
  and **follow**, and cross-session **persistence**.
- **Extensible** — custom icons, per-node decorators, rebindable keys, `on_attach`.

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
nx.plugins({
  {
    "davidrios/nxvim-tree",
    config = function()
      require("nxvim-tree").setup({})
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

- In editor: `:help nxvim-tree`
- On GitHub: [doc/nxvim-tree.md](./doc/nxvim-tree.md) (the help source)

## Trying it locally

```sh
NXVIM_CONFIG=examples nxvim examples/sample/readme.txt
```

(run from the repo root — the demo config in `examples/init.lua` loads the plugin
straight from this checkout).

## Development

```sh
nxvim --test-plugin .
```

The suite covers the config merge/validation, the model (lazy load, sort, hidden
filter, refresh identity), icon and git classification, and the end-to-end flows
(render, expand/collapse, hidden toggle, filter, create, delete, open, change-root,
and the mouse gestures) driven with real keys.

The vimdoc `doc/nxvim-tree.txt` is **generated** from `doc/nxvim-tree.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand.

## License

MIT © David Rios
