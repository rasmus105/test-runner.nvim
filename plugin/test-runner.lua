if vim.g.loaded_test_runner_nvim then
  return
end

vim.g.loaded_test_runner_nvim = true

vim.api.nvim_create_user_command("TestRunnerRunNearest", function()
  require("test-runner").run_nearest()
end, {})

vim.api.nvim_create_user_command("TestRunnerRunFile", function()
  require("test-runner").run_file()
end, {})

vim.api.nvim_create_user_command("TestRunnerRunAll", function()
  require("test-runner").run_all()
end, {})

vim.api.nvim_create_user_command("TestRunnerClear", function()
  require("test-runner").clear()
end, {})
