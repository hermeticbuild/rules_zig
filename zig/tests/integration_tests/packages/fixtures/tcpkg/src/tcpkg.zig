const c = @import("c");

pub const wrapped = @import("wrap").TCPKG_WRAPPED;

pub fn value() c_int {
    return c.TCPKG_READY + c.tcpkg_value();
}

pub fn libValue() c_int {
    return c.tclib_value();
}
