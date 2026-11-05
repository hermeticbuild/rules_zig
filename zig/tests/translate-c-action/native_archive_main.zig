extern fn native_answer() c_int;

pub fn main() void {
    if (native_answer() != 42) @panic("unexpected native result");
}
