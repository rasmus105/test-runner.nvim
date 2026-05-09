local M = {}

local tests_by_bufnr = {}
local diagnostics_by_bufnr = {}
local active_run = nil
local last_run = nil

-- ==================================================
-- Local Functions
-- ==================================================

local function same_file(left, right)
	return vim.fs.normalize(left or "") == vim.fs.normalize(right or "")
end

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

local function ids_for_tests(tests)
	local ids = {}

	for _, test in ipairs(tests) do
		ids[test.id] = true
	end

	return ids
end

local function shift_diagnostics_after(bufnr, after_lnum, delta)
	if delta == 0 then
		return
	end

	for _, diagnostic in ipairs(M.get_diagnostics(bufnr)) do
		if after_lnum < diagnostic.lnum then
			diagnostic.lnum = math.max(diagnostic.lnum + delta, 1)
		end
	end
end

local function normalize_diagnostic(bufnr, diagnostic)
	local lnum = diagnostic.lnum or 1
	local test_id = diagnostic.test_id
	local test_name = diagnostic.test_name

	if not test_id then
		local test = nil

		if test_name then
			for _, candidate in ipairs(M.get_tests(bufnr)) do
				if candidate.name == test_name then
					test = candidate
					break
				end
			end
		end

		if not test then
			test = M.find_at_line(bufnr, lnum)
		end

		if test then
			test_id = test.id
			test_name = test_name or test.name
		end
	end

	return vim.tbl_extend("force", diagnostic, {
		lnum = lnum,
		col = diagnostic.col or 0,
		severity = diagnostic.severity or "error",
		message = diagnostic.message or "test failed",
		test_id = test_id,
		test_name = test_name,
		stale = diagnostic.stale == true,
	})
end

-- ==================================================
-- Public API
-- ==================================================

-- Store normalized tests for a buffer while preserving existing statuses by id.
function M.set_tests(bufnr, tests)
	local stored = {}
	local previous = {}

	for _, test in ipairs(M.get_tests(bufnr)) do
		previous[test.id] = test
	end

	for _, test in ipairs(tests) do
		local normalized = normalize_test(bufnr, test)
		local existing = previous[normalized.id]

		if existing and test.status == nil then
			normalized.status = existing.status
		end

		table.insert(stored, normalized)
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

-- Return tests currently known for a buffer.
function M.get_tests(bufnr)
	return tests_by_bufnr[bufnr] or {}
end

-- Return buffers that currently have discovered tests cached.
function M.test_buffers()
	local bufnrs = {}

	for bufnr, _ in pairs(tests_by_bufnr) do
		table.insert(bufnrs, bufnr)
	end

	return bufnrs
end

-- Drop all cached tests and diagnostics associated with a buffer.
function M.clear_buffer(bufnr)
	tests_by_bufnr[bufnr] = nil
	diagnostics_by_bufnr[bufnr] = nil
end

-- Drop cached diagnostics while keeping discovered tests intact.
function M.clear_diagnostics(bufnr)
	diagnostics_by_bufnr[bufnr] = nil
end

-- Reset every cached test status in the buffer back to idle.
function M.reset_statuses(bufnr)
	for _, test in ipairs(M.get_tests(bufnr)) do
		test.status = "idle"
	end
end

-- Find the test whose source range contains the given line.
function M.find_at_line(bufnr, lnum)
	for _, test in ipairs(M.get_tests(bufnr)) do
		local end_lnum = test.end_lnum or test.lnum

		if test.lnum <= lnum and lnum <= end_lnum then
			return test
		end
	end

	return nil
end

-- Find the closest cached test that starts before or on the given line.
function M.find_nearest_before_line(bufnr, lnum)
	local nearest = nil

	for _, test in ipairs(M.get_tests(bufnr)) do
		if test.lnum <= lnum and (not nearest or nearest.lnum < test.lnum) then
			nearest = test
		end
	end

	return nearest
end

-- Find a cached test that starts exactly on the given line.
function M.find_starting_at_line(bufnr, lnum)
	for _, test in ipairs(M.get_tests(bufnr)) do
		if test.lnum == lnum then
			return test
		end
	end

	return nil
end

-- Report whether a test command is currently active.
function M.is_running()
	return active_run ~= nil
end

-- Mark a run as active so concurrent runs can be rejected.
function M.start_run(tests)
	active_run = {
		tests = tests,
	}
end

-- Clear the active run marker after completion or failure.
function M.finish_run()
	active_run = nil
end

-- Store enough run metadata for run_last to recreate the selection later.
function M.set_last_run(run)
	last_run = run
end

-- Return metadata for the most recent run, if one has been recorded.
function M.get_last_run()
	return last_run
end

-- Return diagnostics currently known for a buffer.
function M.get_diagnostics(bufnr)
	return diagnostics_by_bufnr[bufnr] or {}
end

-- Return buffers that currently have diagnostics cached.
function M.diagnostic_buffers()
	local bufnrs = {}

	for bufnr, _ in pairs(diagnostics_by_bufnr) do
		table.insert(bufnrs, bufnr)
	end

	return bufnrs
end

