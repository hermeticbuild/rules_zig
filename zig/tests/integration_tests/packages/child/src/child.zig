const leaf = @import("leaf");
const lib = @import("lib");
const hostuser = @import("hostuser");

pub const value: u32 = leaf.value + lib.v2 + 100;
pub const host_value: u32 = hostuser.value;
