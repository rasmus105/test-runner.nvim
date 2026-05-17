local config = require("test-runner.config")

local M = {}

M.name = "zig"

-- ==================================================
-- Local Functions
-- ==================================================

local function adapter_config()
	return config.options.adapters.zig or {}
end

local function is_zig_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return vim.bo[bufnr].filetype == "zig" or name:match("%.zig$") ~= nil
end

local function test_name(line)
	local string_name = line:match('^%s*test%s+"([^"]+)"%s*[%{%:]')
	if string_name then
		return string_name, "test"
	end

	local identifier = line:match("^%s*test%s+([%a_][%w_]*)%s*[%{%:]")
	if identifier then
		return identifier, "decltest"
	end

	if line:match("^%s*test%s*[%{%:]") then
		return "unnamed test", "unnamed_test"
	end

	return nil
end

local function unescape_zig_string(text)
	if type(text) ~= "string" or text:sub(1, 1) ~= '"' or text:sub(-1) ~= '"' then
		return text
	end

	local ok, decoded = pcall(vim.json.decode, text)
	if ok and type(decoded) == "string" then
		return decoded
	end

	local escapes = {
		n = "\n",
		r = "\r",
		t = "\t",
		["\\"] = "\\",
		['"'] = '"',
		["'"] = "'",
	}
	local inner = text:sub(2, -2)

	inner = inner:gsub("\\x(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)

	inner = inner:gsub("\\u%{(%x+)%}", function(hex)
		local codepoint = tonumber(hex, 16)

		if not codepoint then
			return "\\u{" .. hex .. "}"
		end

		return vim.fn.nr2char(codepoint)
	end)

	local unescaped = inner:gsub("\\(.)", function(value)
		return escapes[value] or value
	end)

	return unescaped
end

local function make_test(file, name, lnum, col, end_lnum, zig_kind)
	return {
		id = file .. ":" .. lnum .. ":" .. name,
		name = name,
		zig_kind = zig_kind,
		file = file,
		lnum = lnum,
		col = col,
		end_lnum = end_lnum,
	}
end

local function test_name_from_node(bufnr, node)
	local name_node = node:named_child(0)

	if not name_node then
		return nil
	end

	local node_type = name_node:type()

	if node_type == "string" then
		return unescape_zig_string(vim.treesitter.get_node_text(name_node, bufnr)), "test"
	elseif node_type == "identifier" then
		return vim.treesitter.get_node_text(name_node, bufnr), "decltest"
	elseif node_type == "block" then
		return "unnamed test", "unnamed_test"
	end

	return nil
end

local function discover_with_treesitter(bufnr, file)
	if not vim.treesitter or not vim.treesitter.get_parser then
		return nil
	end

	local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "zig")
	if not parser_ok or not parser then
		return nil
	end

	local parse_ok, trees = pcall(function()
		return parser:parse()
	end)

	if not parse_ok or not trees or not trees[1] then
		return nil
	end

	local tests = {}

	local function walk(node)
		if node:type() == "test_declaration" then
			local name, zig_kind = test_name_from_node(bufnr, node)

			if name then
				local start_row, start_col, end_row = node:range()
				local lnum = start_row + 1

				table.insert(tests, make_test(file, name, lnum, start_col, end_row + 1, zig_kind))
			end
		end

		for index = 0, node:named_child_count() - 1 do
			walk(node:named_child(index))
		end
	end

	walk(trees[1]:root())

	table.sort(tests, function(left, right)
		if left.lnum == right.lnum then
			return left.col < right.col
		end

		return left.lnum < right.lnum
	end)

	return tests
end

local function discover_with_patterns(bufnr, file)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local tests = {}
	local previous_test = nil

	for index, line in ipairs(lines) do
		local name, zig_kind = test_name(line)

		if name then
			if previous_test then
				previous_test.end_lnum = index - 1
			end

			previous_test = make_test(
				file,
				name,
				index,
				math.max((line:find("test", 1, true) or 1) - 1, 0),
				#lines,
				zig_kind
			)

			table.insert(tests, previous_test)
		end
	end

	return tests
end

local function adapter_dir()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fn.fnamemodify(source, ":p:h")
end

local function default_build_runner()
	return adapter_dir() .. "/zig/build_runner.zig"
end

