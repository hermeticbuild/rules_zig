// The importer never configures a lazy dependency that no build() requests.
pub fn build(b: *@import("std").Build) void {
    _ = b;
    @compileError("lazyunused must not be configured");
}
