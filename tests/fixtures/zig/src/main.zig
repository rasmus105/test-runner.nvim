const std = @import("std");

fn add(left: i32, right: i32) i32 {
    return left + right;
}

test "adapter passing test" {
    try std.testing.expectEqual(@as(i32, 4), add(2, 2));
}

test "adapter failing test" {
    try std.testing.expectEqual(@as(i32, 5), add(2, 2));
}

test add {
    try std.testing.expectEqual(@as(i32, 3), add(1, 2));
}
