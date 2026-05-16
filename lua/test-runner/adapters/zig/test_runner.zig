//! Custom Zig test runner for test-runner.nvim.
//!
//! The runner executes `builtin.test_functions` directly and writes NDJSON event
//! files to `$TRNVIM_EVENT_DIR`. Each test binary writes its own file named
//! `events-<thread-id>.jsonl`, so multiple test artifacts can run without
//! writing to the same file concurrently.
//!
//! Each line is one JSON object. Current event formats:
//!
//! ```jsonc
//! { "type": "test_pass", "name": "parses input", "source_file": "/abs/src/main.zig", "source_line": 12 }
//! { "type": "test_fail", "name": "parses input", "source_file": "/abs/src/main.zig", "source_line": 12, "fail_file": "/abs/src/main.zig", "fail_line": 14, "fail_column": 8, "error_name": "TestExpectedEqual", "message": "expected 5, found 4", "related_locations": [] }
//! { "type": "adapter_issue", "message": "unable to resolve failure location for 'parses input': MissingErrorReturnTrace" }
//! { "type": "summary", "total": 3, "passed": 2, "failed": 1, "skipped": 0 }
//! ```
//!
//! Source and failure locations are resolved from Zig debug info. Lines are
//! 1-based and columns are 0-based to match Neovim diagnostics. Locations fall
//! back to `""`/`0` if unavailable, and abnormal runner issues are emitted as
//! `adapter_issue` events.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const event_dir = readRequiredEnv(init.environ_map, "TRNVIM_EVENT_DIR");
    var debug_info = DebugInfo.init(gpa);

    const events_file = try createEventsFile(io, gpa, event_dir);
    defer events_file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = events_file.writer(io, &buffer);
    const writer = &file_writer.interface;

    var results: SummaryEvent = .{};

    for (builtin.test_functions, 0..) |test_fn, index| {
        try runTest(io, gpa, writer, event_dir, test_fn, index, &results, &debug_info);
    }

    results.total = results.passed + results.failed + results.skipped;
    try emit(writer, &results);
    try writer.flush();

    if (results.failed > 0) std.process.exit(1);
}

fn runTest(
    io: std.Io,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    event_dir: []const u8,
    test_fn: std.builtin.TestFn,
    index: usize,
    results: *SummaryEvent,
    debug_info: *DebugInfo,
) !void {
    const name = testDisplayName(test_fn.name);
    const source_location = debug_info.sourceLocation(test_fn.func) catch |err| location: {
        try emitIssue(gpa, writer, "unable to resolve source location", name, err);
        break :location Location{};
    };
    defer if (source_location.file.len > 0) gpa.free(source_location.file);

    var output = try CapturedStderr.start(io, gpa, event_dir, index);

    test_fn.func() catch |err| switch (err) {
        error.SkipZigTest => {
            output.discard();
            results.skipped += 1;
            return;
        },
        else => {
            const message = std.mem.trim(u8, try output.finish(), &std.ascii.whitespace);
            const failure_location = debug_info.failureLocation(@errorReturnTrace()) catch |location_err| location: {
                try emitIssue(gpa, writer, "unable to resolve failure location", name, location_err);
                break :location Location{};
            };
            defer if (failure_location.file.len > 0) gpa.free(failure_location.file);
            const related_locations = debug_info.traceLocations(@errorReturnTrace()) catch &.{};
            defer if (related_locations.len > 0) freeLocations(gpa, related_locations);

            results.failed += 1;
            try emit(writer, &TestFailEvent{
                .name = name,
                .source_file = source_location.file,
                .source_line = source_location.line,
                .fail_file = failure_location.file,
                .fail_line = failure_location.line,
                .fail_column = failure_location.column,
                .error_name = @errorName(err),
                .message = if (message.len > 0) message else @errorName(err),
                .related_locations = related_locations,
            });
            return;
        },
    };

    output.discard();
    results.passed += 1;
    try emit(writer, &TestPassEvent{
        .name = name,
        .source_file = source_location.file,
        .source_line = source_location.line,
    });
}

