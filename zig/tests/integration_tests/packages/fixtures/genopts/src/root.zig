const build_options = @import("build_options");

pub const value: u32 = if (build_options.feature) 7 else 0;
