extern fn amalg_value(x: c_int) c_int;
extern fn linkamalg_scaled(x: c_int) c_int;

pub fn value() c_int {
    return amalg_value(21);
}

pub fn scaled() c_int {
    return linkamalg_scaled(10);
}
