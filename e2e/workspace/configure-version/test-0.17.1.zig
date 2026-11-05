const std = @import("std");
const builtin = @import("builtin");

test "match Zig version" {
    try std.testing.expectEqualStrings("0.17.1", builtin.zig_version_string);
}
