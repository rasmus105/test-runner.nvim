local adapters = require("test-runner.adapters")
local config = require("test-runner.config")
local decorations = require("test-runner.decorations")
local diagnostics = require("test-runner.diagnostics")
local state = require("test-runner.state")

local M = {}
local click_mapping_registered = false
local attached_buffers = {}

---@class TestRunnerRunOptions
---@field silent? boolean
---@field scope? string
---@field exact_line? boolean

-- ==================================================
-- Local Functions
-- ==================================================

local function project_root()
	local cwd = vim.fn.getcwd()
	return vim.fs.root(cwd, { ".git" }) or cwd
end

local function context_for_buffer(bufnr, opts)
	opts = opts or {}

	if not config.options.enabled then
		if not opts.silent then
			vim.notify("test-runner.nvim: disabled", vim.log.levels.INFO)
		end
		return nil
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		if not opts.silent then
			vim.notify("test-runner.nvim: buffer no longer exists", vim.log.levels.WARN)
		end
		return nil
	end

	local adapter = adapters.for_buffer(bufnr)

	if not adapter then
		if not opts.silent then
			vim.notify("test-runner.nvim: no adapter found", vim.log.levels.WARN)
		end
		return nil
	end

	return {
		bufnr = bufnr,
		adapter = adapter,
		root = project_root(),
	}
end

local function current_context(opts)
	return context_for_buffer(vim.api.nvim_get_current_buf(), opts)
end

local function test_ids(tests)
	local ids = {}

	for _, test in ipairs(tests) do
		table.insert(ids, test.id)
	end

	return ids
end

local function find_tests_by_ids(tests, ids)
	local selected = {}
	local wanted = {}

	for _, id in ipairs(ids or {}) do
		wanted[id] = true
	end

	for _, test in ipairs(tests) do
		if wanted[test.id] then
			table.insert(selected, test)
		end
	end

	return selected
end

local function notify_adapter_error(action, err, opts)
	if not opts or not opts.silent then
		vim.notify(
			"test-runner.nvim: adapter " .. action .. " failed: " .. tostring(err),
			vim.log.levels.ERROR
		)
	end
end

local function all_hidden(tests)
	for _, test in ipairs(tests or {}) do
		if not test.hidden then
			return false
		end
	end

	return not vim.tbl_isempty(tests or {})
end

local function list_contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end

	return false
end

local function buffer_for_file(file)
	if not file or file == "" then
		return nil
	end

	local bufnr = vim.fn.bufadd(vim.fs.normalize(file))

	if bufnr <= 0 then
		return nil
	end

	vim.fn.bufload(bufnr)
	return bufnr
end

local function normalize_result(result)
	result = type(result) == "table" and result or {}

	local completed = type(result.completed) == "table" and result.completed or {}
	local failed_count = result.failed_count
	local total_count = result.total_count
	local has_failure = false

	if not failed_count then
		failed_count = 0

		for _, completed_test in ipairs(completed) do
			if completed_test.status == "failed" then
				failed_count = failed_count + 1
			end
		end
	end

	for _, completed_test in ipairs(completed) do
		if completed_test.status == "failed" or completed_test.status == "blocked" then
			has_failure = true
			break
		end
	end

	total_count = total_count or #completed

	return vim.tbl_extend("force", result, {
		completed = completed,
		failed_count = failed_count,
		total_count = total_count,
		ok = not has_failure,
		message = result.message,
	})
end

local function notify_result(result, tests)
	if result.notify == false then
		return
	end

	local failed_count = result.failed_count or 0
	local total_count = result.total_count or #tests
	local passed_count = math.max(total_count - failed_count, 0)

	if result.ok then
		vim.notify("test-runner.nvim: " .. total_count .. " test(s) passed", vim.log.levels.INFO)
		return
	end

	if result.message then
		vim.notify("test-runner.nvim: " .. result.message, vim.log.levels.WARN)
		return
	end

	if failed_count == 0 then
		vim.notify("test-runner.nvim: test run did not complete", vim.log.levels.WARN)
		return
	end

	vim.notify(
		"test-runner.nvim: " .. failed_count .. " failed, " .. passed_count .. " passed",
		vim.log.levels.WARN
	)
