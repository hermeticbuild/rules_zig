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
package hash does not match the expected `zig_hash`. The package's `build.zig`
is then configured to extract its public module graph
(`module_manifest.json`), and a `zig_library` is generated for each module the
package owns. The package's files are public, individually and grouped as the
`files` filegroup.

With `zig_hash` the fetch is reproducible. Without it, the repository reports
the fetched hash so a fetch cycle surfaces the value to pin.
"""

ATTRS = {
    "url": attr.string(mandatory = True, doc = "The package URL, e.g. `https://...` or `git+https://...`."),
    "zig_hash": attr.string(doc = "The expected Zig package hash. May be omitted to obtain the hash to pin from a fetch cycle."),
    "deps": attr.string(
        default = "{\"root_deps\": [], \"packages\": {}}",
        doc = """\
JSON `{root_deps, packages}` describing the `@dependencies` closure used
to configure the package; each dependency edge is `[name, key, lazy]`.
""",
    ),
    "dep_build_files": attr.string_keyed_label_dict(
        doc = "Map from each dependency package hash to its `build.zig`, used to wire `@dependencies`.",
    ),
}

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(["**"], exclude = [
        "BUILD.bazel",
        "module_manifest.json",
    ]),
)
"""

_EXPORT_MANIFEST = """\

exports_files(["module_manifest.json"])
"""

_LIBRARY_LOAD = """\
load("@rules_zig//zig:defs.bzl", "zig_library")

"""

_ZIG_LIBRARY = """
zig_library(
    name = "{name}",
    main = "{main}",
    import_name = "{name}",
    srcs = glob(["**/*.zig"], exclude = ["{main}"]),
    deps = {deps},
    import_names = {import_names},
)
"""

def _module_dep_label(repository_ctx, imported):
    # A same-package import resolves to a sibling target here; a cross-package
    # import resolves to the module's target in the dependency's own spoke.
    if imported["package"] == "":
        return ":" + imported["module"]
    return str(repository_ctx.attr.dep_build_files[imported["package"]].same_package_label(imported["module"]))

def _render_libraries(repository_ctx, modules):
    """Render a `zig_library` for each module this package owns.

    A dependency is imported under its own name by default; an import under a
    different name is remapped through `import_names`. Modules owned by a
    dependency are generated in that dependency's own spoke and skipped here.
    """
    chunks = []
    for module in modules:
        if module["package"] != "":
            continue
        deps = []
        import_names = {}
        for imported in module["imports"]:
            label = _module_dep_label(repository_ctx, imported)
            deps.append(label)
            if imported["name"] != imported["module"]:
                import_names[label] = imported["name"]
        chunks.append(_ZIG_LIBRARY.format(
            name = module["name"],
            main = module["root_source"],
            deps = json.encode(deps),
            import_names = json.encode(import_names),
        ))
    return "".join(chunks)

# Directories the rule creates in the repository root for its own use.
_SCRATCH_DIRS = ["_fetch", "_configure"]

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

_EMPTY_DEPS = """\
pub const packages = struct {};
pub const root_deps: []const struct { []const u8, []const u8 } = &.{};
"""

