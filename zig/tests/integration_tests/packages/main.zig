const std = @import("std");
const leaf = @import("leaf");
const bottom = @import("bottom");

pub fn main() void {
    std.debug.assert(leaf.value == 7);
    std.debug.assert(bottom.value == 2);
}
