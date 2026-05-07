const std = @import("std");

test "adapter compiler error" {
    try std.testing.expectEqual(@as(i32, 1), missingDeclaration());
}
