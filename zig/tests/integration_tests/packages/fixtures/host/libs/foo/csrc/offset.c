// Resolves `offset.h` through the package-root include directory that
// `build.zig` adds as `b.path(".")`.
#include "offset.h"

int foo_offset(void) {
    return FOO_OFFSET;
}
