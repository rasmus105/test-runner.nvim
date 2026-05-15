local M = {}

local tests_by_bufnr = {}
local diagnostics_by_bufnr = {}
local active_run = nil
local last_run = nil

---@alias TestRunnerStatus "idle"|"running"|"passed"|"failed"|"blocked"|"skipped"

---@class TestRunnerTest
---@field id string
---@field name string
---@field file string
---@field root? string
---@field scope? string
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field status? TestRunnerStatus
---@field hidden? boolean
---@field project? boolean

---@class TestRunnerRelatedDiagnostic
---@field message? string
---@field file string
---@field lnum integer
---@field col integer
---@field severity? "error"|"warn"|"info"|"hint"

---@class TestRunnerFailure
---@field message string
---@field file string
---@field lnum integer
---@field col integer
---@field related? TestRunnerRelatedDiagnostic[]

---@class TestCompleted
---@field id? string
---@field name string
---@field file string
---@field lnum? integer
---@field status TestRunnerStatus
---@field message? string
---@field failure? TestRunnerFailure

---@class TestRunnerResult
---@field completed TestCompleted[]
---@field failed_count? integer
---@field total_count? integer
---@field message? string
---@field notify? boolean

---@class TestRunnerDiagnostic
---@field test_id? string
---@field test_name? string
---@field file string
---@field lnum integer
---@field col integer
---@field severity? "error"|"warn"|"info"|"hint"
---@field message string
---@field stale? boolean
---@field related? TestRunnerRelatedDiagnostic[]
---@field related_to? table

---@class TestRunnerLastRun
---@field scope string
---@field bufnr integer
---@field root string
---@field test_ids string[]

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

local function line_in_test(test, lnum)
	lnum = tonumber(lnum)
	return lnum ~= nil and test.lnum <= lnum and lnum <= (test.end_lnum or test.lnum)
end

local function completed_matches_test(completed, test, tests)
	if completed.id and completed.id == test.id then
		return true
	end

	if same_file(completed.file, test.file) then
		if line_in_test(test, completed.lnum) then
			return true
		end

		if completed.name == test.name then
			return true
		end
	end

	return false
end

local function completed_by_test_id(tests, completed_tests)
	local completed = {}

	for _, test in ipairs(tests) do
		for _, completed_test in ipairs(completed_tests or {}) do
			if completed_matches_test(completed_test, test, tests) then
				completed[test.id] = completed_test
				break
			end
		end
	end

	return completed
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

---Store normalized tests for a buffer while preserving existing statuses by id.
---@param bufnr integer
---@param tests TestRunnerTest[]
---@return TestRunnerTest[] tests
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

---Return tests currently known for a buffer.
---@param bufnr integer
---@return TestRunnerTest[] tests
function M.get_tests(bufnr)
	return tests_by_bufnr[bufnr] or {}
end

---Return buffers that currently have discovered tests cached.
---@return integer[] bufnrs
function M.test_buffers()
	local bufnrs = {}

	for bufnr, _ in pairs(tests_by_bufnr) do
		table.insert(bufnrs, bufnr)
	end

	return bufnrs
end

---Drop all cached tests and diagnostics associated with a buffer.
---@param bufnr integer
function M.clear_buffer(bufnr)
	tests_by_bufnr[bufnr] = nil
	diagnostics_by_bufnr[bufnr] = nil
end

---Drop cached diagnostics while keeping discovered tests intact.
---@param bufnr integer
function M.clear_diagnostics(bufnr)
	diagnostics_by_bufnr[bufnr] = nil
end

---Reset every cached test status in the buffer back to idle.
---@param bufnr integer
function M.reset_statuses(bufnr)
	for _, test in ipairs(M.get_tests(bufnr)) do
		test.status = "idle"
	end
end

---Find the test whose source range contains the given line.
---@param bufnr integer
---@param lnum integer
---@return TestRunnerTest? test
function M.find_at_line(bufnr, lnum)
	for _, test in ipairs(M.get_tests(bufnr)) do
		local end_lnum = test.end_lnum or test.lnum

		if test.lnum <= lnum and lnum <= end_lnum then
			return test
		end
	end

	return nil