-- Replace diagnostics for selected tests while preserving unrelated failures.
function M.apply_diagnostics(bufnr, tests, diagnostics)
	local selected = ids_for_tests(tests)
	local stored = {}
	local file = vim.api.nvim_buf_get_name(bufnr)

	for _, diagnostic in ipairs(M.get_diagnostics(bufnr)) do
		if diagnostic.test_id and not selected[diagnostic.test_id] then
			table.insert(stored, diagnostic)
		end
	end

	for _, diagnostic in ipairs(diagnostics or {}) do
		if not diagnostic.file or same_file(diagnostic.file, file) then
			table.insert(stored, normalize_diagnostic(bufnr, diagnostic))
		end
	end

	diagnostics_by_bufnr[bufnr] = stored
	return stored
end

-- Mark cached diagnostics stale after a buffer write until tests run again.
function M.mark_diagnostics_stale(bufnr)
	for _, diagnostic in ipairs(M.get_diagnostics(bufnr)) do
		diagnostic.stale = true
	end

	return M.get_diagnostics(bufnr)
end

-- Remove diagnostics linked to the supplied test ids.
function M.remove_diagnostics_for_tests(bufnr, test_ids)
	local diagnostics = M.get_diagnostics(bufnr)
	local kept = {}
	local removed = false

	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.test_id and test_ids[diagnostic.test_id] then
			removed = true
		else
			table.insert(kept, diagnostic)
		end
	end

	if removed then
		diagnostics_by_bufnr[bufnr] = kept
	end

	return removed
end

-- Remove diagnostics whose test ids no longer exist in the buffer.
function M.remove_diagnostics_for_missing_tests(bufnr)
	local existing = ids_for_tests(M.get_tests(bufnr))
	local kept = {}
	local removed = false

	for _, diagnostic in ipairs(M.get_diagnostics(bufnr)) do
		if diagnostic.test_id and not existing[diagnostic.test_id] then
			removed = true
		else
			table.insert(kept, diagnostic)
		end
	end

	if removed then
		diagnostics_by_bufnr[bufnr] = kept
	end

	return removed
end

-- Update cached line ranges after edits and clear results for changed tests.
function M.invalidate_changed_range(bufnr, start_lnum, old_end_lnum, new_end_lnum)
	local changed_tests = {}
	local changed_end_lnum = math.max(start_lnum, old_end_lnum)
	local delta = new_end_lnum - old_end_lnum

	for _, test in ipairs(M.get_tests(bufnr)) do
		local test_end = test.end_lnum or test.lnum

		if test.lnum <= changed_end_lnum and start_lnum <= test_end then
			changed_tests[test.id] = true
			test.status = "idle"
		elseif delta ~= 0 and old_end_lnum < test.lnum then
			test.lnum = math.max(test.lnum + delta, 1)
			test.end_lnum = math.max((test.end_lnum or test.lnum) + delta, test.lnum)
		end
	end

	if vim.tbl_isempty(changed_tests) then
		shift_diagnostics_after(bufnr, old_end_lnum, delta)
		return false
	end

	M.remove_diagnostics_for_tests(bufnr, changed_tests)
	shift_diagnostics_after(bufnr, old_end_lnum, delta)

	return true
end

-- Apply the same status to selected cached tests.
function M.set_status(bufnr, tests, status)
	local ids = ids_for_tests(tests)

	for _, test in ipairs(M.get_tests(bufnr)) do
		if ids[test.id] then
			test.status = status
		end
	end
end

-- Apply a run result to selected tests, deriving failed tests from diagnostics when needed.
function M.apply_result(bufnr, tests, result)
	local failed = {}
	local file = vim.api.nvim_buf_get_name(bufnr)

	for _, test in ipairs(result.failed_tests or {}) do
		if test.id then
			failed[test.id] = true
		end
	end

	for _, diagnostic in ipairs(result.diagnostics or {}) do
		if not diagnostic.file or same_file(diagnostic.file, file) then
			local test = nil

			if diagnostic.test_id then
				for _, candidate in ipairs(tests) do
					if candidate.id == diagnostic.test_id then
						test = candidate
						break
					end
				end
			end

			if not test then
				for _, candidate in ipairs(tests) do
					if diagnostic.test_name and candidate.name == diagnostic.test_name then
						test = candidate
						break
					end
				end
			end

			if not test then
				local lnum = diagnostic.lnum or 1

				for _, candidate in ipairs(tests) do
					local end_lnum = candidate.end_lnum or candidate.lnum

					if candidate.lnum <= lnum and lnum <= end_lnum then
						test = candidate
						break
					end
				end
			end

			if test then
				failed[test.id] = true
			end
		end
	end

	if not result.ok and not result.status and vim.tbl_isempty(failed) then
		for _, test in ipairs(tests) do
			failed[test.id] = true
		end
	end

	local selected = ids_for_tests(tests)

	for _, test in ipairs(M.get_tests(bufnr)) do
		if selected[test.id] then
			if result.status then
				test.status = result.status
			elseif failed[test.id] then
				test.status = "failed"
			else
				test.status = "passed"
			end
		end
	end
end

return M
