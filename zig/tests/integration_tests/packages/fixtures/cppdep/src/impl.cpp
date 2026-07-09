// Uses operator new/delete (C++ runtime symbols whose mangling is shared by
// libc++ and libstdc++).
extern "C" int cpp_compute(int x) {
    int *p = new int(x);
    int r = *p + 1;
    delete p;
    return r;
}
