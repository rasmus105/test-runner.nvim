const std = @import("std");

fn value() i32 {
    return 4;
}

test "adapter filename test failure" {
    try std.testing.expectEqual(@as(i32, 5), value());
}
