local M = {}

M.name = "fake"

function M.detect(_bufnr)
	return true
end

function M.discover(ctx)
	local bufnr = ctx.bufnr
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local file = vim.api.nvim_buf_get_name(bufnr)

	return {
		{
			name = "fake failing " .. ctx.scope .. " test",
			file = file,
			lnum = cursor_lnum,
			col = 0,
		},
	}
end

function M.run(tests, done)
	local failures = {}

	for _, test in ipairs(tests) do
		table.insert(failures, {
			test_name = test.name,
			file = test.file,
			lnum = test.lnum,
			col = test.col,
			message = "Fake adapter failure for `" .. test.name .. "`",
		})
	end

	done({
		ok = false,
		failures = failures,
	})
end

return M
