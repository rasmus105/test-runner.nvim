local config = require("test-runner.config")
local registry = require("test-runner.adapters.registry")

local M = {}

local adapters = registry.require_available()

---@class TestRunnerContext
---@field bufnr integer
---@field scope string
---@field root string

---@class TestRunnerAdapter
---@field name string
---@field detect? fun(bufnr: integer): boolean
---@field discover fun(ctx: TestRunnerContext): TestRunnerTest[]
---@field run fun(tests: TestRunnerTest[], done: fun(result: TestRunnerResult))

-- ==================================================
-- Public API
-- ==================================================

---Return the first enabled adapter that accepts the buffer.
---@param bufnr integer
---@return TestRunnerAdapter? adapter
function M.for_buffer(bufnr)
	for name, adapter in pairs(adapters) do
		if config.is_adapter_enabled(name) and (not adapter.detect or adapter.detect(bufnr)) then
			return adapter
		end
	end

	return nil
end

return M
