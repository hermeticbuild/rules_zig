extern int value;

__attribute__((constructor))
static void register_value(void) {
    value = 7;
}
