# inlinediff-nvim

Simplest Neovim inline diff view with character-level highlighting.

- VS Code-style inline diff view
- Character-level highlighting across the entire buffer width
- Auto-refresh with configurable debounce
- Git-index comparison (works with unsaved buffers)
- Optional staged changes shown at the same time, in their own colors
- Optional brighter highlight for the diff under the cursor
- Configurable colors

<img width="1440" height="900" alt="Screenshot 2026-01-28 at 16 54 19" src="https://github.com/user-attachments/assets/b4bd0b1f-d079-4951-b58b-35c681fa628f" />

---

This plugin is solely focused on providing a better inline Git diff view. It is meant to be used alongside your favorite Git plugin (for example, gitsigns). I created inlinediff-nvim because gitsigns lacked character-level highlighting and its inline decorations could disappear on cursor move.

inspiration:
[mini.diff](https://github.com/nvim-mini/mini.diff/tree/main), [gitsigns](https://github.com/lewis6991/gitsigns.nvim)

## Install with your favorite plugin manager

```lua
-- lazy.nvim
return {
    "YouSame2/inlinediff-nvim",
    lazy = true, -- disable loading plugin until called with cmd or keys
    cmd = "InlineDiff",
    opts = {}, -- leave blank to use defaults
    keys = {
        {
            "<leader>ghp",
            function()
                require("inlinediff").toggle()
            end,
            desc = "Toggle inline diff",
        },
    },

```

## Default opts (configure to your liking)

```lua
opts = {
    debounce_time = 200,
    -- Start with the inline diff enabled right after setup().
    enabled = false,
    -- Show staged changes alongside unstaged ones, in separate colors.
    show_staged = false,
    -- Tint the diff on the line under the cursor more strongly.
    cursor_highlight = true,
	ignored_buftype = { "terminal", "nofile" },
	ignored_filetype = { "TelescopePrompt", "NvimTree", "dap-repl", "neo-tree" },
    -- Colors are derived from the active colorscheme and refreshed on ColorScheme.
    -- Override any entry to pin a custom color, e.g.:
    colors = {
        -- context = dim background color; change = bright background color for changed text.
        -- InlineDiffAddChange = "#395200",
        -- InlineDiffDeleteChange = "#520005",
        -- Staged changes use their own colors so both can be visible together.
        -- InlineDiffStagedAddContext = "#0b2233",
    },
}
```

Set `enabled = true` to start with the inline diff turned on, and `show_staged = true`
to also display staged changes. When both staged and unstaged edits touch the same
line, the unstaged highlight takes precedence. Diff colors follow the active
colorscheme — unstaged edits are low-intensity tints of its `Added`/`Removed`
accents, staged edits of its diagnostic info/warn accents, so text stays readable.

## Commands

- `:InlineDiff toggle`
- `:InlineDiff refresh`
- `:InlineDiff staged` — toggle showing staged changes alongside unstaged ones
