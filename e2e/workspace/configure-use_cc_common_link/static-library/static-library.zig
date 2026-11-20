extern fn add(u8, u8) u8;

export fn zig_add(a: u8, b: u8) u8 {
    return add(a, b);
}