local function default_test_runner()
	return adapter_dir() .. "/zig/test_runner.zig"
end

local function build_zig_exists(root)
	return vim.uv.fs_stat(root .. "/build.zig") ~= nil
end

local function zig_test_filter(test)
	if test.zig_kind == "test" then
		return ".test." .. test.name
	elseif test.zig_kind == "decltest" then
		return ".decltest." .. test.name
	elseif test.zig_kind == "unnamed_test" then
		return nil
	end

	return test.name
end

local function root_for_run(ctx, tests)
	local file = tests[1] and tests[1].file

	if file and file ~= "" then
		return vim.fs.root(vim.fs.dirname(file), { "build.zig" }) or ctx.root or vim.fn.getcwd()
	end

	return ctx.root or vim.fn.getcwd()
end

local function command_for(tests, root, scope)
	local opts = adapter_config()
	local step = opts.step or "test"
	local test_runner = default_test_runner()

	if build_zig_exists(root) then
		local command = {
			"zig",
			"build",
			"--build-runner",
			default_build_runner(),
			step,
		}

		if type(opts.build_args) == "table" then
			vim.list_extend(command, opts.build_args)
		end

		return command
	end

	local file = tests[1] and tests[1].file
	local command = { "zig", "test", file or "", "--test-runner", test_runner }

	if #tests == 1 and not tests[1].project and scope ~= "all" then
		local filter = zig_test_filter(tests[1])

		if filter then
			vim.list_extend(command, { "--test-filter", filter })
		end
	end

	return command
end

local function event_dir_for_run()
	local event_dir = vim.fn.tempname()
	vim.fn.mkdir(event_dir, "p")
	return event_dir
end

local function env_for_run(tests, event_dir, scope)
	local env = {
		TRNVIM_EVENT_DIR = event_dir,
		TRNVIM_TEST_RUNNER = default_test_runner(),
	}

	if #tests == 1 and not tests[1].project and scope ~= "all" then
		env.TRNVIM_FILTER = zig_test_filter(tests[1])
		env.TRNVIM_FILTER_FILE = tests[1].file
		env.TRNVIM_FILTER_LINE = tostring(tests[1].lnum)
	end

	return env
end

local function cleanup_event_dir(event_dir)
	if event_dir and event_dir ~= "" then
		vim.fn.delete(event_dir, "rf")
	end
end

local function parse_error(line)
	local file, lnum, col, severity, message = line:match("^(.+%.zig):(%d+):(%d+): (%w+): (.+)$")

	if not file then
		return nil
	end

	return {
		file = file,
		lnum = tonumber(lnum),
		col = math.max((tonumber(col) or 1) - 1, 0),
		severity = severity == "note" and "info" or "error",
		message = message,
	}
end

local function absolute_path(root, file)
	if file:sub(1, 1) == "/" then
		return file
	end

	return vim.fs.normalize(root .. "/" .. file)
end

local function event_path(root, file)
	if not file or file == "" then
		return nil
	end

	return absolute_path(root, file)
end

local function event_name(event)
	return event.name
end

local function event_source_file(event, root)
	return event_path(root, event.source_file)
end

local function event_source_line(event)
	return tonumber(event.source_line)
end

local function event_failure_file(event, root)
	return event_path(root, event.fail_file)
end

local function event_failure_line(event)
	return tonumber(event.fail_line)
end

local function event_failure_column(event)
	return tonumber(event.fail_column) or 0
end

local function event_error_name(event)
	if type(event.error_name) == "string" and event.error_name ~= "" then
		return event.error_name
	end

	return nil
end

local function event_error_label(event)
	local error_name = event_error_name(event)

	if error_name then
		return "error." .. error_name
	end

	return "error"
end

local same_path

function same_path(left, right)
	return left and right and vim.fs.normalize(left) == vim.fs.normalize(right)
end

local function line_in_test(test, lnum)
	return lnum and test.lnum <= lnum and lnum <= (test.end_lnum or test.lnum)
end

local function path_is_under(root, file)
	if not root or not file then
		return false
	end

	local normalized_root = vim.fs.normalize(root)
	local normalized = vim.fs.normalize(file)
	return normalized == normalized_root
		or normalized:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

local function frame_kind(file, root)
	if same_path(file, default_test_runner()) then
		return "runner"
	end

	if path_is_under(root, file) then
		return "project"
	end

	return "external"
