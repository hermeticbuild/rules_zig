const std = @import("std");
const builtin = @import("builtin");
extern fn c_add(x: u32) u32;

test "C dependency is linked into the Zig test runner" {
    try std.testing.expectEqual(@as(u32, 42), c_add(35));
}

test "ThinLTO uses object mode" {
    try std.testing.expectEqual(.Obj, builtin.output_mode);
}
