local M = {}

local adapter_dir = "lua/test-runner/adapters/"
local ignored = {
	init = true,
	registry = true,
}

local function adapter_name(path)
	local name = path:match("([^/]+)%.lua$")

	if not name or ignored[name] then
		return nil
	end

	return name
end

function M.available()
	local adapters = {}
	local paths = vim.api.nvim_get_runtime_file(adapter_dir .. "*.lua", true)

	for _, path in ipairs(paths) do
		local name = adapter_name(path)

		if name then
			adapters[name] = "test-runner.adapters." .. name
		end
	end

	return adapters
end

function M.require_available()
	local loaded = {}

	for name, module in pairs(M.available()) do
		loaded[name] = require(module)
	end

	return loaded
end

return M
