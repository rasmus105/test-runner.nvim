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

assert(#tests == 6, "expected six discovered Zig tests")
assert(tests[1].name == "adapter passing test", "expected string test discovery")
assert(tests[2].name == "test", "expected test named like Zig output prefix")
assert(tests[3].name == "adapter failing test", "expected third string test discovery")
assert(tests[4].name == "adapter helper failing test", "expected helper failure test discovery")
assert(tests[5].name == "add", "expected doctest discovery")
assert(tests[6].name == "unnamed test", "expected unnamed test discovery")
assert(tests[1].root == fixture, "expected nearest build.zig root")
assert(tests[1].end_lnum == 13, "expected Tree-sitter test range to end at closing brace")

local function discover_source(name, lines)
	local source_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(source_bufnr, fixture .. "/src/" .. name)
	vim.bo[source_bufnr].filetype = "zig"
	vim.api.nvim_buf_set_lines(source_bufnr, 0, -1, false, lines)

	local discovered = zig.discover({
		bufnr = source_bufnr,
		scope = "file",
		root = root,
	})

	vim.api.nvim_buf_delete(source_bufnr, { force = true })
	return discovered
end

local treesitter_tests = discover_source("treesitter_discovery.zig", {
	"fn helper() void {",
	'    test "nested false positive" {}',
	"}",
	"test",
	'"multiline name" {',
	"    try std.testing.expect(true);",
	"}",
	"test add {",
	"    try std.testing.expect(true);",
	"}",
	"test {",
	"    try std.testing.expect(true);",
	"}",
})

assert(#treesitter_tests == 3, "expected Tree-sitter discovery to ignore nested false positives")
assert(treesitter_tests[1].name == "multiline name", "expected multiline test discovery")
assert(treesitter_tests[1].lnum == 4, "expected multiline test start line")
assert(treesitter_tests[1].end_lnum == 7, "expected multiline test end line")
assert(treesitter_tests[2].name == "add", "expected identifier test discovery")
assert(treesitter_tests[2].end_lnum == 10, "expected identifier test end line")
assert(treesitter_tests[3].name == "unnamed test", "expected unnamed test discovery")

local original_get_parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function()
	error("zig parser unavailable")
end
local fallback_tests = discover_source("fallback_discovery.zig", {
	'const text = "test \\"not real\\" {}";',
	'test "regex fallback" {',
	"}",
})
vim.treesitter.get_parser = original_get_parser

assert(#fallback_tests == 1, "expected pattern fallback when Tree-sitter parser is unavailable")
assert(fallback_tests[1].name == "regex fallback", "expected fallback test discovery")

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
assert(#state.get_tests(bufnr) == 6, "expected clear to keep discovered tests")
assert(state.get_tests(bufnr)[1].status == "idle", "expected clear to reset test status")
assert(#state.get_diagnostics(bufnr) == 0, "expected clear to remove diagnostics")

local current_run_tests = nil
local last_event_dir = nil

local function run(tests_to_run)
	local result = nil
	current_run_tests = tests_to_run

	zig.run({
		bufnr = vim.api.nvim_get_current_buf(),
		root = fixture,
		scope = "custom",
		tests = tests_to_run,
	}, function(run_result)
		result = run_result
	end)

	local completed = vim.wait(15000, function()
		return result ~= nil
	end, 50)

	assert(completed, "timed out waiting for Zig adapter run")
	if last_event_dir then
		assert(not vim.uv.fs_stat(last_event_dir), "expected Zig event dir cleanup")
	end
	return result
end

local original_system = vim.system

local function event_line(event)
	return vim.json.encode(event)
end

local function write_event_file(event_dir, name, events)
	local lines = {}

	for _, event in ipairs(events) do
		table.insert(lines, event_line(event))
	end

	vim.fn.writefile(lines, event_dir .. "/" .. name)
end

local function write_events(event_dir, event_files)
	if event_files[1] and event_files[1].type then
		write_event_file(event_dir, "events.jsonl", event_files)
		return
	end

	for name, events in pairs(event_files) do
		write_event_file(event_dir, name, events)
	end
end

vim.system = function(command, opts, callback)
	assert(command[1] == "zig", "expected Zig command")
	assert(command[2] == "build", "expected zig build")
	assert(command[3] == "--build-runner", "expected build runner flag")
	assert(
		command[4]:match("/lua/test%-runner/adapters/zig/build_runner%.zig$"),
		"expected bundled build runner"
	)
	assert(command[5] == "test", "expected configured test step")
	assert(command[6] == nil, "expected no default build args")
	assert(opts.env.TRNVIM_EVENT_DIR, "expected event dir env")
	assert(
		opts.env.TRNVIM_TEST_RUNNER:match("/lua/test%-runner/adapters/zig/test_runner%.zig$"),
		"expected bundled test runner env"
	)
	last_event_dir = opts.env.TRNVIM_EVENT_DIR

	local selected = current_run_tests or {}
	local filter = opts.env.TRNVIM_FILTER
	local event_files = {}
	local code = 0
	local stderr = ""

	if filter == "adapter compiler error" then
		event_files = {
			{ type = "summary", total = 0, failed = 0 },
		}
	elseif filter == "adapter passing test" then
		event_files = {
			{ type = "test_pass", name = filter, source_file = file, source_line = 11 },
			{ type = "summary", total = 1, failed = 0 },
		}
	elseif filter == "adapter issue" then
		code = 1
		event_files = {
			{ type = "adapter_issue", message = "unable to resolve source location" },
			{ type = "summary", total = 0, failed = 0 },
		}
	elseif filter == "adapter failing test" then
		code = 1
		event_files = {
			{
				type = "test_fail",
				name = filter,
				source_file = file,
				source_line = 19,
				fail_file = file,
				fail_line = 20,
				fail_column = 4,
				message = "expected 5, found 4",
			},
			{ type = "summary", total = 1, failed = 1 },
		}
	elseif filter == "adapter filename test failure" then
		code = 1
		event_files = {
			{
				type = "test_fail",
				name = filter,
				source_file = fixture .. "/src/MyStruct.test.zig",
				source_line = 7,
				fail_file = fixture .. "/src/MyStruct.test.zig",
				fail_line = 8,
				fail_column = 4,
				message = "expected 5, found 4",
			},
			{ type = "summary", total = 1, failed = 1 },
		}
	elseif selected[1] and selected[1].project then
		code = 1
		event_files = {
			["events-main.jsonl"] = {
				{
					type = "test_pass",
					name = "adapter passing test",
					source_file = file,
					source_line = 11,
				},
				{ type = "test_pass", name = "test", source_file = file, source_line = 15 },
				{
					type = "test_fail",
					name = "adapter failing test",
					source_file = file,
					source_line = 19,
					fail_file = file,
					fail_line = 20,
					fail_column = 4,
					message = "expected 5, found 4",
				},
				{
					type = "test_fail",
					name = "adapter helper failing test",
					source_file = file,
					source_line = 23,
					fail_file = file,
					fail_line = 24,
					fail_column = 4,
					message = "expected 5, found 4",
				},
				{ type = "test_pass", name = "add", source_file = file, source_line = 27 },
				{ type = "test_pass", name = "main.test_0", source_file = file, source_line = 31 },
				{ type = "summary", total = 6, failed = 2 },
			},
			["events-filename.jsonl"] = {
				{
					type = "test_fail",
					name = "adapter filename test failure",
					source_file = fixture .. "/src/MyStruct.test.zig",
					source_line = 7,
					fail_file = fixture .. "/src/MyStruct.test.zig",
					fail_line = 8,
					fail_column = 4,
					message = "expected 5, found 4",
				},
				{ type = "summary", total = 1, failed = 1 },
			},
		}
	else
		code = 1
		event_files = {
			{
				type = "test_pass",
				name = "adapter passing test",
				source_file = file,
				source_line = 11,
			},
			{ type = "test_pass", name = "test", source_file = file, source_line = 15 },
			{
				type = "test_fail",
				name = "adapter failing test",
				source_file = file,
				source_line = 19,
				fail_file = file,
				fail_line = 20,
				fail_column = 4,
				message = "expected 5, found 4",
			},
			{
				type = "test_fail",
				name = "adapter helper failing test",
				source_file = file,
				source_line = 23,
				fail_file = file,
				fail_line = 24,
				fail_column = 4,
				message = "expected 5, found 4",
			},
			{ type = "test_pass", name = "add", source_file = file, source_line = 27 },
			{ type = "test_pass", name = "main.test_0", source_file = file, source_line = 31 },
			{ type = "summary", total = 6, failed = 2 },
		}
	end

	if not vim.tbl_isempty(event_files) then
		write_events(opts.env.TRNVIM_EVENT_DIR, event_files)
	end

	vim.schedule(function()
		callback({ code = code, stdout = "", stderr = stderr })
	end)
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

local function diagnostic_with_severity(diagnostics, severity)
	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.severity == severity then
			return diagnostic
		end
	end

	return nil
end

local function completed_with_status(result, status)
	local completed = {}

	for _, completed_test in ipairs(result.completed or {}) do
		if completed_test.status == status then
			table.insert(completed, completed_test)
		end
	end

	return completed
end

local function failures_for(result)
	local failures = {}

	for _, completed_test in ipairs(result.completed or {}) do
		if completed_test.failure then
			table.insert(failures, completed_test.failure)
		end
	end

	return failures
end

local passing = run({ tests[1] })
assert(passing.total_count == 1, "expected filtered passing test to report Zig summary total")
assert(passing.failed_count == 0, "expected filtered passing test to report zero failures")
assert(#completed_with_status(passing, "passed") == 1, "expected passing completion")

local adapter_issue = run({
	vim.tbl_extend("force", tests[1], {
		id = file .. ":adapter issue",
		name = "adapter issue",
	}),
})
assert(
	#completed_with_status(adapter_issue, "blocked") == 1,
	"expected adapter issue to block the run"
)
assert(
	completed_with_status(adapter_issue, "blocked")[1].message:find(
		"unable to resolve source location",
		1,
		true
	),
	"expected adapter issue message"
)

local failing = run({ tests[3] })
local failing_tests = completed_with_status(failing, "failed")
local failing_diagnostics = failures_for(failing)
assert(#failing_tests == 1, "expected one failed test")
assert(failing_tests[1].name == "adapter failing test", "expected failing test name")
assert(#failing_diagnostics == 1, "expected one failure diagnostic")
assert(failing_diagnostics[1].lnum > tests[3].lnum, "expected diagnostic on failing statement")
assert(failing_diagnostics[1].col == 4, "expected zero-based Zig failure column")
assert(
	failing_diagnostics[1].message:find("expected 5, found 4", 1, true),
	"expected Zig failure message"
)

local all = run(tests)
local all_failures = failures_for(all)
assert(#completed_with_status(all, "failed") == 2, "expected two failed tests in full fixture run")
assert(
	diagnostic_for_line(all_failures, fixture .. "/src/main.zig", 20),
	"expected direct failure diagnostic"
)
assert(
	diagnostic_for_line(all_failures, fixture .. "/src/main.zig", 24),
	"expected helper failure diagnostic"
)

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
assert(project.total_count == 7, "expected project run to report all Zig test summaries")
assert(project.failed_count == 3, "expected project run to report all Zig failure summaries")
local project_failures = failures_for(project)
assert(#completed_with_status(project, "failed") == 3, "expected project run failed completions")
assert(#project_failures == 3, "expected project run to include source failure diagnostics")
local project_main_diagnostic = diagnostic_for(project_failures, fixture .. "/src/main.zig")
assert(project_main_diagnostic, "expected project diagnostic file")
assert(project_main_diagnostic.lnum == 20, "expected project diagnostic on failing statement")
assert(project_main_diagnostic.col == 4, "expected project diagnostic zero-based column")
assert(
	diagnostic_for_line(project_failures, fixture .. "/src/main.zig", 24),
	"expected project diagnostic on helper failure statement"
)
local project_filename_diagnostic =
	diagnostic_for(project_failures, fixture .. "/src/MyStruct.test.zig")
assert(project_filename_diagnostic, "expected project diagnostic for filename containing test")
assert(
	project_filename_diagnostic.message
		~= "error: 'MyStruct.test.test.adapter filename test failure' failed:",
	"expected project filename diagnostic to use failure detail instead of top-level Zig error"
)
assert(
	project_filename_diagnostic.lnum == 8,
	"expected project filename diagnostic on failing statement"
)
assert(project_filename_diagnostic.col == 4, "expected filename diagnostic zero-based column")

state.clear_diagnostics(bufnr)
test_runner.run_all({ silent = true })
assert(
	vim.wait(15000, function()
		local diagnostics = state.get_diagnostics(bufnr)
		return #diagnostics == 2
			and diagnostic_for_line(diagnostics, fixture .. "/src/main.zig", 20)
			and diagnostic_for_line(diagnostics, fixture .. "/src/main.zig", 24)
	end, 50),
	"timed out waiting for project run source diagnostic"
)
local project_state_diagnostic =
	diagnostic_for_line(state.get_diagnostics(bufnr), fixture .. "/src/main.zig", 20)
local project_helper_state_diagnostic =
	diagnostic_for_line(state.get_diagnostics(bufnr), fixture .. "/src/main.zig", 24)
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
assert(
	state.get_tests(bufnr)[1].status == "passed",
	"expected project run to mark passing test passed"
)
assert(
	state.get_tests(bufnr)[2].status == "passed",
	"expected project run to mark passing test passed"
)
assert(
	state.get_tests(bufnr)[3].status == "failed",
	"expected project run to mark failing test failed"
)
assert(
	state.get_tests(bufnr)[4].status == "failed",
	"expected project run to mark helper failing test failed"
)
assert(
	state.get_tests(bufnr)[5].status == "passed",
	"expected project run to mark passing test passed"
)
local loaded_filename_bufnr = vim.fn.bufnr(fixture .. "/src/MyStruct.test.zig")
assert(loaded_filename_bufnr ~= -1, "expected project run to load failed filename buffer")
local loaded_filename_diagnostics = state.get_diagnostics(loaded_filename_bufnr)
assert(
	#loaded_filename_diagnostics == 1,
	"expected project run to store diagnostic for non-current file"
)
assert(
	loaded_filename_diagnostics[1].lnum == 8,
	"expected non-current project diagnostic on failing statement"
)
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
		completed = vim.tbl_map(function(test)
			return {
				id = test.id,
				name = test.name,
				file = test.file,
				lnum = test.lnum,
				status = "passed",
			}
		end, tests),
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
assert(#state.get_tests(bufnr) == 6, "expected project run to keep visible file tests")
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
assert(
	state.get_tests(bufnr)[6].status == "passed",
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
assert(compiler_error.total_count == 0, "expected unexecuted compiler error run summary")
assert(compiler_error.failed_count == 0, "expected unexecuted compiler error to report no failures")
assert(
	#completed_with_status(compiler_error, "blocked") == 1,
	"expected compiler error test to be blocked"
)
assert(
	completed_with_status(compiler_error, "blocked")[1].message:find(
		"no matching Zig test was executed",
		1,
		true
	),
	"expected compiler error unobserved help message"
)

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/MyStruct.test.zig"))
vim.bo.filetype = "zig"

local filename_test_tests = zig.discover({
	bufnr = vim.api.nvim_get_current_buf(),
	scope = "file",
	root = root,
})

assert(#filename_test_tests == 1, "expected filename test fixture test")

local filename_test = run({ filename_test_tests[1] })
local filename_failures = failures_for(filename_test)
assert(#completed_with_status(filename_test, "failed") == 1, "expected filename test failure")
assert(#filename_failures == 1, "expected filename test diagnostic")
assert(
	filename_failures[1].file == fixture .. "/src/MyStruct.test.zig",
	"expected diagnostic to use filename containing test"
)
assert(
	filename_failures[1].lnum == 8,
	"expected diagnostic on failing statement in filename containing test"
)
assert(filename_failures[1].col == 4, "expected filename diagnostic zero-based column")
assert(
	filename_failures[1].lnum ~= filename_test_tests[1].lnum,
	"expected diagnostic not to fall back to test declaration"
)

local filename_bufnr = vim.api.nvim_get_current_buf()
state.clear_diagnostics(filename_bufnr)
state.set_tests(filename_bufnr, filename_test_tests)
current_run_tests = project_tests
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

vim.system = original_system
last_event_dir = nil

vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "zig"

local real_tests = zig.discover({
	bufnr = vim.api.nvim_get_current_buf(),
	scope = "file",
	root = root,
})

local real_passing = run({ real_tests[1] })
assert(
	#completed_with_status(real_passing, "failed") == 0,
	"expected real filtered passing Zig run to pass"
)
assert(real_passing.total_count == 2, "expected real filtered passing Zig summary")

local real_project_tests = zig.discover({
	bufnr = vim.api.nvim_get_current_buf(),
	scope = "all",
	root = root,
})

local real_project = run(real_project_tests)
assert(real_project.total_count == 7, "expected real project run to report Zig summaries")
assert(real_project.failed_count == 3, "expected real project run to report Zig failures")
local real_project_failures = failures_for(real_project)
assert(
	diagnostic_for_line(real_project_failures, fixture .. "/src/main.zig", 20),
	"expected real project direct failure diagnostic"
)
assert(
	diagnostic_for_line(real_project_failures, fixture .. "/src/main.zig", 20).col == 4,
	"expected real project direct failure zero-based column"
)
assert(
	diagnostic_for_line(real_project_failures, fixture .. "/src/main.zig", 24),
	"expected real project helper failure diagnostic"
)
assert(
	diagnostic_for_line(real_project_failures, fixture .. "/src/main.zig", 24).col == 4,
	"expected real project helper failure zero-based column"
)
assert(
	#(diagnostic_for_line(real_project_failures, fixture .. "/src/main.zig", 20).related or {}) > 0,
	"expected real project direct failure to include related trace hints"
)

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/MyStruct.test.zig"))
vim.bo.filetype = "zig"
local real_filename_tests = zig.discover({
	bufnr = vim.api.nvim_get_current_buf(),
	scope = "file",
	root = root,
})
local real_filename = run({ real_filename_tests[1] })
assert(real_filename.total_count == 2, "expected real filename run summary")
assert(real_filename.failed_count == 1, "expected real filename failure count")
assert(#real_filename.completed == 2, "expected filename and import tests to be completed")
assert(#completed_with_status(real_filename, "failed") == 1, "expected real filename failed test")
assert(#failures_for(real_filename) == 1, "expected real filename diagnostic")

vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "zig"
bufnr = vim.api.nvim_get_current_buf()
real_tests = zig.discover({
	bufnr = bufnr,
	scope = "file",
	root = root,
})

local notifications = {}
local original_notify = vim.notify

vim.notify = function(message, level, opts)
	table.insert(notifications, { message = message, level = level, opts = opts })
end

local function clear_notifications()
	notifications = {}
end

local function last_notification()
	return notifications[#notifications] and notifications[#notifications].message or ""
end

local function run_at_line(lnum)
	clear_notifications()
	vim.api.nvim_win_set_cursor(0, { lnum, 0 })
	test_runner.run_at_cursor()

	assert(
		vim.wait(15000, function()
			return not state.is_running() and #notifications > 0
		end, 50),
		"timed out waiting for cursor run notification"
	)

	return last_notification()
end

state.clear_diagnostics(bufnr)
state.set_tests(bufnr, real_tests)

local cursor_passing_message = run_at_line(11)
assert(
	cursor_passing_message:find("2 test%(s%) passed"),
	"expected cursor passing run to report two passed tests, got: " .. cursor_passing_message
)
assert(state.get_tests(bufnr)[1].status == "passed", "expected cursor passing run status")

local cursor_between_tests_message = run_at_line(14)
assert(
	cursor_between_tests_message:find("2 test%(s%) passed"),
	"expected nearest previous test run to report two passed tests, got: "
		.. cursor_between_tests_message
)

local cursor_doctest_message = run_at_line(27)
assert(
	cursor_doctest_message:find("2 test%(s%) passed"),
	"expected cursor doctest run to report two passed tests, got: " .. cursor_doctest_message
)

local cursor_failing_message = run_at_line(19)
assert(
	cursor_failing_message:find("1 failed, 1 passed"),
	"expected cursor failing run to report one failed test, got: " .. cursor_failing_message
)
assert(state.get_tests(bufnr)[3].status == "failed", "expected cursor failing run status")
local cursor_failure = diagnostic_for_line(state.get_diagnostics(bufnr), file, 20)
assert(cursor_failure, "expected cursor failure diagnostic")
assert(#(cursor_failure.related or {}) > 0, "expected cursor failure related trace hints")
local related_bufnr = vim.fn.bufnr(cursor_failure.related[1].file)
assert(related_bufnr ~= -1, "expected related trace buffer to be loaded")
local related_hint = diagnostic_with_severity(state.get_diagnostics(related_bufnr), "hint")
assert(related_hint, "expected related trace hint diagnostic")
assert(
	related_hint.related_to.lnum == cursor_failure.lnum,
	"expected hint to reference primary error"
)

clear_notifications()
test_runner.run_all()
assert(
	vim.wait(15000, function()
		return not state.is_running() and #notifications > 0
	end, 50),
	"timed out waiting for run-all notification"
)
assert(
	last_notification():find("3 failed, 4 passed"),
	"expected run-all notification to aggregate project results, got: " .. last_notification()
)

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/untracked.zig"))
vim.bo.filetype = "zig"
local untracked_bufnr = vim.api.nvim_get_current_buf()
local untracked_tests = zig.discover({
	bufnr = untracked_bufnr,
	scope = "file",
	root = root,
})

assert(#untracked_tests == 2, "expected untracked fixture tests")
state.set_tests(untracked_bufnr, untracked_tests)

clear_notifications()
vim.api.nvim_win_set_cursor(0, { 3, 0 })
test_runner.run_at_cursor()
assert(
	vim.wait(15000, function()
		local diagnostics = state.get_diagnostics(untracked_bufnr)
		return not state.is_running()
			and state.get_tests(untracked_bufnr)[1].status == "blocked"
			and #diagnostics == 1
			and diagnostics[1].severity == "warn"
	end, 50),
	"timed out waiting for unexecuted cursor test warning"
)
assert(#notifications == 0, "expected unexecuted cursor run to avoid notifications")
assert(
	state
		.get_diagnostics(untracked_bufnr)[1].message
		:find("no matching Zig test was executed", 1, true),
	"expected unexecuted cursor warning help text"
)

state.clear_diagnostics(untracked_bufnr)
state.reset_statuses(untracked_bufnr)
test_runner.run_all({ silent = true })
assert(
	vim.wait(15000, function()
		local diagnostics = state.get_diagnostics(untracked_bufnr)
		local tests = state.get_tests(untracked_bufnr)
		return not state.is_running()
			and tests[1].status == "blocked"
			and tests[2].status == "blocked"
			and #diagnostics == 2
			and diagnostics[1].severity == "warn"
			and diagnostics[2].severity == "warn"
	end, 50),
	"timed out waiting for unexecuted run-all warnings"
)

vim.notify = original_notify

vim.cmd("qa!")
