local M = {}

M.name = "fake"

function M.detect(_bufnr)
	return true
end

function M.discover(ctx)
	local bufnr = ctx.bufnr
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local cursor_lnum = math.max(math.min(vim.api.nvim_win_get_cursor(0)[1], line_count), 1)
	local file = vim.api.nvim_buf_get_name(bufnr)
	local name = "fake failing " .. ctx.scope .. " test"

	return {
		{
			id = file .. ":" .. cursor_lnum .. ":" .. name,
			name = name,
			file = file,
			lnum = cursor_lnum,
			col = 0,
		},
	}
end

function M.run(tests, done)
	local diagnostics = {}
	local failed_tests = {}

	for _, test in ipairs(tests) do
		table.insert(failed_tests, {
			id = test.id,
			name = test.name,
			file = test.file,
			lnum = test.lnum,
			col = test.col,
		})

		table.insert(diagnostics, {
			test_id = test.id,
			test_name = test.name,
			file = test.file,
			lnum = test.lnum,
			col = test.col,
			severity = "error",
			message = "Fake adapter failure for `" .. test.name .. "`",
		})
	end

	done({
		ok = false,
		failed_tests = failed_tests,
		diagnostics = diagnostics,
	})
end

return M
