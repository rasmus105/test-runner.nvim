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

local function command_for(tests)
	local opts = adapter_config()
	local command = vim.deepcopy(opts.build or { "zig", "build", "test" })

	if #tests == 1 and not tests[1].project and tests[1].scope ~= "all" and opts.filter then
		local extra = opts.filter(tests[1])

		if type(extra) == "table" then
			vim.list_extend(command, extra)
		end
	end

	return command
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

local function parse_failed_test(line, tests)
	local reported, failure = line:match("^%d+/%d+ (.-)%.%.%.FAIL%s*(.*)$")
	failure = failure or ""

	if not reported then
		reported = line:match("^error: '(.+)' failed:$")
		failure = ""
	end

	if not reported then
		return nil
	end

	local matched = nil

	for _, test in ipairs(tests) do
		local name = test.name
		local suffix = ".test." .. name

		if reported == name or reported:sub(-#suffix) == suffix then
			if not matched or #name > #matched.name then
				matched = test
			end
		end
	end

	if matched then
		return {
			id = matched.id,
			name = matched.name,
			file = matched.file,
			lnum = matched.lnum,
			col = matched.col,
			message = failure ~= "" and vim.trim(failure) or "test failed",
		}
	end

	return nil
end

local function reported_test_name(reported)
	return reported and (reported:match("^.*%.test%.(.+)$") or reported) or nil
end

local function parse_stack_frame(line)
	local file, lnum, col = line:match("^%s*(.+%.zig):(%d+):(%d+): .* in .+$")

	if not file then
		return nil
	end

	return {
		file = file,
		lnum = tonumber(lnum),
		col = math.max((tonumber(col) or 1) - 1, 0),
	}
end

local function absolute_path(root, file)
	if file:sub(1, 1) == "/" then
		return file
	end

	return vim.fs.normalize(root .. "/" .. file)
end

local function is_under_root(root, file)
	local normalized_root = vim.fs.normalize(root)
	return file == normalized_root or file:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

local function parse_summary(line)
	local passed, total, failed = line:match("(%d+)/(%d+) tests passed %((%d+) failed%)")
	if passed then
		return tonumber(total), tonumber(failed)
	end

	passed, total = line:match("(%d+)/(%d+) tests passed")
	if passed then
		return tonumber(total), 0
	end

	local run_passed, run_failed, run_total =
		line:match("run test (%d+) pass, (%d+) fail %((%d+) total%)")
	if run_passed then
		return tonumber(run_total), tonumber(run_failed)
	end

	run_passed, run_total = line:match("run test (%d+) pass %((%d+) total%)")
	if run_passed then
		return tonumber(run_total), 0
	end

	return nil, nil
end

local function parse_output(output, tests, code, root)
	local opts = adapter_config()
	local diagnostics = {}
	local failed_tests = {}
	local project_test = #tests == 1 and tests[1].project and tests[1] or nil
	local first_error = nil
	local saw_test_result = false
	local total_count = nil
	local parsed_failed_count = nil
	local observed_failed_count = 0
	local project_saw_failure_result = false
	local current_failure = nil

	for line in output:gmatch("[^\r\n]+") do
		if line:match("^%d+/%d+ .-%.%.%.") then
			saw_test_result = true
		end

		local summary_total, summary_failed = parse_summary(line)
		if summary_total then
			saw_test_result = true
			total_count = math.max(total_count or 0, summary_total)
			parsed_failed_count = math.max(parsed_failed_count or 0, summary_failed or 0)
		end

		first_error = first_error or line:match("^error: (.+)$")

		local failed = parse_failed_test(line, tests)
		if failed then
			failed_tests[failed.id] = failed
			observed_failed_count = observed_failed_count + 1
			current_failure = failed
		elseif project_test then
			local reported, failure = line:match("^%d+/%d+ (.-)%.%.%.FAIL%s*(.*)$")
			if failure then
				project_saw_failure_result = true
			else
				reported = line:match("^error: '(.+)' failed:$")
			end

			if reported and not failure and not project_saw_failure_result then
				failure = ""
			end

			if failure then
				local message = failure ~= "" and vim.trim(failure) or "test failed"
				local test_name = reported_test_name(reported)
				observed_failed_count = observed_failed_count + 1
				failed_tests[project_test.id] = failed_tests[project_test.id]
					or {
						id = project_test.id,
						name = project_test.name,
						file = project_test.file,
						project = true,
						lnum = project_test.lnum,
						col = project_test.col,
						message = message,
					}
				current_failure = {
					id = project_test.id,
					name = project_test.name,
					project = true,
					test_name = test_name,
					message = message,
				}
			end
		end

		if not failed and current_failure and current_failure.message == "test failed" then
			local message = vim.trim(line)

			if
				message ~= ""
				and not message:match("%.zig:%d+:%d+:")
				and not message:match("^failed command:")
				and not message:match("^error: '.+' failed:$")
			then
				current_failure.message = message
			end
		end

		local frame = parse_stack_frame(line)
		if current_failure and frame then
			frame.file = absolute_path(root, frame.file)

			if
				(current_failure.project and is_under_root(root, frame.file))
				or frame.file == current_failure.file
			then
				table.insert(diagnostics, {
					test_id = not current_failure.project and current_failure.id or nil,
					test_name = current_failure.project and current_failure.test_name
						or current_failure.name,
					file = frame.file,
					lnum = frame.lnum,
					col = frame.col,
					severity = "error",
					message = current_failure.message,
				})

				current_failure = nil
			end
		end

		local diagnostic = parse_error(line)
		if diagnostic then
			diagnostic.file = absolute_path(root, diagnostic.file)
			first_error = first_error or diagnostic.message
			local belongs_to_selected_file = false

			for _, test in ipairs(tests) do
				if diagnostic.file == test.file then
					belongs_to_selected_file = true
					diagnostic.test_id = test.id
					diagnostic.test_name = test.name
					break
				end
			end

			if belongs_to_selected_file and (saw_test_result or opts.compiler_diagnostics) then
				table.insert(diagnostics, diagnostic)
			end
		end
	end

	local failed = {}
	local diagnostics_by_test_id = {}

	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.test_id then
			diagnostics_by_test_id[diagnostic.test_id] = true
		end
	end

	for _, test in pairs(failed_tests) do
		table.insert(failed, test)

		if not test.project and not diagnostics_by_test_id[test.id] then
			table.insert(diagnostics, {
				test_id = test.id,
				test_name = test.name,
				file = test.file,
				lnum = test.lnum,
				col = test.col,
				severity = "error",
				message = test.message or "test failed",
			})
		end
	end

	local ok = code == 0 and vim.tbl_isempty(failed) and vim.tbl_isempty(diagnostics)
	local message = nil
	local status = nil

	local failed_by_test = not vim.tbl_isempty(failed)

	if code ~= 0 and not saw_test_result and first_error and not failed_by_test then
		local compile_message = "unable to run test: couldn't compile: " .. first_error
		message = compile_message
		status = "blocked"

		if opts.compiler_diagnostics and vim.tbl_isempty(diagnostics) then
			for _, test in ipairs(tests) do
				table.insert(diagnostics, {
					test_id = test.id,
					test_name = test.name,
					file = test.file,
					lnum = test.lnum,
					col = test.col,
					severity = "error",
					message = compile_message,
				})
			end
		elseif opts.compiler_diagnostics then
			for _, diagnostic in ipairs(diagnostics) do
				diagnostic.message = "unable to run test: couldn't compile: " .. diagnostic.message
			end
		end
	elseif code ~= 0 and not saw_test_result and not failed_by_test then
		message = "unable to run test: command failed before running tests"
		status = "blocked"
	end

	return {
		ok = ok,
		project = project_test ~= nil,
		failed_tests = failed,
		failed_count = parsed_failed_count
			or (observed_failed_count > 0 and observed_failed_count or nil),
		total_count = total_count,
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

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local tests = {}
	local previous_test = nil

	for index, line in ipairs(lines) do
		local name = test_name(line)

		if name then
			if previous_test then
				previous_test.end_lnum = index - 1
			end

			previous_test = {
				id = file .. ":" .. index .. ":" .. name,
				name = name,
				file = file,
				root = root,
				scope = ctx.scope,
				lnum = index,
				col = math.max((line:find("test", 1, true) or 1) - 1, 0),
				end_lnum = #lines,
			}

			table.insert(tests, previous_test)
		end
	end

	return tests
end

-- Run Zig tests asynchronously and convert command output into test results.
function M.run(tests, done)
	local command = command_for(tests)
	local root = tests[1] and tests[1].root or vim.fn.getcwd()

	vim.system(command, { cwd = root, text = true }, function(result)
		local output = table.concat({ result.stdout or "", result.stderr or "" }, "\n")
		done(parse_output(output, tests, result.code or 1, root))
	end)
end

return M