end

local function attach_buffer(bufnr)
	if attached_buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	attached_buffers[bufnr] = true

	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, changed_bufnr, _, firstline, lastline, new_lastline)
			if not config.options.enabled then
				return
			end

			local start_lnum = firstline + 1
			local old_end_lnum = lastline
			local new_end_lnum = new_lastline

			if
				state.invalidate_changed_range(
					changed_bufnr,
					start_lnum,
					old_end_lnum,
					new_end_lnum
				)
			then
				vim.schedule(function()
					if
						not config.options.enabled or not vim.api.nvim_buf_is_valid(changed_bufnr)
					then
						return
					end

					decorations.render(changed_bufnr, state.get_tests(changed_bufnr))
					diagnostics.render(changed_bufnr, state.get_diagnostics(changed_bufnr))
				end)
			end
		end,
		on_detach = function(_, detached_bufnr)
			attached_buffers[detached_bufnr] = nil
		end,
	})
end

local function discover(ctx, scope, opts)
	opts = opts or {}
	attach_buffer(ctx.bufnr)

	local ok, tests = pcall(ctx.adapter.discover, {
		bufnr = ctx.bufnr,
		scope = scope,
		root = ctx.root,
	})

	if not ok then
		notify_adapter_error("discovery", tests, opts)
		return {}
	end

	tests = type(tests) == "table" and tests or {}

	if all_hidden(tests) then
		return tests
	end

	tests = state.set_tests(ctx.bufnr, tests)
	decorations.render(ctx.bufnr, tests)

	return tests
end

