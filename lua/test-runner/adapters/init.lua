local config = require("test-runner.config")
local registry = require("test-runner.adapters.registry")

local M = {}

local adapters = registry.require_available()

-- ==================================================
-- Public API
-- ==================================================

-- Return the first enabled adapter that accepts the buffer.
function M.for_buffer(bufnr)
	for name, adapter in pairs(adapters) do
		if config.is_adapter_enabled(name) and (not adapter.detect or adapter.detect(bufnr)) then
			return adapter
		end
	end

	return nil
end

return M
