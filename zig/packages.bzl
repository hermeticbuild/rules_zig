"""Extension for importing Zig package dependencies."""

load("//zig/private/bzlmod:zig_packages.bzl", _zig_packages = "zig_packages")

zig_packages = _zig_packages