local function run_tests(ctx, tests, opts)
	opts = opts or {}

	if not tests or vim.tbl_isempty(tests) then
		if not opts.silent then
			vim.notify("test-runner.nvim: no tests found", vim.log.levels.WARN)
		end
		return
	end

	if state.is_running() then
		if not opts.silent then
			vim.notify("test-runner.nvim: test run already in progress", vim.log.levels.INFO)
		end
		return
	end

	state.set_last_run({
		scope = opts.scope or "custom",
		bufnr = ctx.bufnr,
		root = ctx.root,
		test_ids = test_ids(tests),
	})
	state.start_run(tests)
	local hidden_run = all_hidden(tests)
	local status_tests = hidden_run and state.get_tests(ctx.bufnr) or tests
	state.set_status(ctx.bufnr, status_tests, "running")
	decorations.render(ctx.bufnr, state.get_tests(ctx.bufnr))

	local done_called = false
	local blocked_by_bufnr = {}
	local blocked_count = 0

	local function remember_blocked(bufnr, blocked)
		if not blocked or vim.tbl_isempty(blocked) then
			return
		end

		blocked_by_bufnr[bufnr] = blocked_by_bufnr[bufnr] or {}

		for _, test in ipairs(blocked) do
			table.insert(blocked_by_bufnr[bufnr], test)
			blocked_count = blocked_count + 1
		end
	end

	local function diagnostics_for_buffer(result, blocked)
		local items = {}

		for _, completed_test in ipairs(result.completed or {}) do
			local failure = completed_test.failure

			if failure then
				local primary = {
					test_id = completed_test.id,
					test_name = completed_test.name,
					file = failure.file,
					lnum = failure.lnum,
					col = failure.col,
					severity = "error",
					message = failure.message,
					related = failure.related,
				}

				table.insert(items, primary)

				for _, related in ipairs(failure.related or {}) do
					table.insert(items, {
						test_id = completed_test.id,
						test_name = completed_test.name,
						file = related.file,
						lnum = related.lnum,
						col = related.col,
						severity = related.severity or "hint",
						message = related.message or failure.message,
						related_to = {
							file = failure.file,
							lnum = failure.lnum,
							col = failure.col,
							message = failure.message,
						},
					})
				end
			end

			if completed_test.status == "blocked" and completed_test.message then
				table.insert(items, {
					test_id = completed_test.id,
					test_name = completed_test.name,
					file = completed_test.file,
					lnum = completed_test.lnum or 1,
					col = completed_test.col or 0,
					severity = "warn",
					message = completed_test.message,
				})
			end
		end

		local message = "test-runner.nvim: unable to run test: no matching test was executed"

		for _, test in ipairs(blocked or {}) do
			table.insert(items, {
				test_id = test.id,
				test_name = test.name,
				file = test.file,
				lnum = test.lnum,
				col = test.col,
				severity = "warn",
				message = message,
			})
		end

		return items
	end

	local function tests_for_buffer(bufnr)
		local buffer_tests = state.get_tests(bufnr)

		if vim.tbl_isempty(buffer_tests) then
			buffer_tests = discover({
				adapter = ctx.adapter,
				bufnr = bufnr,
				root = ctx.root,
			}, "file", { silent = true })
		end

		return buffer_tests
	end

	local function diagnostic_buffers(result)
		local bufnrs = { ctx.bufnr }

		local function add_file(file)
			local bufnr = buffer_for_file(file)

			if bufnr and not list_contains(bufnrs, bufnr) then
				table.insert(bufnrs, bufnr)
			end
		end

		for _, completed_test in ipairs(result.completed or {}) do
			add_file(completed_test.file)

			if completed_test.failure then
				add_file(completed_test.failure.file)

				for _, related in ipairs(completed_test.failure.related or {}) do
					add_file(related.file)
				end
			end
		end

		if hidden_run then
			for _, bufnr in ipairs(state.diagnostic_buffers()) do
				if vim.api.nvim_buf_is_valid(bufnr) and not list_contains(bufnrs, bufnr) then
					table.insert(bufnrs, bufnr)
				end
			end

			for _, bufnr in ipairs(state.test_buffers()) do
				if vim.api.nvim_buf_is_valid(bufnr) and not list_contains(bufnrs, bufnr) then
					table.insert(bufnrs, bufnr)
				end
			end
		end

		return bufnrs
	end

	local function render_result_diagnostics(result)
		local rendered_current = false
		local current_diagnostics = {}

		for _, diagnostic_bufnr in ipairs(diagnostic_buffers(result)) do
			if vim.api.nvim_buf_is_valid(diagnostic_bufnr) then
				local diagnostic_tests = diagnostic_bufnr == ctx.bufnr
						and (hidden_run and status_tests or tests)
					or tests_for_buffer(diagnostic_bufnr)

				if hidden_run and diagnostic_bufnr ~= ctx.bufnr then
					remember_blocked(
						diagnostic_bufnr,
						state.apply_result(diagnostic_bufnr, diagnostic_tests, result)
					)

					decorations.render(diagnostic_bufnr, state.get_tests(diagnostic_bufnr))
				end

				local result_diagnostics =
					diagnostics_for_buffer(result, blocked_by_bufnr[diagnostic_bufnr])
				local stored_diagnostics =
					state.apply_diagnostics(diagnostic_bufnr, diagnostic_tests, result_diagnostics)

				diagnostics.render(diagnostic_bufnr, stored_diagnostics)

				if diagnostic_bufnr == ctx.bufnr then
					rendered_current = true
					current_diagnostics = stored_diagnostics
				end
			end
		end

		if not rendered_current then
			local diagnostic_tests = hidden_run and status_tests or tests
			local result_diagnostics = diagnostics_for_buffer(result, blocked_by_bufnr[ctx.bufnr])
			current_diagnostics =
				state.apply_diagnostics(ctx.bufnr, diagnostic_tests, result_diagnostics)
			diagnostics.render(ctx.bufnr, current_diagnostics)
		end

		return current_diagnostics
	end

	local function done(result)
		if done_called then
			return
		end

		done_called = true
		result = normalize_result(result)

		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
				state.finish_run()
				return
			end

			if hidden_run then
				remember_blocked(ctx.bufnr, state.apply_result(ctx.bufnr, status_tests, result))
			else
				remember_blocked(ctx.bufnr, state.apply_result(ctx.bufnr, tests, result))
			end
			render_result_diagnostics(result)
			state.finish_run()
			decorations.render(ctx.bufnr, state.get_tests(ctx.bufnr))

			if opts.silent then
				return
			end

			local failed_count = result.failed_count or 0
			if blocked_count > 0 and failed_count == 0 and result.notify == nil then
				result.notify = false
			end

			notify_result(result, tests)
		end)
	end

	local ok, err = pcall(ctx.adapter.run, {
		bufnr = ctx.bufnr,
		root = tests[1] and tests[1].root or ctx.root,
		scope = opts.scope or "custom",
		tests = tests,
	}, done)
	if not ok and not done_called then
		state.finish_run()
		state.set_status(ctx.bufnr, tests, "idle")
		decorations.render(ctx.bufnr, state.get_tests(ctx.bufnr))
		notify_adapter_error("run", err, opts)
	end
