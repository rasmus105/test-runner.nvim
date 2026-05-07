local M = {}

local tests_by_bufnr = {}
local active_run = nil

local function normalize_test(bufnr, test)
	local file = test.file

	if not file or file == "" then
		file = vim.api.nvim_buf_get_name(bufnr)
	end

	local lnum = test.lnum or 1
	local col = test.col or 0
	local name = test.name or "unnamed test"

	return vim.tbl_extend("force", test, {
		id = test.id or (file .. ":" .. lnum .. ":" .. name),
		name = name,
		file = file,
		lnum = lnum,
		col = col,
		end_lnum = test.end_lnum or lnum,
		status = test.status or "idle",
	})
end

function M.set_tests(bufnr, tests)
	local stored = {}

	for _, test in ipairs(tests) do
		table.insert(stored, normalize_test(bufnr, test))
	end

	table.sort(stored, function(left, right)
		if left.lnum == right.lnum then
			return left.col < right.col
		end

		return left.lnum < right.lnum
	end)

	tests_by_bufnr[bufnr] = stored
	return stored
end

function M.get_tests(bufnr)
	return tests_by_bufnr[bufnr] or {}
end

function M.clear_buffer(bufnr)
	tests_by_bufnr[bufnr] = nil
end

function M.find_at_line(bufnr, lnum)
	for _, test in ipairs(M.get_tests(bufnr)) do
		local end_lnum = test.end_lnum or test.lnum

		if test.lnum <= lnum and lnum <= end_lnum then
			return test
		end
	end

	return nil
end

function M.is_running()
	return active_run ~= nil
end

function M.start_run(tests)
	active_run = {
		tests = tests,
	}
end

function M.finish_run()
	active_run = nil
end

function M.set_status(bufnr, tests, status)
	local ids = {}

	for _, test in ipairs(tests) do
		ids[test.id] = true
	end

	for _, test in ipairs(M.get_tests(bufnr)) do
		if ids[test.id] then
			test.status = status
		end
	end
end

function M.apply_result(bufnr, tests, result)
	local failed = {}

	for _, test in ipairs(result.failed_tests or {}) do
		if test.id then
			failed[test.id] = true
		end
	end

	local selected = {}

	for _, test in ipairs(tests) do
		selected[test.id] = true
	end

	for _, test in ipairs(M.get_tests(bufnr)) do
		if selected[test.id] then
			if failed[test.id] then
				test.status = "failed"
			else
				test.status = "passed"
			end
		end
	end
end

return M
