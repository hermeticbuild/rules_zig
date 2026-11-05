const std = @import("std");
const library = @import("library.zig");

test "answer" {
    try std.testing.expectEqual(42, library.answer());
}
