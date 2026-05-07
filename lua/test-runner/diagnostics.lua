local M = {}

local namespace = vim.api.nvim_create_namespace("test-runner.nvim")

local severities = {
	error = vim.diagnostic.severity.ERROR,
	warn = vim.diagnostic.severity.WARN,
	info = vim.diagnostic.severity.INFO,
	hint = vim.diagnostic.severity.HINT,
}

local function message_for(diagnostic)
	local message = diagnostic.message or "test failed"

	if diagnostic.stale then
		return "[stale] " .. message
	end

	return message
end

local function to_diagnostic(diagnostic)
	return {
		lnum = math.max((diagnostic.lnum or 1) - 1, 0),
		col = diagnostic.col or 0,
		severity = severities[diagnostic.severity] or vim.diagnostic.severity.ERROR,
		source = diagnostic.stale and "test-runner.nvim stale" or "test-runner.nvim",
		message = message_for(diagnostic),
		user_data = {
			test_id = diagnostic.test_id,
			test_name = diagnostic.test_name,
			stale = diagnostic.stale,
		},
	}
end

function M.render(bufnr, diagnostics)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local items = {}

	for _, diagnostic in ipairs(diagnostics) do
		table.insert(items, to_diagnostic(diagnostic))
	end

	vim.diagnostic.set(namespace, bufnr, items)
end

function M.clear(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.diagnostic.reset(namespace, bufnr)
end

return M
