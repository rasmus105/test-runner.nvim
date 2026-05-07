local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")

vim.opt.runtimepath:prepend(root)
vim.cmd.runtime("plugin/test-runner.lua")

vim.opt.number = true
vim.opt.signcolumn = "yes"

vim.g.mapleader = " "

vim.diagnostic.config({
	virtual_text = true,
	signs = true,
	underline = true,
	update_in_insert = false,
	severity_sort = true,
	float = {
		border = "rounded",
		source = true,
	},
})

require("test-runner").setup({
	enabled = false,
	adapters = {
		fake = {
			enabled = true,
		},
	},
	ui = {
		inline = {
			click = true,
		},
	},
})

local test_runner = require("test-runner")

vim.keymap.set("n", "<leader>tr", test_runner.run_at_cursor)
vim.keymap.set("n", "<leader>tf", test_runner.run_file)
vim.keymap.set("n", "<leader>ta", test_runner.run_all)
vim.keymap.set("n", "<leader>tl", test_runner.run_last)
vim.keymap.set("n", "<leader>ts", test_runner.discover)
vim.keymap.set("n", "<leader>tc", test_runner.clear)
vim.keymap.set("n", "<leader>tt", test_runner.toggle)
vim.keymap.set("n", "<leader>td", function()
	vim.print(vim.diagnostic.get(0))
end)
