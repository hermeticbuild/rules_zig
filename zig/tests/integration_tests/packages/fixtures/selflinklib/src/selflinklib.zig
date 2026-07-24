// `self_value` is provided only by the linked `selflinklib-impl` static library
// artifact built and installed by this same package; the module sees an
// `extern fn`, so it resolves only if that artifact target is wired in.
extern fn self_value(x: c_int) c_int;

pub fn value() c_int {
    return self_value(4);
}