fn createEventsFile(io: std.Io, gpa: std.mem.Allocator, event_dir: []const u8) !std.Io.File {
    const path = try std.fmt.allocPrint(gpa, "{s}/events-{d}.jsonl", .{
        event_dir,
        std.Thread.getCurrentId(),
    });
    defer gpa.free(path);

    return std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
}

fn emit(writer: *std.Io.Writer, event: anytype) !void {
    try std.json.fmt(event, .{}).format(writer);
    try writer.writeByte('\n');
}

fn emitIssue(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    context: []const u8,
    test_name: []const u8,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(gpa, "{s} for '{s}': {s}", .{
        context,
        test_name,
        @errorName(err),
    });
    defer gpa.free(message);

    try emit(writer, &AdapterIssueEvent{ .message = message });
}

fn testDisplayName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, name, ".test.")) |index| {
        return name[index + ".test.".len ..];
    }

    if (std.mem.lastIndexOf(u8, name, ".decltest.")) |index| {
        return name[index + ".decltest.".len ..];
    }

    return name;
}

fn readRequiredEnv(map: *const std.process.Environ.Map, key: []const u8) []const u8 {
    return map.get(key) orelse std.process.fatal("Missing {s} environment variable", .{key});
}

const Location = struct {
    file: []const u8 = "",
    line: usize = 0,
    column: usize = 0,
};

const LocationError = error{
    MissingDebugInfo,
    MissingErrorReturnTrace,
    EmptyErrorReturnTrace,
    SymbolLookupFailed,
    NoSourceLocation,
} || std.mem.Allocator.Error;

const DebugInfo = struct {
    gpa: std.mem.Allocator,
    self: ?*std.debug.SelfInfo,

    fn init(gpa: std.mem.Allocator) DebugInfo {
        return .{
            .gpa = gpa,
            .self = std.debug.getSelfDebugInfo() catch null,
        };
    }

    fn sourceLocation(debug_info: *DebugInfo, func: *const fn () anyerror!void) LocationError!Location {
        return debug_info.locationForAddress(@intFromPtr(func), true);
    }

    fn failureLocation(debug_info: *DebugInfo, maybe_trace: ?*std.builtin.StackTrace) LocationError!Location {
        const trace = maybe_trace orelse return error.MissingErrorReturnTrace;
        const len = @min(trace.index, trace.instruction_addresses.len);
        if (len == 0) return error.EmptyErrorReturnTrace;

        return debug_info.locationForAddress(trace.instruction_addresses[len - 1] -| 1, true);
    }

    fn traceLocations(debug_info: *DebugInfo, maybe_trace: ?*std.builtin.StackTrace) LocationError![]Location {
        const trace = maybe_trace orelse return error.MissingErrorReturnTrace;
        const len = @min(trace.index, trace.instruction_addresses.len);
        if (len == 0) return error.EmptyErrorReturnTrace;

        var locations: std.ArrayList(Location) = .empty;
        errdefer freeLocations(debug_info.gpa, locations.items);

        var index = len;
        while (index > 0) {
            index -= 1;
            const location = debug_info.locationForAddress(
                trace.instruction_addresses[index] -| 1,
                false,
            ) catch continue;

            try locations.append(debug_info.gpa, location);
        }

        return try locations.toOwnedSlice(debug_info.gpa);
    }

    fn locationForAddress(debug_info: *DebugInfo, address: usize, user_only: bool) LocationError!Location {
        const self = debug_info.self orelse return error.MissingDebugInfo;

        const debug_allocator = std.heap.page_allocator;
        var text_arena: std.heap.ArenaAllocator = .init(debug_allocator);
        defer text_arena.deinit();

        var symbols: std.ArrayList(std.debug.Symbol) = .empty;
        defer symbols.deinit(debug_allocator);

        self.getSymbols(
            std.Options.debug_io,
            debug_allocator,
            text_arena.allocator(),
            address,
            false,
            &symbols,
        ) catch return error.SymbolLookupFailed;

        for (symbols.items) |symbol| {
            const source = symbol.source_location orelse continue;
            if (user_only and !isUserFailureLocation(source.file_name)) continue;

            return .{
                .file = try debug_info.gpa.dupe(u8, source.file_name),
                .line = @intCast(source.line),
                .column = if (source.column > 0) @intCast(source.column - 1) else 0,
            };
        }

        return error.NoSourceLocation;
    }
};

