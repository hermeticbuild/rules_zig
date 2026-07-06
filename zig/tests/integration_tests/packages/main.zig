const std = @import("std");
const leaf = @import("leaf");

pub fn main() void {
    std.debug.assert(leaf.value == 7);
}