end

local function run_test_at_line(line, opts)
	opts = opts or {}
	local ctx = current_context(opts)
	if not ctx then
		return false
	end

	local line_count = vim.api.nvim_buf_line_count(ctx.bufnr)
	line = math.max(math.min(line, line_count), 1)

	if vim.tbl_isempty(state.get_tests(ctx.bufnr)) then
		discover(ctx, "file", opts)
	end

	local test = nil

	if opts.exact_line then
		test = state.find_starting_at_line(ctx.bufnr, line)
	else
		test = state.find_at_line(ctx.bufnr, line)
			or state.find_nearest_before_line(ctx.bufnr, line)
	end

	if not test then
		if not opts.silent then
			vim.notify("test-runner.nvim: no test found at cursor", vim.log.levels.WARN)
		end
		return false
	end

	opts.scope = opts.scope or "nearest"
	run_tests(ctx, { test }, opts)
	return true
end

local function register_click_mapping()
	if click_mapping_registered and not config.options.ui.inline.click then
		vim.keymap.del("n", "<LeftMouse>")
		click_mapping_registered = false
		return
	end

	if click_mapping_registered or not config.options.ui.inline.click then
		return
	end

	click_mapping_registered = true

	vim.keymap.set("n", "<LeftMouse>", function()
		local mouse = vim.fn.getmousepos()
		local bufnr = mouse.winid ~= 0 and vim.api.nvim_win_get_buf(mouse.winid) or 0

		if mouse.line > 0 and state.find_starting_at_line(bufnr, mouse.line) then
			vim.api.nvim_set_current_win(mouse.winid)
			local col = math.max(mouse.column - 1, 0)
			vim.api.nvim_win_set_cursor(0, { mouse.line, col })
			run_test_at_line(mouse.line, { exact_line = true, silent = true })
			return ""
		end

		return "<LeftMouse>"
	end, { desc = "Run test-runner.nvim test under mouse", expr = true })
end

local function register_autocmds()
	local group = vim.api.nvim_create_augroup("test-runner.nvim", { clear = true })
	local events = config.options.discovery.events or {}

	if type(events) == "table" and vim.tbl_isempty(events) then
		return
	end

	vim.api.nvim_create_autocmd(events, {
		group = group,
		callback = function(args)
			if not config.options.enabled or not config.options.discovery.auto then
				return
			end

			local ctx = context_for_buffer(args.buf, { silent = true })
			if not ctx then
				return
			end

			discover(ctx, "file", { silent = true })

			if args.event == "BufWritePost" then
				state.mark_diagnostics_stale(ctx.bufnr)
				state.remove_diagnostics_for_missing_tests(ctx.bufnr)
				diagnostics.render(ctx.bufnr, state.get_diagnostics(ctx.bufnr))
			end
		end,
	})
end

local function run(scope, opts)
	opts = opts or {}
	local ctx = current_context(opts)
	if not ctx then
		return
	end

	local tests = discover(ctx, scope, opts)
	if scope == "all" and all_hidden(tests) and vim.tbl_isempty(state.get_tests(ctx.bufnr)) then
		discover(ctx, "file", { silent = true })
	end

	opts.scope = scope
	run_tests(ctx, tests, opts)
