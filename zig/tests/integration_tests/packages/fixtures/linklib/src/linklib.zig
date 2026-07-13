extern fn scaled(x: c_int) c_int;

pub fn value() c_int {
    return scaled(7);
}
