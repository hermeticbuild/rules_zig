#include <cstdio>

extern "C" unsigned zig_eval(unsigned value);

extern "C" __attribute__((noinline)) unsigned cpp_entry(unsigned value) {
    return zig_eval(value);
}

int main() {
    volatile unsigned input = 11;
    const unsigned result = cpp_entry(input);
    if (result != 43) {
        std::fprintf(stderr, "Expected 43, got %u\n", result);
        return 1;
    }
    return 0;
}
