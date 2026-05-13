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
		return string_name
	end

	local identifier = line:match("^%s*test%s+([%a_][%w_]*)%s*[%{%:]")
	if identifier then
		return identifier
	end

	if line:match("^%s*test%s*[%{%:]") then
		return "unnamed test"
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

local function make_test(file, root, scope, name, lnum, col, end_lnum)
	return {
		id = file .. ":" .. lnum .. ":" .. name,
		name = name,
		file = file,
		root = root,
		scope = scope,
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
		return unescape_zig_string(vim.treesitter.get_node_text(name_node, bufnr))
	elseif node_type == "identifier" then
		return vim.treesitter.get_node_text(name_node, bufnr)
	elseif node_type == "block" then
		return "unnamed test"
	end

	return nil
end

local function discover_with_treesitter(bufnr, file, root, scope)
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
			local name = test_name_from_node(bufnr, node)

			if name then
				local start_row, start_col, end_row = node:range()
				local lnum = start_row + 1

				table.insert(
					tests,
					make_test(file, root, scope, name, lnum, start_col, end_row + 1)
				)
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

local function discover_with_patterns(bufnr, file, root, scope)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local tests = {}
	local previous_test = nil

	for index, line in ipairs(lines) do
		local name = test_name(line)

		if name then
			if previous_test then
				previous_test.end_lnum = index - 1
			end

			previous_test = make_test(
				file,
				root,
				scope,
				name,
				index,
				math.max((line:find("test", 1, true) or 1) - 1, 0),
				#lines
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

local function command_for(tests, root)
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

	if #tests == 1 and not tests[1].project and tests[1].scope ~= "all" then
		vim.list_extend(command, { "--test-filter", tests[1].name })
	end

	return command
end

local function event_dir_for_run()
	local event_dir = vim.fn.tempname()
	vim.fn.mkdir(event_dir, "p")
	return event_dir
end

local function env_for_run(tests, event_dir)
	local env = {
		TRNVIM_EVENT_DIR = event_dir,
		TRNVIM_TEST_RUNNER = default_test_runner(),
	}

	if #tests == 1 and not tests[1].project and tests[1].scope ~= "all" then
		env.TRNVIM_FILTER = tests[1].name
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

local function same_path(left, right)
	return left and right and vim.fs.normalize(left) == vim.fs.normalize(right)
end

local function line_in_test(test, lnum)
	return lnum and test.lnum <= lnum and lnum <= (test.end_lnum or test.lnum)
end

local function match_event_test(event, tests, root)
	local name = event_name(event)
	local source_file = event_source_file(event, root)
	local source_line = event_source_line(event)
	local failure_file = event_failure_file(event, root)
	local failure_line = event_failure_line(event)

	if #tests == 1 and not tests[1].project then
		return tests[1]
	end

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

local function add_failure(diagnostics, failed, failed_by_id, event, matched, root)
	local name = event_name(event)
	local fail_file = event_failure_file(event, root)
	local fail_line = event_failure_line(event)
	local message = event.message or "test failed"

	if matched and not matched.project and not failed_by_id[matched.id] then
		failed_by_id[matched.id] = true
		table.insert(failed, {
			id = matched.id,
			name = matched.name,
			file = matched.file,
			lnum = matched.lnum,
			col = matched.col,
			message = message,
		})
	end

	if fail_file or fail_line or matched then
		table.insert(diagnostics, {
			test_id = matched and not matched.project and matched.id or nil,
			test_name = matched and matched.name or name,
			file = fail_file or (matched and matched.file) or nil,
			lnum = fail_line or (matched and matched.lnum) or 1,
			col = event_failure_column(event),
			severity = "error",
			message = message,
		})
	end
end

local function add_adapter_issue(diagnostics, event)
	table.insert(diagnostics, {
		lnum = 1,
		col = 0,
		severity = "error",
		message = event.message or "zig adapter issue",
	})
end

local function parse_events(event_dir, tests, code, root)
	local events = read_events(event_dir)

	if vim.tbl_isempty(events) then
		return nil
	end

	local diagnostics = {}
	local failed_by_id = {}
	local failed = {}
	local seen = {}
	local failed_seen = {}
	local observed_tests = {}
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
			table.insert(observed_tests, {
				name = event_name(event),
				file = event_source_file(event, root),
				lnum = event_source_line(event),
			})
		end

		if failed_event then
			failed_seen[key] = true
		end
	end

	local function observed_matches_test(observed, test)
		if observed.file and same_path(test.file, observed.file) then
			return line_in_test(test, observed.lnum) or observed.name == test.name
		end

		return #tests == 1 and observed.name == test.name
	end

	local function has_unobserved_selected_test()
		for _, test in ipairs(tests) do
			if not test.project then
				local observed = false

				for _, observed_test in ipairs(observed_tests) do
					if observed_matches_test(observed_test, test) then
						observed = true
						break
					end
				end

				if not observed then
					return true
				end
			end
		end

		return false
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
				add_failure(
					diagnostics,
					failed,
					failed_by_id,
					event,
					match_event_test(event, tests, root),
					root
				)
			end
		elseif event_type == "adapter_issue" then
			add_adapter_issue(diagnostics, event)
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
	local has_unobserved = saw_summary and has_unobserved_selected_test()
	local ok = code == 0
		and vim.tbl_isempty(failed)
		and vim.tbl_isempty(diagnostics)
		and not has_unobserved
	local notify = nil

	if has_unobserved and effective_failed_count == 0 and vim.tbl_isempty(diagnostics) then
		notify = false
	end

	return {
		ok = ok,
		project = project_test ~= nil,
		failed_tests = failed,
		failed_count = final_failed_count,
		total_count = final_total_count,
		observed_tests = observed_tests,
		exhaustive = saw_summary,
		unobserved_message = "test-runner.nvim: unable to run test: no matching Zig test was executed. The selected test may not be included by the configured Zig test step.",
		notify = notify,
		diagnostics = diagnostics,
	}
end

local function parse_output(output, tests, code, root)
	local diagnostics = {}
	local project_test = #tests == 1 and tests[1].project and tests[1] or nil
	local first_error = nil

	for line in output:gmatch("[^\r\n]+") do
		first_error = first_error or line:match("^error: (.+)$")

		local diagnostic = parse_error(line)
		if diagnostic then
			diagnostic.file = absolute_path(root, diagnostic.file)
			first_error = first_error or diagnostic.message
		end
	end

	local ok = code == 0
	local message = nil
	local status = nil

	if code ~= 0 and first_error then
		local compile_message = "unable to run test: couldn't compile: " .. first_error
		message = compile_message
		status = "blocked"
	elseif code ~= 0 then
		message = "unable to run test: command failed before running tests"
		status = "blocked"
	end

	return {
		ok = ok,
		project = project_test ~= nil,
		failed_tests = {},
		diagnostics = diagnostics,
		message = message,
		status = status,
	}
end

-- ==================================================
-- Public API
-- ==================================================

-- Accept Zig buffers by filetype or file extension.
function M.detect(bufnr)
	return is_zig_buffer(bufnr)
end

-- Discover project runs or file-local Zig test blocks with source ranges.
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
				root = root,
				scope = ctx.scope,
				project = true,
				hidden = true,
				lnum = 1,
				col = 0,
				end_lnum = 1,
			},
		}
	end

	local tests = discover_with_treesitter(bufnr, file, root, ctx.scope)
	if tests then
		return tests
	end

	return discover_with_patterns(bufnr, file, root, ctx.scope)
end

-- Run Zig tests asynchronously and convert command output into test results.
function M.run(tests, done)
	local root = tests[1] and tests[1].root or vim.fn.getcwd()
	local command = command_for(tests, root)
	local event_dir = event_dir_for_run()
	local env = env_for_run(tests, event_dir)

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