fn freeLocations(gpa: std.mem.Allocator, locations: []const Location) void {
    for (locations) |location| {
        if (location.file.len > 0) gpa.free(location.file);
    }

    gpa.free(locations);
}

fn isUserFailureLocation(file_name: []const u8) bool {
    if (std.mem.indexOf(u8, file_name, "/lib/zig/") != null) return false;
    if (std.mem.endsWith(u8, file_name, "/test_runner.zig")) return false;
    return true;
}

const CapturedStderr = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    file: std.Io.File,
    original_stderr: std.Io.File,
    restored: bool = false,

    fn start(io: std.Io, gpa: std.mem.Allocator, event_dir: []const u8, index: usize) !CapturedStderr {
        const path = try std.fmt.allocPrint(gpa, "{s}/stderr-{d}-{d}.txt", .{
            event_dir,
            std.Thread.getCurrentId(),
            index,
        });
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = true,
        });
        const original_stderr = try duplicateFd(std.posix.STDERR_FILENO);
        try replaceFd(file.handle, std.posix.STDERR_FILENO);

        return .{
            .io = io,
            .gpa = gpa,
            .path = path,
            .file = file,
            .original_stderr = original_stderr,
        };
    }

    fn finish(capture: *CapturedStderr) ![]const u8 {
        try capture.restoreStderr();

        const stat = try capture.file.stat(capture.io);
        const contents = try capture.gpa.alloc(u8, @intCast(stat.size));
        const len = try capture.file.readPositionalAll(capture.io, contents, 0);
        capture.cleanup();

        return std.mem.trim(u8, contents[0..len], &std.ascii.whitespace);
    }

    fn discard(capture: *CapturedStderr) void {
        capture.restoreStderr() catch {};
        capture.cleanup();
    }

    fn restoreStderr(capture: *CapturedStderr) !void {
        if (capture.restored) return;

        try replaceFd(capture.original_stderr.handle, std.posix.STDERR_FILENO);
        capture.original_stderr.close(capture.io);
        capture.restored = true;
    }

    fn cleanup(capture: *CapturedStderr) void {
        capture.file.close(capture.io);
        std.Io.Dir.deleteFileAbsolute(capture.io, capture.path) catch {};
        capture.gpa.free(capture.path);
    }
};

fn duplicateFd(fd: std.posix.fd_t) !std.Io.File {
    while (true) {
        const new_fd = std.posix.system.dup(fd);
        switch (std.posix.errno(new_fd)) {
            .SUCCESS => return .{
                .handle = @intCast(new_fd),
                .flags = .{ .nonblocking = false },
            },
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn replaceFd(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    while (true) {
        const result = std.posix.system.dup2(old_fd, new_fd);
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

const TestPassEvent = struct {
    type: []const u8 = "test_pass",
    name: []const u8,
    source_file: []const u8,
    source_line: usize,
};

const TestFailEvent = struct {
    type: []const u8 = "test_fail",
    name: []const u8,
    source_file: []const u8,
    source_line: usize,
    fail_file: []const u8,
    fail_line: usize,
    fail_column: usize,
    error_name: []const u8,
    message: []const u8,
    related_locations: []const Location,
};

const AdapterIssueEvent = struct {
    type: []const u8 = "adapter_issue",
    message: []const u8,
};

const SummaryEvent = struct {
    type: []const u8 = "summary",
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};
