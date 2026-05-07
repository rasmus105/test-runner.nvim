local config = require("test-runner.config")

local M = {}

local namespace = vim.api.nvim_create_namespace("test-runner.nvim.inline")

local highlights = {
	idle = "DiagnosticHint",
	running = "DiagnosticInfo",
	passed = "DiagnosticOk",
	failed = "DiagnosticError",
	blocked = "DiagnosticWarn",
}

local function icon_for(status)
	local icons = config.options.ui.inline.icons
	return icons[status] or icons.idle
end

function M.render(bufnr, tests)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if not config.options.ui.inline.enabled then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	for _, test in ipairs(tests) do
		local status = test.status or "idle"
		local lnum = test.lnum or 1

		if lnum >= 1 and lnum <= line_count then
			vim.api.nvim_buf_set_extmark(bufnr, namespace, lnum - 1, 0, {
				virt_text = { { " " .. icon_for(status), highlights[status] or highlights.idle } },
				virt_text_pos = config.options.ui.inline.virt_text_pos,
				hl_mode = "combine",
			})
		end
	end
end

function M.clear(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
