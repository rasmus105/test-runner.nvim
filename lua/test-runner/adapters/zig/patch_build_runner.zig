const std = @import("std");

// ====================================================================================================
// Public API
// ====================================================================================================

/// We assume all steps the build runner is called with, are steps to build and run tests.
/// All other steps are ignored.
pub fn patch(b: *std.Build, steps: []*std.Build.Step) void {
    const filter = b.graph.environ_map.get("TRNVIM_FILTER");

    for (steps) |step| {
        const compile = step.cast(std.Build.Step.Compile) orelse continue;
        if (!compile.kind.isTest()) continue;

        if (filter) |f| {
            compile.filters = b.dupeStrings(&.{f});
        }

        compile.test_runner = .{
            .path = .{ .cwd_relative = "test_runner.zig" },
            .mode = .simple, // simple "start, run tests, close" lifecycle.
        };
    }
}
