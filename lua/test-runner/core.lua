local adapters = require("test-runner.adapters")
local diagnostics = require("test-runner.diagnostics")

local M = {}

local function project_root()
	local cwd = vim.fn.getcwd()
	return vim.fs.root(cwd, { ".git" }) or cwd
end

local function current_context()
	local bufnr = vim.api.nvim_get_current_buf()
	local adapter = adapters.for_buffer(bufnr)

	if not adapter then
		vim.notify("test-runner.nvim: no adapter found", vim.log.levels.WARN)
		return nil
	end

	return {
		bufnr = bufnr,
		adapter = adapter,
		root = project_root(),
	}
end

local function run_tests(ctx, tests)
	if not tests or vim.tbl_isempty(tests) then
		vim.notify("test-runner.nvim: no tests found", vim.log.levels.WARN)
		return
	end

	diagnostics.clear(ctx.bufnr)

	ctx.adapter.run(tests, function(result)
		vim.schedule(function()
			diagnostics.set(ctx.bufnr, result.failures or {})

			if result.ok then
				vim.notify("test-runner.nvim: tests passed", vim.log.levels.INFO)
			else
				local count = #(result.failures or {})
				vim.notify("test-runner.nvim: " .. count .. " test failure(s)", vim.log.levels.WARN)
			end
		end)
	end)
end

function M.run_nearest()
	local ctx = current_context()
	if not ctx then
		return
	end

	local tests = ctx.adapter.discover({
		bufnr = ctx.bufnr,
		scope = "nearest",
		root = ctx.root,
	})
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local nearest

	for _, test in ipairs(tests) do
		if test.lnum <= cursor_lnum then
			nearest = test
		end
	end

	if not nearest then
		vim.notify("test-runner.nvim: no nearest test found", vim.log.levels.WARN)
		return
	end

	run_tests(ctx, { nearest })
end

function M.run_file()
	local ctx = current_context()
	if not ctx then
		return
	end

	run_tests(ctx, ctx.adapter.discover({
		bufnr = ctx.bufnr,
		scope = "file",
		root = ctx.root,
	}))
end

function M.run_all()
	local ctx = current_context()
	if not ctx then
		return
	end

	run_tests(ctx, ctx.adapter.discover({
		bufnr = ctx.bufnr,
		scope = "all",
		root = ctx.root,
	}))
end

function M.clear()
	diagnostics.clear(vim.api.nvim_get_current_buf())
end

return M
