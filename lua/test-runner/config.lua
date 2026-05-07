local M = {}

local registry = require("test-runner.adapters.registry")

M.options = {
	adapters = {
		fake = {
			enabled = true,
		},
	},
}

local function validate(opts)
	local available_adapters = registry.available()

	for name, _ in pairs(opts.adapters or {}) do
		if not available_adapters[name] then
			error("test-runner.nvim: unsupported adapter `" .. name .. "`", 2)
		end
	end
end

function M.setup(opts)
	validate(opts or {})
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

function M.is_adapter_enabled(name)
	local adapter_config = M.options.adapters[name]
	return adapter_config and adapter_config.enabled ~= false
end

return M
