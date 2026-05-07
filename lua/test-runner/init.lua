local M = {}

local config = require("test-runner.config")
local core = require("test-runner.core")

function M.setup(opts)
	config.setup(opts)
	core.setup()
end

function M.discover(opts)
	core.discover(opts)
end

function M.run_at_cursor(opts)
	core.run_at_cursor(opts)
end

function M.run_file(opts)
	core.run_file(opts)
end

function M.run_all(opts)
	core.run_all(opts)
end

function M.run_last(opts)
	core.run_last(opts)
end

function M.clear()
	core.clear()
end

function M.enable()
	core.enable()
end

function M.disable()
	core.disable()
end

function M.toggle()
	core.toggle()
end

return M
