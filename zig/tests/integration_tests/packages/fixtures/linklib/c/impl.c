#include "impl.h"

#if SCALE != 6
#error "impl.c expected -DSCALE=6"
#endif

int scaled(int x) {
    return SCALE * x;
}
