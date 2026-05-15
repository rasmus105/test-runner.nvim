local M = {}

M.name = "fake"

-- ==================================================
-- Public API
-- ==================================================

---Accept every buffer so tests can be exercised without a real language adapter.
---@param _bufnr integer
---@return boolean accepted
function M.detect(_bufnr)
	return true
end

---Create deterministic fake tests near the cursor for UI and state testing.
---@param ctx TestRunnerContext
---@return TestRunnerTest[] tests
function M.discover(ctx)
	local bufnr = ctx.bufnr
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local cursor_lnum = math.max(math.min(vim.api.nvim_win_get_cursor(0)[1], line_count), 1)
	local file = vim.api.nvim_buf_get_name(bufnr)
	local count = ctx.scope == "all" and 5 or 3
	local tests = {}

	for index = 1, count do
		local lnum = math.min(cursor_lnum + ((index - 1) * 2), line_count)
		local name = "fake " .. ctx.scope .. " test " .. index

		table.insert(tests, {
			id = file .. ":" .. lnum .. ":" .. name,
			name = name,
			file = file,
			lnum = lnum,
			col = 0,
			end_lnum = math.min(lnum + 1, line_count),
		})
	end

	return tests
end

---Mark alternating fake tests as failed and report matching diagnostics.
---@param ctx TestRunnerRunContext
---@param done fun(result: TestRunnerResult)
function M.run(ctx, done)
	local completed = {}

	for index, test in ipairs(ctx.tests) do
		if index % 2 == 1 then
			table.insert(completed, {
				id = test.id,
				name = test.name,
				file = test.file,
				lnum = test.lnum,
				status = "failed",
				failure = {
					file = test.file,
					lnum = test.lnum,
					col = test.col,
					message = "Fake adapter failure for `" .. test.name .. "`",
				},
			})
		else
			table.insert(completed, {
				id = test.id,
				name = test.name,
				file = test.file,
				lnum = test.lnum,
				status = "passed",
			})
		end
	end

	done({
		completed = completed,
	})
end

return M
