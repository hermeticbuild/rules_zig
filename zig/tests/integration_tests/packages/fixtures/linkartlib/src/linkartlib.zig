// `artlib_value` is provided only by the linked `artlib` static library
// artifact, reached through `dep.artifact("artlib")`; the module sees an
// `extern fn`, so it resolves only if that artifact target is wired in.
extern fn artlib_value(x: c_int) c_int;

pub fn value() c_int {
    return artlib_value(8);
}
