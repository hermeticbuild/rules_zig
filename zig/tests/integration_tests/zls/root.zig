comptime {
    @compileError("application compilation forbidden");
}

pub const dep = @import("dep");
pub const a = dep.leaf.answer;
pub const b = @import("generated").answer;
pub const c = @import("linked").answer;
pub const d = @import("undeclared").answer;
pub const e = @import("external").answer;
