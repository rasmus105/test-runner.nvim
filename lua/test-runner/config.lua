local M = {}

local registry = require("test-runner.adapters.registry")

M.options = {
	enabled = true,
	adapters = {
		fake = {
			enabled = true,
		},
	},
	discovery = {
		auto = true,
		events = { "BufEnter", "BufWritePost" },
	},
	ui = {
		inline = {
			enabled = true,
			click = false,
			virt_text_pos = "eol",
			icons = {
				idle = "",
				running = "",
				passed = "",
				failed = "",
			},
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

function M.set_enabled(enabled)
	M.options.enabled = enabled
end

function M.toggle_enabled()
	M.options.enabled = not M.options.enabled
	return M.options.enabled
end

return M
