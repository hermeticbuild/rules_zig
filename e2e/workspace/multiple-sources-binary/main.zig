const data = @import("data.zig");
const io = @import("io.zig");

pub fn main() void {
    io.print(data.hello_world);
}
