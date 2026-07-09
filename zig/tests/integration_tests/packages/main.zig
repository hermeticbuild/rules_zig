const std = @import("std");
const builtin = @import("builtin");
const leaf = @import("leaf");
const bottom = @import("bottom");
const top = @import("top");
const lib = @import("lib");
const libfork = @import("libfork");
const lib2 = @import("lib2");
const pruned = @import("pruned");
const symlinked = @import("symlinked");
const lazyhost = @import("lazyhost");
const lazydirect = @import("lazydirect");
const child = @import("child");
const usec = @import("usec");
const cdep = @import("cdep");
const cppdep = @import("cppdep");
const syslibdep = @import("syslibdep");
const optdep = @import("optdep");
const cfgdep = @import("cfgdep");
const host = @import("host");

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
    // 2000 + 2: the lazy `lazyleaf` dependency is resolved through
    // `b.dependency`.
    std.debug.assert(lazydirect.value == 2002);
    // 7 + 2 + 100: `child_module` resolves its own manifest, importing `lib` at
    // v2 (a separate repository from the root's `lib` v1).
    std.debug.assert(child.value == 109);
    // `host`'s value + 1: `hostuser` depends on the URL package `host`, so its
    // spoke configures `host`'s sub-tree path dependencies through `host`'s.
    std.debug.assert(child.host_value == 64);
    // Calls libc's `getpid`; links only if the `usec` module pulls in libc.
    std.debug.assert(usec.pid() > 0);
    // 3*14 + 7*2, proving each C source got its own `-DSCALE` copts.
    std.debug.assert(cdep.value() == 56);
    // `new int(2)` then `+ 1`, computed by the vendored C++ source the module
    // links via libc++.
    std.debug.assert(cppdep.value() == 3);
    // 21*2, computed by the `mymath` cc_library the annotation provides.
    std.debug.assert(syslibdep.compute(21) == 42);
    // 5+100, from `optmath` linked only because its integration is enabled.
    std.debug.assert(optdep.compute(5) == 105);
    // The `configure` matrix links `dbgonly` (returns 1) in the fallback `dbg`
    // cell and `relonly` (returns 2) in the `rel` cell; the build's optimize
    // mode selects the cell, matching the mode `cfgdep` itself compiles under.
    std.debug.assert(cfgdep.value() == @as(c_int, if (builtin.mode == .debug) 1 else 2));
    // (5 + 7 + 42) + 9: `host` has sub-tree path dependencies `foo` and `bar`;
    // `foo` pulls its own nested `bar` (5) and the URL `leaf` (7), while `host`
    // links a distinct `bar` (9) — the two `bar`s stay separate by sub-path.
    std.debug.assert(host.value == 63);
}
