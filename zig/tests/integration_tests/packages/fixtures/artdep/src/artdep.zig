// The C-ABI symbol a Bazel consumer links from the installed static library.
// The consumer sees only an `extern fn` declaration, so the call cannot fold
// and resolves only if the artifact is linked.
export fn artdep_scaled(x: c_int) c_int {
    return x * 6;
}
