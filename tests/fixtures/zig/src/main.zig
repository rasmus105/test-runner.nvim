const std = @import("std");

fn add(left: i32, right: i32) i32 {
    return left + right;
}

fn expectFive(value: i32) !void {
    try std.testing.expectEqual(@as(i32, 5), value);
}

test "adapter passing test" {
    try std.testing.expectEqual(@as(i32, 4), add(2, 2));
}

test "test" {
    try std.testing.expectEqual(@as(i32, 4), add(2, 2));
}

test "adapter failing test" {
    try std.testing.expectEqual(@as(i32, 5), add(2, 2));
}

test "adapter helper failing test" {
    try expectFive(add(2, 2));
}

test add {
    try std.testing.expectEqual(@as(i32, 3), add(1, 2));
}

test {
    _ = @import("compiler_error.zig");
    _ = @import("MyStruct.test.zig");
}
