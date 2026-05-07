local M = {}

local config = require("test-runner.config")
local core = require("test-runner.core")

function M.setup(opts)
	config.setup(opts)
end

function M.run_nearest()
	core.run_nearest()
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

return M
