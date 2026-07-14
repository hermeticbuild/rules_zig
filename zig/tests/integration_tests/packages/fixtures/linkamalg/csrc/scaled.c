#include "amalg.h"

int linkamalg_scaled(int x) {
    return amalg_value(x) * FACTOR + AMALG_OFFSET;
}
