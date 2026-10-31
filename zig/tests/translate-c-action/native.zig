extern fn answer() c_int;

export fn native_answer() c_int {
    return answer();
}
