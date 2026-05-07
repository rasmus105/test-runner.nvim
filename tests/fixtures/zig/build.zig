const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Filter tests by substring");
    const compiler_error = if (filter) |value|
        std.mem.eql(u8, value, "adapter compiler error")
    else
        false;

    const module = b.createModule(.{
        .root_source_file = b.path(if (compiler_error) "src/compiler_error.zig" else "src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = module,
        .filters = if (filter) |value| &.{value} else &.{},
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
