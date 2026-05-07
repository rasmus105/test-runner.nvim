local adapters = require("test-runner.adapters")
local config = require("test-runner.config")
local decorations = require("test-runner.decorations")
local diagnostics = require("test-runner.diagnostics")
local state = require("test-runner.state")

local M = {}
local click_mapping_registered = false
local autocmds_registered = false

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

local function discover(ctx, scope)
	local tests = ctx.adapter.discover({
		bufnr = ctx.bufnr,
		scope = scope,
		root = ctx.root,
	})

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
	state.set_status(ctx.bufnr, tests, "running")
	decorations.render(ctx.bufnr, state.get_tests(ctx.bufnr))

	ctx.adapter.run(tests, function(result)
		vim.schedule(function()
			state.apply_result(ctx.bufnr, tests, result)
			state.finish_run()
			decorations.render(ctx.bufnr, state.get_tests(ctx.bufnr))
			diagnostics.set(ctx.bufnr, result.diagnostics or {})

			if opts.silent then
				return
			end

			if result.ok then
				vim.notify("test-runner.nvim: tests passed", vim.log.levels.INFO)
			else
				local count = #(result.failed_tests or {})
				vim.notify("test-runner.nvim: " .. count .. " test failure(s)", vim.log.levels.WARN)
			end
		end)
	end)
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
		discover(ctx, "file")
	end

	local test = opts.exact_line and state.find_starting_at_line(ctx.bufnr, line)
		or state.find_at_line(ctx.bufnr, line)

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
	if click_mapping_registered or not config.options.ui.inline.click then
		return
	end

	click_mapping_registered = true

	vim.keymap.set("n", "<LeftMouse>", function()
		local mouse = vim.fn.getmousepos()

		if mouse.winid ~= 0 then
			vim.api.nvim_set_current_win(mouse.winid)
		end

		if mouse.line > 0 then
			local col = math.max(mouse.column - 1, 0)
			vim.api.nvim_win_set_cursor(0, { mouse.line, col })
			run_test_at_line(mouse.line, { exact_line = true, silent = true })
		end
	end, { desc = "Run test-runner.nvim test under mouse" })
end

local function register_autocmds()
	if autocmds_registered then
		return
	end

	autocmds_registered = true

	local group = vim.api.nvim_create_augroup("test-runner.nvim", { clear = true })

	vim.api.nvim_create_autocmd(config.options.discovery.events, {
		group = group,
		callback = function(args)
			if not config.options.enabled or not config.options.discovery.auto then
				return
			end

			M.discover({ silent = true })
		end,
	})
end

function M.setup()
	register_click_mapping()
	register_autocmds()

	if config.options.enabled and config.options.discovery.auto then
		M.discover({ silent = true })
	end
end

function M.discover(opts)
	local ctx = current_context(opts)
	if not ctx then
		return
	end

	discover(ctx, "file")
end

function M.run_at_cursor()
	run_test_at_line(vim.api.nvim_win_get_cursor(0)[1], { scope = "nearest" })
end

local function run(scope, opts)
	opts = opts or {}
	local ctx = current_context(opts)
	if not ctx then
		return
	end

	local tests = discover(ctx, scope)
	opts.scope = scope
	run_tests(ctx, tests, opts)
end

function M.run_file(opts)
	run("file", opts)
end

function M.run_all(opts)
	run("all", opts)
end

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
		local tests = discover(ctx, "file")
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
		local tests = discover(ctx, last.scope)
		opts.scope = last.scope
		run_tests(ctx, tests, opts)
		return
	end

	if not opts.silent then
		vim.notify("test-runner.nvim: previous run cannot be repeated", vim.log.levels.WARN)
	end
end

function M.clear()
	local bufnr = vim.api.nvim_get_current_buf()
	diagnostics.clear(bufnr)
	decorations.clear(bufnr)
	state.clear_buffer(bufnr)
end

function M.enable()
	config.set_enabled(true)
	M.discover({ silent = true })
	vim.notify("test-runner.nvim: enabled", vim.log.levels.INFO)
end

function M.disable()
	config.set_enabled(false)
	M.clear()
	vim.notify("test-runner.nvim: disabled", vim.log.levels.INFO)
end

function M.toggle()
	if config.toggle_enabled() then
		M.discover({ silent = true })
		vim.notify("test-runner.nvim: enabled", vim.log.levels.INFO)
	else
		M.clear()
		vim.notify("test-runner.nvim: disabled", vim.log.levels.INFO)
	end
end

return M