end

local function trace_locations(event, root)
	local locations = {}

	for _, location in ipairs(event.related_locations or {}) do
		local file = event_path(root, location.file)
		local lnum = tonumber(location.line)
		local col = tonumber(location.column) or 0

		if file and lnum then
			table.insert(locations, {
				file = file,
				lnum = lnum,
				col = col,
				frame_kind = frame_kind(file, root),
			})
		end
	end

	return locations
end

local function deepest_trace_location(locations, wanted_kind)
	for index = #locations, 1, -1 do
		if locations[index].frame_kind == wanted_kind then
			return locations[index]
		end
	end

	return nil
end

local function deepest_non_runner_location(locations)
	for index = #locations, 1, -1 do
		if locations[index].frame_kind ~= "runner" then
			return locations[index]
		end
	end

	return nil
end

local function event_failure_location(event, root, locations)
	locations = locations or trace_locations(event, root)

	local location = deepest_trace_location(locations, "project")
		or deepest_non_runner_location(locations)

	if location then
		return location
	end

	local file = event_failure_file(event, root) or event_source_file(event, root)

	return {
		file = file,
		lnum = event_failure_line(event) or event_source_line(event),
		col = event_failure_column(event),
		frame_kind = frame_kind(file, root),
	}
end

local function related_message(event)
	return "propagated " .. event_error_label(event)
end

local function event_related_locations(event, root, failure, locations)
	local related = {}

	for _, location in ipairs(locations or trace_locations(event, root)) do
		if
			location.frame_kind == "project"
			and not (
				same_path(location.file, failure.file)
				and location.lnum == failure.lnum
				and location.col == failure.col
			)
		then
			table.insert(related, {
				file = location.file,
				lnum = location.lnum,
				col = location.col,
				severity = "hint",
				message = related_message(event),
			})
		end
	end

	return related
end

local function match_event_test(event, tests, root)
	local name = event_name(event)
	local source_file = event_source_file(event, root)
	local source_line = event_source_line(event)
	local failure_file = event_failure_file(event, root)
	local failure_line = event_failure_line(event)

	if source_file and source_line then
		for _, test in ipairs(tests) do
			if same_path(test.file, source_file) and line_in_test(test, source_line) then
				return test
			end
		end
	end

	if source_file and name then
		for _, test in ipairs(tests) do
			if test.name == name and same_path(test.file, source_file) then
				return test
			end
		end
	end

	if failure_file and name then
		for _, test in ipairs(tests) do
			if test.name == name and same_path(test.file, failure_file) then
				return test
			end
		end
	end

	if name then
		local matched = nil

		for _, test in ipairs(tests) do
			if test.name == name then
				if matched then
					matched = nil
					break
				end

				matched = test
			end
		end

		if matched then
			return matched
		end
	end

	if failure_file and failure_line then
		for _, test in ipairs(tests) do
			if same_path(test.file, failure_file) and line_in_test(test, failure_line) then
				return test
			end
		end
	end

	if #tests == 1 and not tests[1].project and not source_file and not failure_file then
		return tests[1]
	end

	return nil
end

local function read_events(event_dir)
	local events = {}
	local files = vim.fn.glob(event_dir .. "/*.jsonl", false, true)

	table.sort(files)

	for _, file in ipairs(files) do
		local ok, lines = pcall(vim.fn.readfile, file)

		if ok then
			for _, line in ipairs(lines) do
				if vim.trim(line) ~= "" then
					local decoded_ok, event = pcall(vim.json.decode, line)

					if decoded_ok and type(event) == "table" then
						table.insert(events, event)
					end
				end
			end
		end
	end

	return events
end

local function completed_from_event(event, matched, status, root)
	local name = event_name(event)
	local source_file = event_source_file(event, root)
	local source_line = event_source_line(event)
	local completed = {
		id = matched and not matched.project and matched.id or nil,
		name = matched and matched.name or name,
		file = (matched and matched.file) or source_file or event_failure_file(event, root),
		lnum = (matched and matched.lnum) or source_line or event_failure_line(event),
		status = status,
	}

	if status == "failed" then
		local trace = trace_locations(event, root)
		local failure_location = event_failure_location(event, root, trace)
		local fail_file = failure_location.file or source_file or completed.file
		local fail_line = failure_location.lnum or source_line or completed.lnum or 1

		completed.failure = {
			file = fail_file,
			lnum = fail_line,
			col = failure_location.col or 0,
			message = event.message or "test failed",
		}
		completed.failure.related = event_related_locations(event, root, completed.failure, trace)
	end

	return completed
