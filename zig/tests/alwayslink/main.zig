extern fn registered_value() c_int;

pub fn main() void {
    if (registered_value() != 7) @panic("expected the native constructor to run");
}
