extern fn cpp_scale(value: c_uint) c_uint;

export fn zig_eval(value: c_uint) c_uint {
    return cpp_scale(value) +% value +% 10;
}
