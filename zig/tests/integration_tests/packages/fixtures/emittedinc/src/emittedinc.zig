const c = @import("c");

pub fn value() c_int {
    return c.emitted_value();
}
