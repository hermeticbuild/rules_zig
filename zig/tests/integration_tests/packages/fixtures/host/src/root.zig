const foo = @import("foo");
const barlib = @import("barlib");

pub const value = foo.value + barlib.value;