end

---Find the closest cached test that starts before or on the given line.
---@param bufnr integer
---@param lnum integer
---@return TestRunnerTest? test
function M.find_nearest_before_line(bufnr, lnum)
	local nearest = nil

	for _, test in ipairs(M.get_tests(bufnr)) do
		if test.lnum <= lnum and (not nearest or nearest.lnum < test.lnum) then
			nearest = test
		end
	end

	return nearest
end

---Find a cached test that starts exactly on the given line.
---@param bufnr integer
---@param lnum integer
---@return TestRunnerTest? test
function M.find_starting_at_line(bufnr, lnum)
	for _, test in ipairs(M.get_tests(bufnr)) do
		if test.lnum == lnum then
			return test
		end
	end

	return nil
end

---Report whether a test command is currently active.
---@return boolean running
function M.is_running()
	return active_run ~= nil
end

---Mark a run as active so concurrent runs can be rejected.
---@param tests TestRunnerTest[]
function M.start_run(tests)
	active_run = {
		tests = tests,
	}
end

---Clear the active run marker after completion or failure.
function M.finish_run()
	active_run = nil
end

---Store enough run metadata for run_last to recreate the selection later.
---@param run TestRunnerLastRun
function M.set_last_run(run)
	last_run = run
end

---Return metadata for the most recent run, if one has been recorded.
---@return TestRunnerLastRun? run
function M.get_last_run()
	return last_run
end

---Return diagnostics currently known for a buffer.
---@param bufnr integer
---@return TestRunnerDiagnostic[] diagnostics
function M.get_diagnostics(bufnr)
	return diagnostics_by_bufnr[bufnr] or {}
end

---Return buffers that currently have diagnostics cached.
---@return integer[] bufnrs
function M.diagnostic_buffers()
	local bufnrs = {}

	for bufnr, _ in pairs(diagnostics_by_bufnr) do
		table.insert(bufnrs, bufnr)
	end

	return bufnrs
end

---Replace diagnostics for selected tests while preserving unrelated failures.
---@param bufnr integer
---@param tests TestRunnerTest[]
---@param diagnostics TestRunnerDiagnostic[]
---@return TestRunnerDiagnostic[] diagnostics
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

---Mark cached diagnostics stale after a buffer write until tests run again.
---@param bufnr integer
---@return TestRunnerDiagnostic[] diagnostics
function M.mark_diagnostics_stale(bufnr)
	for _, diagnostic in ipairs(M.get_diagnostics(bufnr)) do
		diagnostic.stale = true
	end

	return M.get_diagnostics(bufnr)
end

---Remove diagnostics linked to the supplied test ids.
---@param bufnr integer
---@param test_ids table<string, boolean>
---@return boolean removed
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

---Remove diagnostics whose test ids no longer exist in the buffer.
---@param bufnr integer
---@return boolean removed
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

---Update cached line ranges after edits and clear results for changed tests.
---@param bufnr integer
---@param start_lnum integer
---@param old_end_lnum integer
---@param new_end_lnum integer
---@return boolean invalidated
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

---Apply the same status to selected cached tests.
---@param bufnr integer
---@param tests TestRunnerTest[]
---@param status TestRunnerStatus
function M.set_status(bufnr, tests, status)
	local ids = ids_for_tests(tests)

	for _, test in ipairs(M.get_tests(bufnr)) do
		if ids[test.id] then
			test.status = status
		end
	end
end

---Apply a run result to selected tests, returning tests that did not complete.
---@param bufnr integer
---@param tests TestRunnerTest[]
---@param result TestRunnerResult
---@return TestRunnerTest[] blocked
function M.apply_result(bufnr, tests, result)
	local selected = ids_for_tests(tests)
	local completed = completed_by_test_id(tests, result.completed)
	local blocked = {}

	for _, test in ipairs(M.get_tests(bufnr)) do
		if selected[test.id] then
			local completed_test = completed[test.id]

			if completed_test then
				test.status = completed_test.status
			else
				test.status = "blocked"
				table.insert(blocked, test)
			end
		end
	end

	return blocked
end

return M
