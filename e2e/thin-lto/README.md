# Cross-language ThinLTO

Run these tests on Linux x86-64 with Bazelisk.

```sh
bazel test --config=native //...
bazel test --config=thin_lto //...
```

The C++ caller uses a Zig static archive, which forwards the C++ helper
through `CcInfo`. Both configurations check the runtime result. The binary
test uses `@llvm//tools:llvm-objdump` to verify that the native `cpp_entry`
transfers control to `zig_eval` and that the ThinLTO build eliminates that
call.
