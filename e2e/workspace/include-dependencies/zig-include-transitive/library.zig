const builtin = @import("builtin");

const is_zig_0_17_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 17;

const c = if (is_zig_0_17_or_later) @import("c") else @import("cimport").c;

pub const three: u8 = c.THREE;