end

local function blocked_completion(test, message)
	return {
		id = test.id,
		name = test.name,
		file = test.file,
		lnum = test.lnum,
		status = "blocked",
		message = message,
	}
end

local function add_project_failure(completed, project_test)
	table.insert(completed, {
		id = project_test.id,
		name = project_test.name,
		file = project_test.file,
		lnum = project_test.lnum,
		status = "failed",
		failure = {
			file = project_test.file,
			lnum = project_test.lnum,
			col = project_test.col,
			message = "test failed",
		},
	})
end

local function add_failure(failed, failed_by_id, event, matched)
	if matched and not matched.project and not failed_by_id[matched.id] then
		failed_by_id[matched.id] = true
		table.insert(failed, {
			id = matched.id,
			name = matched.name,
			file = matched.file,
			lnum = matched.lnum,
			col = matched.col,
			message = event.message or "test failed",
		})
	end
end

local function add_adapter_issue(issues, event)
	table.insert(issues, event.message or "zig adapter issue")
end

local function parse_events(event_dir, tests, code, root)
	local events = read_events(event_dir)

	if vim.tbl_isempty(events) then
		return nil
	end

	local failed_by_id = {}
	local failed = {}
	local seen = {}
	local failed_seen = {}
	local completed = {}
	local issues = {}
	local total_count = 0
	local failed_count = 0
	local saw_summary = false
	local project_test = #tests == 1 and tests[1].project and tests[1] or nil

	local function seen_key(event)
		return table.concat({
			event_name(event) or "",
			event.source_file or "",
			tostring(event.source_line or ""),
		}, "\0")
	end

	local function mark_seen(event, failed_event)
		local key = seen_key(event)

		if not seen[key] then
			seen[key] = true
			table.insert(
				completed,
				completed_from_event(
					event,
					match_event_test(event, tests, root),
					failed_event and "failed" or "passed",
					root
				)
			)
		end

		if failed_event then
			failed_seen[key] = true
		end
	end

	local function completed_matches_test(completed_test, test)
		if completed_test.id and completed_test.id == test.id then
			return true
		end

		if completed_test.file and same_path(test.file, completed_test.file) then
			return line_in_test(test, completed_test.lnum) or completed_test.name == test.name
		end

		return false
	end

	local function add_blocked_selected_tests(message)
		local added = false

		for _, test in ipairs(tests) do
			if not test.project then
				local did_complete = false

				for _, completed_test in ipairs(completed) do
					if completed_matches_test(completed_test, test) then
						did_complete = true
						break
					end
				end

				if not did_complete then
					table.insert(completed, blocked_completion(test, message))
					added = true
				end
			end
		end

		return added
	end

	for _, event in ipairs(events) do
		local event_type = event.type

		if event_type == "summary" then
			saw_summary = true
			total_count = total_count + (tonumber(event.total) or 0)
			failed_count = failed_count + (tonumber(event.failed) or 0)
		elseif event_type == "test_pass" or event_type == "test_fail" then
			mark_seen(event, event_type == "test_fail")

			if event_type == "test_fail" then
				add_failure(failed, failed_by_id, event, match_event_test(event, tests, root))
			end
		elseif event_type == "adapter_issue" then
			add_adapter_issue(issues, event)
		end
	end

	local observed_total = 0
	for _ in pairs(seen) do
		observed_total = observed_total + 1
	end

	local observed_failed = 0
	for _ in pairs(failed_seen) do
		observed_failed = observed_failed + 1
	end

	local effective_failed_count = saw_summary and failed_count or observed_failed

	if project_test and effective_failed_count > 0 then
		table.insert(failed, {
			id = project_test.id,
			name = project_test.name,
			file = project_test.file,
			project = true,
			lnum = project_test.lnum,
			col = project_test.col,
			message = "test failed",
		})
	end

	local final_failed_count = saw_summary and failed_count
		or (effective_failed_count > 0 and effective_failed_count or nil)
	local final_total_count = saw_summary and total_count
		or (observed_total > 0 and observed_total or nil)
	local blocked_message = issues[1]
		or "test-runner.nvim: unable to run test: no matching Zig test was executed. The selected test may not be included by the configured Zig test step."
	local has_blocked = saw_summary and add_blocked_selected_tests(blocked_message)
	local ok = code == 0 and vim.tbl_isempty(failed) and vim.tbl_isempty(issues) and not has_blocked
	local notify = nil

	if has_blocked and not project_test then
		notify = false
		final_failed_count = 0
		final_total_count = 0
	end

	if project_test and effective_failed_count > 0 and vim.tbl_isempty(completed) then
		add_project_failure(completed, project_test)
	end

	return {
		completed = completed,
		failed_count = final_failed_count,
		total_count = final_total_count,
		message = not ok and issues[1] or nil,
		notify = notify,
	}
