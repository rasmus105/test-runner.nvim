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
//! { "type": "test_pass", "name": "parses input", "source_line": 0 }
//! { "type": "test_fail", "name": "parses input", "source_line": 0, "fail_line": 0, "fail_column": 0, "message": "expected 5, found 4" }
//! { "type": "summary", "total": 3, "passed": 2, "failed": 1, "skipped": 0 }
//! ```

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const event_dir = readRequiredEnv(init.environ_map, "TRNVIM_EVENT_DIR");

    const events_file = try createEventsFile(io, gpa, event_dir);
    defer events_file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = events_file.writer(io, &buffer);
    const writer = &file_writer.interface;

    var results: SummaryEvent = .{};

    for (builtin.test_functions, 0..) |test_fn, index| {
        try runTest(io, gpa, writer, event_dir, test_fn, index, &results);
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
) !void {
    const name = testDisplayName(test_fn.name);
    var output = try CapturedStderr.start(io, gpa, event_dir, index);

    test_fn.func() catch |err| switch (err) {
        error.SkipZigTest => {
            output.discard();
            results.skipped += 1;
            return;
        },
        else => {
            const message = try output.finish();
            results.failed += 1;
            try emit(writer, &TestFailEvent{
                .name = name,
                .source_line = 0,
                .fail_line = 0,
                .fail_column = 0,
                .message = if (message.len > 0) message else @errorName(err),
            });
            return;
        },
    };

    output.discard();
    results.passed += 1;
    try emit(writer, &TestPassEvent{
        .name = name,
        .source_line = 0,
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
    source_line: usize,
};

const TestFailEvent = struct {
    type: []const u8 = "test_fail",
    name: []const u8,
    source_line: usize,
    fail_line: usize,
    fail_column: usize,
    message: []const u8,
};

const SummaryEvent = struct {
    type: []const u8 = "summary",
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};
