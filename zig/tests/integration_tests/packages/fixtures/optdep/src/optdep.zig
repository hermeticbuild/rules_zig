extern fn opt_compute(c_int) c_int;

pub fn compute(x: c_int) c_int {
    return opt_compute(x);
}
