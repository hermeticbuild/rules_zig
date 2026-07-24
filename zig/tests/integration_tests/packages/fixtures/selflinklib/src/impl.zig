// The C-ABI symbol the installed static library provides; the public
// `selflinklib` module links this library and calls the symbol through an
// `extern fn`, so it resolves only through the linked artifact.
export fn self_value(x: c_int) c_int {
    return x * 9;
}
