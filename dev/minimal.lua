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
	adapters = {
		fake = {
			enabled = true,
		},
	},
})

local test_runner = require("test-runner")

vim.keymap.set("n", "<leader>tn", test_runner.run_nearest)
vim.keymap.set("n", "<leader>tf", test_runner.run_file)
vim.keymap.set("n", "<leader>ta", test_runner.run_all)
vim.keymap.set("n", "<leader>tc", test_runner.clear)
vim.keymap.set("n", "<leader>td", function()
	vim.print(vim.diagnostic.get(0))
end)
