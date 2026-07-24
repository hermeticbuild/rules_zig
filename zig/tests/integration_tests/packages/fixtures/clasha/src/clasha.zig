extern fn clasha_compute(c_int) c_int;

pub fn compute(x: c_int) c_int {
    return clasha_compute(x);
}
