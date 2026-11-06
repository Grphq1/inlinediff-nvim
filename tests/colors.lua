-- Run from the repo root:
-- nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/colors.lua"

local inlinediff = require("inlinediff")
inlinediff.setup({ enabled = false })

local names = {
	"InlineDiffAddContext",
	"InlineDiffAddChange",
	"InlineDiffDeleteContext",
	"InlineDiffDeleteChange",
	"InlineDiffStagedAddContext",
	"InlineDiffStagedAddChange",
	"InlineDiffStagedDeleteContext",
	"InlineDiffStagedDeleteChange",
}

for _, name in ipairs(names) do
	local bg = vim.api.nvim_get_hl(0, { name = name }).bg
	assert(type(bg) == "number" and bg >= 0 and bg <= 0xffffff, name .. " is missing a background color")
end

-- Colors should follow the active colorscheme.
vim.o.background = "light"
vim.cmd("colorscheme morning")
local morning = vim.api.nvim_get_hl(0, { name = "InlineDiffAddContext" }).bg
vim.o.background = "dark"
vim.cmd("colorscheme habamax")
local habamax = vim.api.nvim_get_hl(0, { name = "InlineDiffAddContext" }).bg
assert(morning ~= habamax, "colors should be recomputed on ColorScheme")

-- Explicit colors should win over the derived ones.
inlinediff.setup({ enabled = false, colors = { InlineDiffAddContext = "#123456" } })
assert(vim.api.nvim_get_hl(0, { name = "InlineDiffAddContext" }).bg == 0x123456, "explicit color should override")
assert(
	type(vim.api.nvim_get_hl(0, { name = "InlineDiffDeleteContext" }).bg) == "number",
	"non-overridden colors should stay derived"
)

print("colors ok")