end

local function parse_output(output, tests, code, root)
	local failures = {}
	local project_test = #tests == 1 and tests[1].project and tests[1] or nil
	local first_error = nil

	for line in output:gmatch("[^\r\n]+") do
		first_error = first_error or line:match("^error: (.+)$")

		local diagnostic = parse_error(line)
		if diagnostic then
			diagnostic.file = absolute_path(root, diagnostic.file)
			table.insert(failures, {
				file = diagnostic.file,
				lnum = diagnostic.lnum,
				col = diagnostic.col,
				message = diagnostic.message,
			})
			first_error = first_error or diagnostic.message
		end
	end

	local message = nil

	if code == 0 then
		message =
			"test-runner.nvim: unable to run test: no matching Zig test was executed. The selected test may not be included by the configured Zig test step."
	elseif first_error then
		message = "unable to run test: couldn't compile: " .. first_error
	else
		message = "unable to run test: command failed before running tests"
	end

	local completed = {}
	for index, test in ipairs(tests) do
		table.insert(completed, {
			id = test.id,
			name = test.name,
			file = test.file,
			lnum = test.lnum,
			status = "blocked",
			message = message,
			failure = failures[index] or failures[1],
		})
	end

	local notify = nil
	if code == 0 or project_test then
		notify = false
	end

	return {
		completed = completed,
		message = message,
		notify = notify,
	}
end

-- ==================================================
-- Public API
-- ==================================================

---Accept Zig buffers by filetype or file extension.
---@param bufnr integer
---@return boolean accepted
function M.detect(bufnr)
	return is_zig_buffer(bufnr)
end

---Discover project runs or file-local Zig test blocks with source ranges.
---@param ctx TestRunnerContext
---@return TestRunnerTest[] tests
function M.discover(ctx)
	local bufnr = ctx.bufnr
	local file = vim.api.nvim_buf_get_name(bufnr)
	local root = vim.fs.root(vim.fs.dirname(file), { "build.zig" }) or ctx.root

	if ctx.scope == "all" then
		return {
			{
				id = root .. ":zig build test",
				name = "zig build test",
				file = file,
				project = true,
				hidden = true,
				lnum = 1,
				col = 0,
				end_lnum = 1,
			},
		}
	end

	local tests = discover_with_treesitter(bufnr, file)
	if tests then
		return tests
	end

	return discover_with_patterns(bufnr, file)
end

---Run Zig tests asynchronously and convert command output into test results.
---@param ctx TestRunnerRunContext
---@param done fun(result: TestRunnerResult)
function M.run(ctx, done)
	local tests = ctx.tests or {}
	local root = root_for_run(ctx, tests)
	local scope = ctx.scope or "custom"
	local command = command_for(tests, root, scope)
	local event_dir = event_dir_for_run()
	local env = env_for_run(tests, event_dir, scope)

	vim.system(command, { cwd = root, text = true, env = env }, function(result)
		vim.schedule(function()
			local ok, run_result = pcall(function()
				local output = table.concat({ result.stdout or "", result.stderr or "" }, "\n")
				local event_result = parse_events(event_dir, tests, result.code or 1, root)
				return event_result or parse_output(output, tests, result.code or 1, root)
			end)

			cleanup_event_dir(event_dir)

			if not ok then
				error(run_result)
			end

			done(run_result)
		end)
	end)
end

return M
