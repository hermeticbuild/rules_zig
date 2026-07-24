extern fn clashb_compute(c_int) c_int;

pub fn compute(x: c_int) c_int {
    return clashb_compute(x);
}
