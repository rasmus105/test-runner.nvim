if vim.g.loaded_test_runner_nvim then
	return
end

vim.g.loaded_test_runner_nvim = true

local function command(name, fn)
	vim.api.nvim_create_user_command(name, function()
		require("test-runner")[fn]()
	end, {})
end

command("TestRunnerRunAtCursor", "run_at_cursor")
command("TestRunnerDiscover", "discover")
command("TestRunnerRunFile", "run_file")
command("TestRunnerRunAll", "run_all")
command("TestRunnerClear", "clear")
command("TestRunnerEnable", "enable")
command("TestRunnerDisable", "disable")
command("TestRunnerToggle", "toggle")
command("TestRunnerToggleRunOnSave", "toggle_run_on_save")
