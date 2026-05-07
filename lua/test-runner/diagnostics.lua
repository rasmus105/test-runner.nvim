local M = {}

local namespace = vim.api.nvim_create_namespace("test-runner.nvim")

local severities = {
	error = vim.diagnostic.severity.ERROR,
	warn = vim.diagnostic.severity.WARN,
	info = vim.diagnostic.severity.INFO,
	hint = vim.diagnostic.severity.HINT,
}

local function to_diagnostic(diagnostic)
	return {
		lnum = math.max((diagnostic.lnum or 1) - 1, 0),
		col = diagnostic.col or 0,
		severity = severities[diagnostic.severity] or vim.diagnostic.severity.ERROR,
		source = "test-runner.nvim",
		message = diagnostic.message or "test failed",
		user_data = {
			test_name = diagnostic.test_name,
		},
	}
end

function M.set(bufnr, diagnostics)
	local items = {}

	for _, diagnostic in ipairs(diagnostics) do
		table.insert(items, to_diagnostic(diagnostic))
	end

	vim.diagnostic.set(namespace, bufnr, items)
end

function M.clear(bufnr)
	vim.diagnostic.reset(namespace, bufnr)
end

return M
