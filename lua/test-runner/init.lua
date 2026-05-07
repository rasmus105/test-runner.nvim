local M = {}

local config = require("test-runner.config")
local core = require("test-runner.core")

function M.setup(opts)
	config.setup(opts)
	core.setup()
end

function M.discover()
	core.discover()
end

function M.run_at_cursor()
	core.run_at_cursor()
end

function M.run_file()
	core.run_file()
end

function M.run_all()
	core.run_all()
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

function M.toggle_run_on_save()
	core.toggle_run_on_save()
end

return M
