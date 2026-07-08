#include "value.h"

#if SCALE != 3
#error "value.c expected -DSCALE=3"
#endif

_Static_assert(sizeof(GREETING) == sizeof("a b"), "value.c expected -DGREETING=\"a b\"");

static const int factor$x = 14;

int scaled_value(void) {
    return SCALE * FACTOR;
}
