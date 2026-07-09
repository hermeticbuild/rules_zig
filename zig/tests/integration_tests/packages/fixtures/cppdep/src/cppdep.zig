extern fn cpp_compute(c_int) c_int;

pub fn value() c_int {
    return cpp_compute(2);
}
