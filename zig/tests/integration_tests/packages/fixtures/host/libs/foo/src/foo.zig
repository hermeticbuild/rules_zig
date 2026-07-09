const bar = @import("bar");
const leaf = @import("leaflib");

pub const value: u32 = bar.value + leaf.value + 42;
