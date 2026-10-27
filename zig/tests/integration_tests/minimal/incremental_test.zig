const std = @import("std");
const input = @import("incremental_value.zig");

test "current input" {
    // The integration changes the value to 42 (passes), then 43 (fails).
    try std.testing.expect(input.value % 2 == 0);
}
