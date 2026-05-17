const std = @import("std");

/// We assume all steps the build runner is called with, are steps to build and run tests.
/// All other steps are ignored.
pub fn patch(b: *std.Build, steps: []*std.Build.Step) void {
    const filters = b.graph.environ_map.get("TRNVIM_FILTER");
    const test_runner = b.graph.environ_map.get("TRNVIM_TEST_RUNNER") orelse
        std.process.fatal("Missing TRNVIM_TEST_RUNNER environment variable", .{});

    for (steps) |step| {
        if (step.cast(std.Build.Step.Compile)) |compile| {
            patchCompileStep(b, compile, test_runner, filters);
        } else if (step.cast(std.Build.Step.Run)) |run| {
            patchRunStep(run);
        }
    }
}

fn patchCompileStep(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    test_runner: []const u8,
    filter: ?[]const u8,
) void {
    if (!compile.kind.isTest()) return;

    if (filter) |f| {
        compile.filters = b.dupeStrings(&.{f});
    }

    compile.test_runner = .{
        .path = .{ .cwd_relative = test_runner },
        .mode = .simple,
    };
}

fn patchRunStep(run: *std.Build.Step.Run) void {
    if (run.stdio != .zig_test) return;

    run.has_side_effects = true;
    stripServerTestRunnerArgs(run);
    run.stdio = .{ .check = .empty };
    run.expectExitCode(0);
}

fn stripServerTestRunnerArgs(run: *std.Build.Step.Run) void {
    var i: usize = 0;
    while (i < run.argv.items.len) {
        if (isServerTestRunnerArg(run.argv.items[i])) {
            _ = run.argv.orderedRemove(i);
            continue;
        }

        i += 1;
    }
}

fn isServerTestRunnerArg(arg: std.Build.Step.Run.Arg) bool {
    return switch (arg) {
        .bytes => |value| std.mem.eql(u8, value, "--listen=-") or std.mem.startsWith(u8, value, "--seed=0x"),
        .lazy_path => |value| std.mem.eql(u8, value.prefix, "--cache-dir="),
        .decorated_directory => |value| std.mem.eql(u8, value.prefix, "--cache-dir="),
        else => false,
    };
}
