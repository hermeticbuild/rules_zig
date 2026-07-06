"""Implementation of the `zig_package` repository rule."""

load("@zig_host_toolchain//:toolchain.bzl", "zig_cache", "zig_path")

# Seconds to allow a `zig fetch`. Zig 0.17.0 runs `zig fetch` through
# `lib/compiler/Maker.zig`, which is compiled into the global cache on first
# use and can take several minutes.
ZIG_FETCH_TIMEOUT = 3600

DOC = """\
Fetch a Zig package with the Zig SDK.

The Zig SDK downloads, verifies, and prunes the package according to its
`build.zig.zon`, and supports `git+` URLs. Fetching fails if the resulting
package hash does not match the expected `zig_hash`. The package's files are
public, individually and grouped as the `files` filegroup.

With `zig_hash` the fetch is reproducible. Without it, the repository reports
the fetched hash so a fetch cycle surfaces the value to pin.
"""

ATTRS = {
    "url": attr.string(mandatory = True, doc = "The package URL, e.g. `https://...` or `git+https://...`."),
    "zig_hash": attr.string(doc = "The expected Zig package hash. May be omitted to obtain the hash to pin from a fetch cycle."),
}

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(["**"], exclude = ["BUILD.bazel"]),
)
"""

# Directories the rule creates in the repository root for its own use.
_SCRATCH_DIRS = ["_fetch"]

def _fetch(repository_ctx, zig, cache):
    """Fetch the package into the repository root.

    Returns:
      the fetched package's Zig hash.
    """

    # Only `zig fetch --save` lays the package tree out under `--pkg-dir`, and
    # it requires a build root to record the dependency in. The name is explicit
    # because a package without `build.zig.zon` has none to default to.
    build_root = repository_ctx.path("_fetch")
    repository_ctx.file("_fetch/build.zig", "")
    pkg_dir = build_root.get_child("pkg")
    fetch = repository_ctx.execute(
        [zig, "fetch", "--pkg-dir", str(pkg_dir), "--save=package", repository_ctx.attr.url],
        environment = {"ZIG_GLOBAL_CACHE_DIR": cache},
        working_directory = str(build_root),
        timeout = ZIG_FETCH_TIMEOUT,
    )
    if fetch.return_code != 0:
        fail("`zig fetch {}` failed:\n{}".format(repository_ctx.attr.url, fetch.stderr))

    trees = pkg_dir.readdir()
    if len(trees) != 1:
        fail("`zig fetch {}` produced {} package trees, expected exactly one.".format(repository_ctx.attr.url, len(trees)))
    tree = trees[0]
    for entry in tree.readdir():
        if entry.basename in _SCRATCH_DIRS:
            fail("The Zig package '{}' has a top-level '{}', a name `zig_package` reserves for its own use.".format(
                repository_ctx.attr.url,
                entry.basename,
            ))
        repository_ctx.rename(entry, entry.basename)
    repository_ctx.delete(build_root)
    return tree.basename

def _zig_package_impl(repository_ctx):
    zig = zig_path(repository_ctx)
    cache = zig_cache(repository_ctx)

    fetched_hash = _fetch(repository_ctx, zig, cache)
    if repository_ctx.attr.zig_hash and fetched_hash != repository_ctx.attr.zig_hash:
        fail("Zig package hash mismatch for '{}':\n  expected: {}\n  fetched:  {}".format(
            repository_ctx.attr.url,
            repository_ctx.attr.zig_hash,
            fetched_hash,
        ))

    repository_ctx.file("BUILD.bazel", _BUILD)

    if not repository_ctx.attr.zig_hash:
        return repository_ctx.repo_metadata(attrs_for_reproducibility = {"zig_hash": fetched_hash})
    return repository_ctx.repo_metadata(reproducible = True)

zig_package = repository_rule(
    _zig_package_impl,
    attrs = ATTRS,
    doc = DOC,
)
