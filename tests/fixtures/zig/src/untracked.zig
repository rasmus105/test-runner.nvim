const std = @import("std");

test "this should not be runnable" {
    const add2with2 = 2 + 2;
    std.testing.expectEqual(5, add2with2);
}

test "this shouldn't be runnable either" {
    std.testing.expectEqual(4, 4);
}
