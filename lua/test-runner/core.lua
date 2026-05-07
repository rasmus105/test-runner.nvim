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

local function current_context(opts)
	opts = opts or {}

	if not config.options.enabled then
		if not opts.silent then
			vim.notify("test-runner.nvim: disabled", vim.log.levels.INFO)
		end
		return nil
	end

	local bufnr = vim.api.nvim_get_current_buf()
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

	diagnostics.clear(ctx.bufnr)
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
		return
	end

	local line_count = vim.api.nvim_buf_line_count(ctx.bufnr)
	line = math.max(math.min(line, line_count), 1)

	if vim.tbl_isempty(state.get_tests(ctx.bufnr)) then
		discover(ctx, "file")
	end

	local test = state.find_at_line(ctx.bufnr, line)

	if not test then
		if not opts.silent then
			vim.notify("test-runner.nvim: no test found at cursor", vim.log.levels.WARN)
		end
		return
	end

	run_tests(ctx, { test }, opts)
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
			run_test_at_line(mouse.line, { silent = true })
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

			if args.event == "BufWritePost" and config.options.run_on_save.enabled then
				M.run_file({ silent = true })
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
	run_test_at_line(vim.api.nvim_win_get_cursor(0)[1])
end

local function run(scope, opts)
	opts = opts or {}
	local ctx = current_context(opts)
	if not ctx then
		return
	end

	local tests = discover(ctx, scope)
	run_tests(ctx, tests, opts)
end

function M.run_file(opts)
	run("file", opts)
end

function M.run_all(opts)
	run("all", opts)
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

function M.toggle_run_on_save()
	local enabled = config.toggle_run_on_save()
	local status = enabled and "enabled" or "disabled"
	vim.notify("test-runner.nvim: run on save " .. status, vim.log.levels.INFO)
end

return M
