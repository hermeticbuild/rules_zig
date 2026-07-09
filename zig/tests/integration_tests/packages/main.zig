const std = @import("std");
const leaf = @import("leaf");
const bottom = @import("bottom");
const top = @import("top");
const lib = @import("lib");
const libfork = @import("libfork");
const lib2 = @import("lib2");
const pruned = @import("pruned");

pub fn main() void {
    std.debug.assert(leaf.value == 7);
    std.debug.assert(bottom.value == 2);
    std.debug.assert(top.value == 6);
    std.debug.assert(lib.v1 == 1);
    std.debug.assert(libfork.fork == 3);
    std.debug.assert(lib2.v2 == 2);
    // Its `extra.zig` and `tests/` were pruned; only the declared paths were
    // packed, so the module still resolves.
    std.debug.assert(pruned.value == 13);
}
