extern fn cvardep_c() c_int;
pub fn value() c_int {
    return cvardep_c() + 100;
}
