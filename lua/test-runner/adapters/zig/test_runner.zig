//! Custom Zig test-runner for running Zig tests and outputting data to
//! "TRNVIM_EVENT_DIR" as NDJSON files.
//!
//! The files use the following format (formatted here for readability):
//! ```jsonc
//! {
//!  "type": "test_fail", // can be "test_start" | "test_pass" | "test_fail" | "summary"
//!  "name": "parser handles spaces", // top level test name (may be "" if unnamed)
//!  "source_file": "/abs/src/parser.zig",
//!  "source_line": 12,
//!  "fail_file": "/abs/src/parser.zig",
//!  "fail_line": 42,
//!  "fail_column": 8,
//!  "message": "expected 4 got 5",
//! }
//! ```
//! // TODO "summary" type should have unique format.
//!
//! All events are written to "$TRNVIM_EVENT_DIR/events.jsonl".
//!

const std = @import("std");
const builtin = @import("builtin");

// const event_dir = b.graph.environ_map.get("TRNVIM_EVENT_DIR") orelse std.process.fatal("Missing 'TRNVIM_EVENT_DIR' environment variable to run custom zig build runner!");
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = Env.init(init.environ_map) catch |err| {
        std.process.fatal("Missing environment variables for custom zig test runner! (err='{s}')", .{@errorName(err)});
    };

    const events_path = try std.mem.join(gpa, "/", &.{
        env.event_dir,
        "events.jsonl",
    });
    defer gpa.free(events_path);
    const file = try std.Io.Dir.createFileAbsolute(io, events_path, .{
        .truncate = true,
    });

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const w = &writer.interface;

    for (builtin.test_functions) |t| {
        // note all tests not matching $TRNVIM_TEST_FILTER are not included in
        // `builtin.test_functions` (see `patch_build_runner.zig`)

        t.func() catch |err| {
            try emit(&.{
                .test_fail = .{},
            });
        };

        try emit(&.{
            .test_pass = .{},
        });
    }

    try emit(&.{
        .summary = .{},
    });
}

fn emit(event: *const EventObject) !void {
    _ = event;
}

const EventType = enum {
    test_fail,
    test_pass,
    summary,
};

const TestFailObject = struct {
    /// Full path of file.
    file_path: []const u8,
    /// Line of actual test (i.e. `test "..." {`)
    test_line: usize,
    /// Line of failure
    fail_line: usize,
    /// Column of failure
    fail_column: usize,
    /// Error message, e.g. "expected 4 got 5".
    message: []const u8,
};

const TestPassObject = struct {
    /// Full path of file
    file_path: []const u8,
    /// Line of actual test (i.e. `test "..." {`)
    test_line: usize,
};

const SummaryObject = struct {
    /// Total number of tests run.
    total_tests: usize,
    /// Number of tests that passed.
    passed_tests: usize,
    /// Number of tests that failed.
    failed_tests: usize,
};

const EventObject = union(EventType) {
    test_fail: TestFailObject,
    test_pass: TestPassObject,
    summary: SummaryObject,
};

const Env = struct {
    filter: ?[]const u8,
    event_dir: []const u8,

    fn init(map: *const std.process.Environ.Map) !Env {
        return .{
            .filter = readEnv(map, "TRNVIM_FILTER"),
            .event_dir = readEnv(map, "TRNVIM_EVENT_DIR") orelse return error.MissingTestRunnerEventDirectory,
        };
    }

    fn readEnv(map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
        return map.get(key);
    }

    // fn readEnvBool(map: *const std.process.Environ.Map, key: []const u8) ?bool {
    //     const value = readEnv(map, key) orelse return null;
    //     return std.ascii.eqlIgnoreCase(value, "true");
    // }
};

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}
