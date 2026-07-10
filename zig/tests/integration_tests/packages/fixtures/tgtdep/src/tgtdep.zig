const builtin = @import("builtin");

extern fn win_compute() c_int;
extern fn mac_compute() c_int;
extern fn posix_compute() c_int;

pub fn value() c_int {
    return switch (builtin.os.tag) {
        .windows => win_compute(),
        .macos => mac_compute(),
        else => posix_compute(),
    };
}