end

local function clear_buffer(bufnr)
	diagnostics.clear(bufnr)
	decorations.clear(bufnr)
	state.clear_buffer(bufnr)
end

local function clear_attached_buffers()
	for bufnr, _ in pairs(attached_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			clear_buffer(bufnr)
		else
			attached_buffers[bufnr] = nil
		end
	end
end

-- ==================================================
-- Public API
-- ==================================================

---Register mappings and autocmds, then discover tests if startup discovery is enabled.
function M.setup()
	register_click_mapping()
	register_autocmds()

	if config.options.enabled and config.options.discovery.auto then
		M.discover({ silent = true })
	end
end

---Discover tests for the current buffer and render inline markers for them.
---@param opts? TestRunnerRunOptions
---@return TestRunnerTest[]? tests
function M.discover(opts)
	local ctx = current_context(opts)
	if not ctx then
		return
	end

	return discover(ctx, "file", opts)
end

---Run the test containing the cursor, or the nearest earlier test when between tests.
---@param opts? TestRunnerRunOptions
function M.run_at_cursor(opts)
	opts = opts or {}
	opts.scope = opts.scope or "nearest"
	run_test_at_line(vim.api.nvim_win_get_cursor(0)[1], opts)
end

---Discover the current buffer and run only that file's tests.
---@param opts? TestRunnerRunOptions
function M.run_file(opts)
	run("file", opts)
end

---Ask the active adapter to run its project-wide test target.
---@param opts? TestRunnerRunOptions
function M.run_all(opts)
	run("all", opts)
end

---Repeat the previous run by rediscovering the stored scope and selected test ids.
---@param opts? TestRunnerRunOptions
function M.run_last(opts)
	opts = opts or {}
	local last = state.get_last_run()

	if not last then
		if not opts.silent then
			vim.notify("test-runner.nvim: no previous test run", vim.log.levels.WARN)
		end
		return
	end

	local ctx = context_for_buffer(last.bufnr, opts)
	if not ctx then
		return
	end

	if last.scope == "nearest" then
		local tests = discover(ctx, "file", opts)
		local selected = find_tests_by_ids(tests, last.test_ids)

		if vim.tbl_isempty(selected) then
			if not opts.silent then
				vim.notify("test-runner.nvim: previous test no longer found", vim.log.levels.WARN)
			end
			return
		end

		opts.scope = "nearest"
		run_tests(ctx, selected, opts)
		return
	end

	if last.scope == "file" or last.scope == "all" then
		local tests = discover(ctx, last.scope, opts)
		opts.scope = last.scope
		run_tests(ctx, tests, opts)
		return
	end

	if not opts.silent then
		vim.notify("test-runner.nvim: previous run cannot be repeated", vim.log.levels.WARN)
	end
end

---Clear diagnostics and reset rendered test statuses in the current buffer.
function M.clear()
	local bufnr = vim.api.nvim_get_current_buf()
	diagnostics.clear(bufnr)
	state.clear_diagnostics(bufnr)
	state.reset_statuses(bufnr)
	decorations.render(bufnr, state.get_tests(bufnr))
end

---Enable runner behavior and discover tests for the current buffer.
function M.enable()
	config.set_enabled(true)
	M.discover({ silent = true })
	vim.notify("test-runner.nvim: enabled", vim.log.levels.INFO)
end

---Disable runner behavior and remove state rendered into attached buffers.
function M.disable()
	config.set_enabled(false)
	clear_attached_buffers()
	vim.notify("test-runner.nvim: disabled", vim.log.levels.INFO)
end

---Flip enabled state and apply the same discovery or cleanup side effects.
function M.toggle()
	if config.toggle_enabled() then
		M.discover({ silent = true })
		vim.notify("test-runner.nvim: enabled", vim.log.levels.INFO)
	else
		clear_attached_buffers()
		vim.notify("test-runner.nvim: disabled", vim.log.levels.INFO)
	end
end

return M
