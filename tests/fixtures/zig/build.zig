const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Filter tests by substring");
    const source_file = if (filter) |value|
        if (std.mem.eql(u8, value, "adapter compiler error"))
            "src/compiler_error.zig"
        else if (std.mem.eql(u8, value, "adapter filename test failure"))
            "src/MyStruct.test.zig"
        else
            "src/main.zig"
    else
        "src/main.zig";

    const module = b.createModule(.{
        .root_source_file = b.path(source_file),
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

    if (filter == null) {
        const filename_test_module = b.createModule(.{
            .root_source_file = b.path("src/MyStruct.test.zig"),
            .target = target,
            .optimize = optimize,
        });

        const filename_tests = b.addTest(.{
            .root_module = filename_test_module,
        });

        const run_filename_tests = b.addRunArtifact(filename_tests);
        test_step.dependOn(&run_filename_tests.step);
    }
}
