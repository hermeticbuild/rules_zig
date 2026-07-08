const builtin = @import("builtin");

extern fn dbg_compute() c_int;
extern fn rel_compute() c_int;

pub fn value() c_int {
    if (builtin.mode == .debug) {
        return dbg_compute();
    } else {
        return rel_compute();
    }
}
