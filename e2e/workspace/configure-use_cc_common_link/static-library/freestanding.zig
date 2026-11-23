const builtin = @import("builtin");
const linux = @import("std").os.linux;

comptime {
    if (builtin.link_libc) @compileError("this binary must compile without libc");
}

export fn _start() callconv(.c) noreturn {
    linux.exit(0);
}
