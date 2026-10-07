const c = @import("c");

pub const tag = c.BOX_TAG;
pub const wrapped = @import("wrapper").BOX_WRAPPED;

pub fn value() c_int {
    return c.box_value();
}

pub fn libValue() c_int {
    return c.boxlib_value();
}
