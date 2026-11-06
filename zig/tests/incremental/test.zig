const std = @import("std");

test "answer" {
    try std.testing.expectEqual(42, 6 * 7);
}
