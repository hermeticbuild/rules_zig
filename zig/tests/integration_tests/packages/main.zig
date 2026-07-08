const std = @import("std");
const leaf = @import("leaf");
const bottom = @import("bottom");
const top = @import("top");
const lib = @import("lib");
const libfork = @import("libfork");
const lib2 = @import("lib2");
const pruned = @import("pruned");
const symlinked = @import("symlinked");
const lazyhost = @import("lazyhost");
const child = @import("child");
const usec = @import("usec");
const cdep = @import("cdep");
const cppdep = @import("cppdep");
const syslibdep = @import("syslibdep");

pub fn main() void {
    std.debug.assert(leaf.value == 7);
    std.debug.assert(bottom.value == 2);
    std.debug.assert(top.value == 6);
    std.debug.assert(lib.v1 == 1);
    std.debug.assert(libfork.fork == 3);
    std.debug.assert(lib2.v2 == 2);
    // Its `extra.zig` and `tests/` were pruned; only the declared paths were
    // packed, so the module still resolves.
    std.debug.assert(pruned.value == 13);
    // `src/aliased.zig` is a symlink to `real.zig`; the packer followed it.
    std.debug.assert(symlinked.value == 3000);
    // 2000 + 1: the `lazy = true` `lazyleaf` dependency is fetched eagerly and
    // resolved through `b.lazyDependency`.
    std.debug.assert(lazyhost.value == 2001);
    // 7 + 2 + 100: `child_module` resolves its own manifest, importing `lib` at
    // v2 (a separate repository from the root's `lib` v1).
    std.debug.assert(child.value == 109);
    // Calls libc's `getpid`; links only if the `usec` module pulls in libc.
    std.debug.assert(usec.pid() > 0);
    // 3*14 + 7*2, proving each C source got its own `-DSCALE` copts.
    std.debug.assert(cdep.value() == 56);
    // `new int(2)` then `+ 1`, computed by the vendored C++ source the module
    // links via libc++.
    std.debug.assert(cppdep.value() == 3);
    // 21*2, computed by the `mymath` cc_library the annotation provides.
    std.debug.assert(syslibdep.compute(21) == 42);
}
