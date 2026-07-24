// The C-ABI symbol a dependent package links from the installed static library
// via `dep.artifact("artlib")`. The dependent sees only an `extern fn`
// declaration, so the call cannot fold and resolves only if the artifact is
// linked.
export fn artlib_value(x: c_int) c_int {
    return x * 5;
}
