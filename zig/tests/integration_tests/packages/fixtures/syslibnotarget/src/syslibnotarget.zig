extern fn my_compute(c_int) c_int;

pub fn compute(x: c_int) c_int {
    return my_compute(x);
}
