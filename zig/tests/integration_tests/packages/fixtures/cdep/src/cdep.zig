extern fn scaled_value() c_int;
extern fn offset_value() c_int;

pub fn value() c_int {
    return scaled_value() + offset_value();
}
