extern fn c_add(x: u32) u32;

pub fn main() void {
    if (c_add(35) != 42) @panic("C/Zig ThinLTO result mismatch");
}
