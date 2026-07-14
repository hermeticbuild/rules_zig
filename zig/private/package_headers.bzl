"""Implementation of the `package_headers` rule."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

DOC = """\
Provide one directory of a package's files as an include directory.

The directory is searched in place, and all the package's files are headers, so
a header under it may include any other file of the package by a path relative
to itself, such as `"../src/private.h"` or a `.inc` file.
"""

ATTRS = {
    "files": attr.label(
        mandatory = True,
        allow_files = True,
        doc = "The package's files.",
    ),
    "directory": attr.string(
        doc = "The include directory, relative to the files' repository root.",
    ),
}

def _package_headers_impl(ctx):
    include = paths.normalize(paths.join(ctx.attr.files.label.workspace_root, ctx.attr.directory))
    return [CcInfo(compilation_context = cc_common.create_compilation_context(
        headers = depset(ctx.files.files),
        includes = depset([include]),
    ))]

package_headers = rule(
    _package_headers_impl,
    attrs = ATTRS,
    doc = DOC,
)
