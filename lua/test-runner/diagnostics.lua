local M = {}

local namespace = vim.api.nvim_create_namespace("test-runner.nvim")

local function to_diagnostic(failure)
	return {
		lnum = math.max((failure.lnum or 1) - 1, 0),
		col = failure.col or 0,
		severity = vim.diagnostic.severity.ERROR,
		source = "test-runner.nvim",
		message = failure.message or "test failed",
		user_data = {
			test_name = failure.test_name,
		},
	}
end

function M.set(bufnr, failures)
	local items = {}

	for _, failure in ipairs(failures) do
		table.insert(items, to_diagnostic(failure))
	end

	vim.diagnostic.set(namespace, bufnr, items)
end

function M.clear(bufnr)
	vim.diagnostic.reset(namespace, bufnr)
end

return M
