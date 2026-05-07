local M = {}

local registry = require("test-runner.adapters.registry")

M.options = {
	-- Set to false to disable discovery, commands, diagnostics, and decorations.
	enabled = true,
	adapters = {
		fake = {
			enabled = false,
		},
		zig = {
			enabled = true,

			-- Base command used for every Zig test run.
			build = { "zig", "build", "test" },

			-- When true, compiler errors are also shown as diagnostics.
			compiler_diagnostics = false,

			-- Called when running one non-project test. Return extra arguments
			-- appended to `build`.
			--
			-- `test` has this shape:
			-- {
			--   id = string,
			--   name = string,
			--   file = string,
			--   root = string,
			--   scope = "nearest" | "file" | "all",
			--   lnum = number,
			--   col = number,
			--   end_lnum = number,
			-- }
			filter = function(test)
				return { "-Dtest-filter=" .. test.name }
			end,
		},
	},
	discovery = {
		-- Discover tests automatically when opening or writing buffers.
		auto = true,
		events = { "BufEnter", "BufWritePost" },
	},
	ui = {
		inline = {
			-- Show inline status icons next to discovered tests.
			enabled = true,
			click = false,
			virt_text_pos = "eol",
			icons = {
				idle = "",
				running = "",
				passed = "",
				failed = "",
				blocked = "",
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
