local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
local fixture = root .. "/tests/fixtures/zig"
local file = fixture .. "/src/main.zig"

vim.opt.runtimepath:prepend(root)

local config = require("test-runner.config")
local state = require("test-runner.state")
local test_runner = require("test-runner")
local zig = require("test-runner.adapters.zig")

config.setup({})

vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "zig"
local bufnr = vim.api.nvim_get_current_buf()

local tests = zig.discover({
	bufnr = bufnr,
	scope = "file",
	root = root,
})

assert(#tests == 5, "expected five discovered Zig tests")
assert(tests[1].name == "adapter passing test", "expected string test discovery")
assert(tests[2].name == "test", "expected test named like Zig output prefix")
assert(tests[3].name == "adapter failing test", "expected third string test discovery")
assert(tests[4].name == "adapter helper failing test", "expected helper failure test discovery")
assert(tests[5].name == "add", "expected doctest discovery")
assert(tests[1].root == fixture, "expected nearest build.zig root")

state.set_tests(bufnr, tests)
state.set_status(bufnr, { tests[1] }, "passed")
state.set_tests(bufnr, zig.discover({ bufnr = bufnr, scope = "file", root = root }))
assert(state.get_tests(bufnr)[1].status == "passed", "expected rediscovery to preserve status")

state.set_status(bufnr, { tests[1] }, "passed")
assert(
	state.invalidate_changed_range(bufnr, tests[1].lnum + 1, tests[1].lnum + 1, tests[1].lnum + 1)
)
assert(state.get_tests(bufnr)[1].status == "idle", "expected body edit to invalidate test status")

state.apply_diagnostics(bufnr, { tests[1] }, {
	{
		test_id = tests[1].id,
		test_name = tests[1].name,
		lnum = tests[1].lnum,
		message = "temporary diagnostic",
	},
})
test_runner.clear()
assert(#state.get_tests(bufnr) == 5, "expected clear to keep discovered tests")
assert(state.get_tests(bufnr)[1].status == "idle", "expected clear to reset test status")
assert(#state.get_diagnostics(bufnr) == 0, "expected clear to remove diagnostics")

local function run(tests_to_run)
	local result = nil

	zig.run(tests_to_run, function(run_result)
		result = run_result
	end)

	local completed = vim.wait(15000, function()
		return result ~= nil
	end, 50)

	assert(completed, "timed out waiting for Zig adapter run")
	return result
end

local function diagnostic_for(diagnostics, diagnostic_file)
	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.file == diagnostic_file then
			return diagnostic
		end
	end

	return nil
end

local function diagnostic_for_line(diagnostics, diagnostic_file, lnum)
	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.file == diagnostic_file and diagnostic.lnum == lnum then
			return diagnostic
		end
	end

	return nil
end

local passing = run({ tests[1] })
assert(passing.ok, "expected filtered passing test to pass")
assert(passing.total_count == 1, "expected filtered passing test to report Zig summary total")
assert(passing.failed_count == 0, "expected filtered passing test to report zero failures")
assert(#passing.failed_tests == 0, "expected no failed tests for passing filter")

local failing = run({ tests[3] })
assert(not failing.ok, "expected filtered failing test to fail")
assert(#failing.failed_tests == 1, "expected one failed test")
assert(failing.failed_tests[1].name == "adapter failing test", "expected failing test name")
assert(#failing.diagnostics == 1, "expected one failure diagnostic")
assert(failing.diagnostics[1].lnum > tests[3].lnum, "expected diagnostic on failing statement")
assert(
	failing.diagnostics[1].message:find("expected 5, found 4", 1, true),
	"expected Zig failure message"
)

local all = run(tests)
assert(not all.ok, "expected full fixture run to fail")
assert(#all.failed_tests == 2, "expected two failed tests in full fixture run")
assert(
	diagnostic_for_line(all.diagnostics, fixture .. "/src/main.zig", 20),
	"expected direct failure diagnostic"
)
assert(diagnostic_for_line(all.diagnostics, fixture .. "/src/main.zig", 8), "expected helper failure diagnostic")
assert(all.status == nil, "expected normal test failures not to be blocked")

local project_tests = zig.discover({
	bufnr = bufnr,
	scope = "all",
	root = root,
})

assert(#project_tests == 1, "expected project-level test for all scope")
assert(project_tests[1].project, "expected all scope to run the Zig project")
assert(project_tests[1].hidden, "expected project-level test to stay out of inline UI")
assert(project_tests[1].root == fixture, "expected project-level run from nearest build.zig root")

local project = run(project_tests)
assert(not project.ok, "expected project fixture run to fail")
assert(project.project, "expected project run result")
assert(project.total_count == 6, "expected project run to report all Zig test summaries")
assert(project.failed_count == 3, "expected project run to report all Zig failure summaries")
assert(#project.failed_tests == 1, "expected project-level failure to map to synthetic test")
assert(project.failed_tests[1].id == project_tests[1].id, "expected synthetic project test to fail")
assert(#project.diagnostics == 3, "expected project run to include source failure diagnostics")
local project_main_diagnostic = diagnostic_for(project.diagnostics, fixture .. "/src/main.zig")
assert(project_main_diagnostic, "expected project diagnostic file")
assert(project_main_diagnostic.lnum == 20, "expected project diagnostic on failing statement")
assert(
	diagnostic_for_line(project.diagnostics, fixture .. "/src/main.zig", 8),
	"expected project diagnostic on helper failure statement"
)
local project_filename_diagnostic = diagnostic_for(project.diagnostics, fixture .. "/src/MyStruct.test.zig")
assert(project_filename_diagnostic, "expected project diagnostic for filename containing test")
assert(
	project_filename_diagnostic.message ~= "error: 'MyStruct.test.test.adapter filename test failure' failed:",
	"expected project filename diagnostic to use failure detail instead of top-level Zig error"
)
assert(project_filename_diagnostic.lnum == 8, "expected project filename diagnostic on failing statement")
assert(project.status == nil, "expected project test failures not to be blocked")

state.clear_diagnostics(bufnr)
test_runner.run_all({ silent = true })
assert(
	vim.wait(15000, function()
		local diagnostics = state.get_diagnostics(bufnr)
		return #diagnostics == 2
			and diagnostic_for_line(diagnostics, fixture .. "/src/main.zig", 20)
			and diagnostic_for_line(diagnostics, fixture .. "/src/main.zig", 8)
	end, 50),
	"timed out waiting for project run source diagnostic"
)
local project_state_diagnostic = diagnostic_for_line(state.get_diagnostics(bufnr), fixture .. "/src/main.zig", 20)
local project_helper_state_diagnostic = diagnostic_for_line(state.get_diagnostics(bufnr), fixture .. "/src/main.zig", 8)
assert(
	project_state_diagnostic.message ~= "error: 'main.test.adapter failing test' failed:",
	"expected stored project diagnostic to use failure detail instead of top-level Zig error"
)
assert(
	project_state_diagnostic.message:find("expected 5, found 4", 1, true),
	"expected stored project diagnostic failure detail"
)
assert(
	project_helper_state_diagnostic.test_id == state.get_tests(bufnr)[4].id,
	"expected helper-frame diagnostic to attach to reported failed test"
)
assert(state.get_tests(bufnr)[1].status == "passed", "expected project run to mark passing test passed")
assert(state.get_tests(bufnr)[2].status == "passed", "expected project run to mark passing test passed")
assert(
	state.get_tests(bufnr)[3].status == "failed",
	"expected project run to mark failing test failed"
)
assert(
	state.get_tests(bufnr)[4].status == "failed",
	"expected project run to mark helper failing test failed"
)
assert(state.get_tests(bufnr)[5].status == "passed", "expected project run to mark passing test passed")
local loaded_filename_bufnr = vim.fn.bufnr(fixture .. "/src/MyStruct.test.zig")
assert(loaded_filename_bufnr ~= -1, "expected project run to load failed filename buffer")
local loaded_filename_diagnostics = state.get_diagnostics(loaded_filename_bufnr)
assert(#loaded_filename_diagnostics == 1, "expected project run to store diagnostic for non-current file")
assert(loaded_filename_diagnostics[1].lnum == 8, "expected non-current project diagnostic on failing statement")
assert(
	state.get_tests(loaded_filename_bufnr)[1].status == "failed",
	"expected project run to mark non-current failing test failed"
)
assert(
	#vim.diagnostic.get(loaded_filename_bufnr) == 1,
	"expected non-current project diagnostic to be published to Neovim diagnostics"
)

local original_discover = zig.discover
local original_run = zig.run

state.set_tests(bufnr, tests)
zig.discover = function(ctx)
	if ctx.scope == "all" then
		return project_tests
	end

	return original_discover(ctx)
end
zig.run = function(_, done)
	done({
		ok = true,
		project = true,
		total_count = #tests,
		failed_count = 0,
	})
end

test_runner.run_all({ silent = true })
assert(
	vim.wait(1000, function()
		return state.get_tests(bufnr)[1].status == "passed"
	end, 10),
	"timed out waiting for project run status update"
)
assert(#state.get_tests(bufnr) == 5, "expected project run to keep visible file tests")
assert(
	state.get_tests(bufnr)[1].status == "passed",
	"expected project run to mark visible tests passed"
)
assert(
	state.get_tests(bufnr)[2].status == "passed",
	"expected project run to mark visible tests passed"
)
assert(
	state.get_tests(bufnr)[3].status == "passed",
	"expected project run to mark visible tests passed"
)
assert(
	state.get_tests(bufnr)[4].status == "passed",
	"expected project run to mark visible tests passed"
)
assert(
	state.get_tests(bufnr)[5].status == "passed",
	"expected project run to mark visible tests passed"
)

zig.discover = original_discover
zig.run = original_run

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/compiler_error.zig"))
vim.bo.filetype = "zig"

local compiler_error_tests = zig.discover({
	bufnr = vim.api.nvim_get_current_buf(),
	scope = "file",
	root = root,
})

assert(#compiler_error_tests == 1, "expected compiler error fixture test")

local compiler_error = run({ compiler_error_tests[1] })
assert(not compiler_error.ok, "expected compiler error run to fail")
assert(compiler_error.message, "expected compiler error feedback message")
assert(compiler_error.status == "blocked", "expected compiler error to block the test run")
assert(
	compiler_error.message:find("unable to run test: couldn't compile", 1, true),
	"expected compiler error message"
)
assert(#compiler_error.diagnostics == 0, "expected compiler errors to stay out of diagnostics")

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/MyStruct.test.zig"))
vim.bo.filetype = "zig"

local filename_test_tests = zig.discover({
	bufnr = vim.api.nvim_get_current_buf(),
	scope = "file",
	root = root,
})

assert(#filename_test_tests == 1, "expected filename test fixture test")

local filename_test = run({ filename_test_tests[1] })
assert(not filename_test.ok, "expected filename test fixture to fail")
assert(#filename_test.failed_tests == 1, "expected filename test failure")
assert(#filename_test.diagnostics == 1, "expected filename test diagnostic")
assert(
	filename_test.diagnostics[1].file == fixture .. "/src/MyStruct.test.zig",
	"expected diagnostic to use filename containing test"
)
assert(
	filename_test.diagnostics[1].lnum == 8,
	"expected diagnostic on failing statement in filename containing test"
)
assert(
	filename_test.diagnostics[1].lnum ~= filename_test_tests[1].lnum,
	"expected diagnostic not to fall back to test declaration"
)

local filename_bufnr = vim.api.nvim_get_current_buf()
state.clear_diagnostics(filename_bufnr)
state.set_tests(filename_bufnr, filename_test_tests)
test_runner.run_all({ silent = true })
assert(
	vim.wait(15000, function()
		local diagnostics = state.get_diagnostics(filename_bufnr)
		return #diagnostics == 1 and diagnostics[1].lnum == 8
	end, 50),
	"timed out waiting for project run filename diagnostic"
)
local filename_project_state_diagnostic = state.get_diagnostics(filename_bufnr)[1]
assert(
	filename_project_state_diagnostic.message
		~= "error: 'MyStruct.test.test.adapter filename test failure' failed:",
	"expected stored filename project diagnostic to use failure detail instead of top-level Zig error"
)
assert(
	filename_project_state_diagnostic.message:find("expected 5, found 4", 1, true),
	"expected stored filename project diagnostic failure detail"
)

vim.cmd("qa!")
