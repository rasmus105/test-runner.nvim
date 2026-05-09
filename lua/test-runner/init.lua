local M = {}

local config = require("test-runner.config")
local core = require("test-runner.core")

-- ==================================================
-- Public API
-- ==================================================

-- Configure options before core registers mappings, autocmds, and initial discovery.
function M.setup(opts)
	config.setup(opts)
	core.setup()
end

-- Find tests in the current buffer and render their inline state without running them.
function M.discover(opts)
	core.discover(opts)
end

-- Resolve the test nearest to the cursor, preferring the test that contains the line.
function M.run_at_cursor(opts)
	core.run_at_cursor(opts)
end

-- Discover tests in the current buffer before running that file's test scope.
function M.run_file(opts)
	core.run_file(opts)
end

-- Use the current buffer's adapter to discover and run the project-wide test scope.
function M.run_all(opts)
	core.run_all(opts)
end

-- Repeat the previous run from stored scope and selected test ids when possible.
function M.run_last(opts)
	core.run_last(opts)
end

-- Clear diagnostics and reset test status markers for the current buffer.
function M.clear()
	core.clear()
end

-- Enable the runner, then discover tests for the current buffer if possible.
function M.enable()
	core.enable()
end

-- Disable the runner and remove rendered state from buffers it has attached to.
function M.disable()
	core.disable()
end

-- Toggle the runner and apply the same side effects as enable or disable.
function M.toggle()
	core.toggle()
end

return M