def _zig_string(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _edge_lines(edges, indent):
    return [
        "{}.{{ {}, {} }},".format(indent, _zig_string(name), _zig_string(key))
        for name, key, _lazy in edges
    ]

def _available(deps, requested):
    """The packages reachable through eager or `requested` lazy dependency edges."""
    packages = deps["packages"]
    available = {}
    frontier = deps["root_deps"]
    for _ in range(len(packages)):
        reached = []
        for _name, key, lazy in frontier:
            if key not in available and (not lazy or key in requested):
                available[key] = True
                reached.extend(packages[key]["deps"])
        frontier = reached
    return available

def _dependencies_source(repository_ctx, deps, available):
    """Render the `@dependencies` module that `b.dependency` consumes.

    A package outside `available` is an unrequested lazy dependency; it is
    declared unavailable, so its spoke is not materialized.
    """
    packages = deps["packages"]
    if not packages:
        return _EMPTY_DEPS

    lines = ["pub const packages = struct {"]
    for key in sorted(packages):
        package = packages[key]
        lines.append("    pub const @\"{}\" = struct {{".format(key))
        if key not in available:
            lines.append("        pub const available = false;")
            lines.append("    };")
            continue
        build_zig = repository_ctx.path(repository_ctx.attr.dep_build_files[key])
        lines.append("        pub const build_root = {};".format(_zig_string(str(build_zig.dirname))))
        lines.append("        pub const build_zig = @import(\"{}\");".format(key))
        lines.append("        pub const deps: []const struct { []const u8, []const u8 } = &.{")
        lines.extend(_edge_lines(package["deps"], "            "))
        lines.append("        };")
        lines.append("    };")
    lines.append("};")
    lines.append("")
    lines.append("pub const root_deps: []const struct { []const u8, []const u8 } = &.{")
    lines.extend(_edge_lines(deps["root_deps"], "    "))
    lines.append("};")
    return "\n".join(lines) + "\n"

def _run_configurer(repository_ctx, zig, build_zig, cache, deps, available):
    """Compile the configurer against the package's `build.zig` and run it.

    Returns:
      the configurer's `exec_result`.
    """
    configurer = repository_ctx.path(Label("//zig/private/packages:configurer.zig"))

    # `configurer.zig` is watched by the `path` above, but the modules it
    # `@import`s are not: Bazel cannot see Zig's transitive imports, so a change
    # to the configurer's logic there would reuse a cached manifest. Watch them
    # so editing the configurer re-runs configuration.
    repository_ctx.watch(Label("//zig/private/packages:module_graph.zig"))

    repository_ctx.file("_configure/deps.zig", _dependencies_source(repository_ctx, deps, available))

    keys = sorted(available)

    args = [zig, "build-exe", "--dep", "pkg", "--dep", "deps", "-Mroot=" + str(configurer), "-Mpkg=" + str(build_zig)]
    for key in keys:
        args.extend(["--dep", key])
    args.append("-Mdeps=" + str(repository_ctx.path("_configure/deps.zig")))
    for key in keys:
        dep_build_zig = repository_ctx.path(repository_ctx.attr.dep_build_files[key])

        # The configurer is compiled against each dependency's `build.zig`, so
        # a change to one must re-run configuration.
        repository_ctx.watch(dep_build_zig)
        args.append("-M{}={}".format(key, dep_build_zig))
    args.extend([
        "--cache-dir",
        cache,
        "--global-cache-dir",
        cache,
        "-femit-bin=" + str(repository_ctx.path("_configure/configurer")),
    ])

    compiled = repository_ctx.execute(args)
    if compiled.return_code != 0:
        fail("Failed to compile the Zig configurer for '{}':\n{}".format(repository_ctx.attr.url, compiled.stderr))

    configured = repository_ctx.execute([
        str(repository_ctx.path("_configure/configurer")),
        "--zig",
        str(zig),
        "--build-root",
        str(repository_ctx.path(".")),
    ])
    if configured.return_code != 0:
        fail("Failed to configure the Zig package '{}':\n{}".format(repository_ctx.attr.url, configured.stderr))
    return configured

def _configure(repository_ctx, zig, build_zig, cache):
    """Configure the package with only the lazy dependencies it requests, as `zig build` does.

    Returns:
      the package's module-graph JSON.
    """
    deps = json.decode(repository_ctx.attr.deps)
    edges = deps["root_deps"] + [edge for package in deps["packages"].values() for edge in package["deps"]]
    lazy = {key: None for _name, key, is_lazy in edges if is_lazy}
    requested = {}
    for _ in range(len(lazy) + 1):
        configured = _run_configurer(repository_ctx, zig, build_zig, cache, deps, _available(deps, requested))
        result = json.decode(configured.stdout, default = None)
        if result != None and "needed_lazy_dependencies" not in result:
            return configured.stdout

        # `b.dependency` on an unavailable lazy dependency ends the configuration
        # early, emitting Zig's binary build configuration, which is not parsed
        # here, so make every lazy dependency available.
        needed = lazy.keys() if result == None else result["needed_lazy_dependencies"]
        new = [key for key in needed if key not in requested]
        if not new:
            break
        requested.update({key: None for key in new})
    fail("Failed to configure the Zig package '{}': with every requested lazy dependency available, {}:\n{}".format(
        repository_ctx.attr.url,
        "its output is not JSON" if result == None else "it still requests lazy dependencies",
        configured.stderr,
    ))

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

    build = _BUILD
    if repository_ctx.path("build.zig").exists:
        manifest = _configure(repository_ctx, zig, repository_ctx.path("build.zig"), cache)
        repository_ctx.delete("_configure")
        repository_ctx.file("module_manifest.json", manifest)
        libraries = _render_libraries(repository_ctx, json.decode(manifest)["modules"])
        build = _LIBRARY_LOAD + build + libraries + _EXPORT_MANIFEST

    repository_ctx.file("BUILD.bazel", build)

    if not repository_ctx.attr.zig_hash:
        return repository_ctx.repo_metadata(attrs_for_reproducibility = {"zig_hash": fetched_hash})
    return repository_ctx.repo_metadata(reproducible = True)

zig_package = repository_rule(
    _zig_package_impl,
    attrs = ATTRS,
    doc = DOC,
)
