// `getpid` is provided by libc.
extern fn getpid() c_int;

pub fn pid() c_int {
    return getpid();
}
