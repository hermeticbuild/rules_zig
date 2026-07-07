"""Implementation of the `zig_deps` hub repository rule."""

load(":zig_deps_index.bzl", "index_packages")

DOC = """\
The `@zig_deps` hub repository of the `zig_packages` module extension.

Exposes the resolved Zig package dependency graph: `defs.bzl` provides
accessors that address a package's files and generated targets, and resolve a
consumer manifest's declared dependencies with `zig_dep`.
"""

ATTRS = {
    "package_files": attr.string_keyed_label_dict(
        mandatory = True,
        doc = "Map from each package's Zig hash key to its `files` filegroup.",
    ),
    "graph": attr.string(
        mandatory = True,
        doc = "JSON map from each package's Zig hash key to its `{name, version}`.",
    ),
    "manifests": attr.string(
        default = "[]",
        doc = "JSON list of `{repo, package, deps}` consumer manifests, where `deps` maps a declared dependency name to `{key}`, its hash key.",
    ),
}

_DEFS = '''\
"""Accessors for the resolved Zig package dependency graph."""

load("@rules_zig//zig/private/repo:zig_deps_index.bzl", "resolve_version")

_PACKAGES = json.decode("""%PACKAGES%""")
_VERSIONS = json.decode("""%VERSIONS%""")
_MANIFESTS = json.decode("""%MANIFESTS%""")

def _enclosing_deps():
    by_package = _MANIFESTS.get(native.repo_name(), {})
    candidate = native.package_name()
    for _ in range(len(candidate) + 1):
        if candidate in by_package:
            return by_package[candidate]
        if not candidate:
            break
        candidate = candidate.rpartition("/")[0]
    fail("no Zig `from_file` manifest covers package '%s'" % native.package_name())

def _declared(name):
    deps = _enclosing_deps()
    if name not in deps:
        fail("the enclosing Zig manifest declares no dependency '%s'; available: %s" % (name, sorted(deps)))
    return deps[name]

def _package(name, version):
    if version == None:
        return _PACKAGES[_declared(name)["key"]]
    error, key = resolve_version(_VERSIONS, name, version)
    if error != None:
        fail(error)
    return _PACKAGES[key]

def zig_package_files(name, version = None):
    """The label of a Zig package's `files` filegroup.

    Without `version`, `name` is a dependency declared by the enclosing
    manifest; with `version`, it is a package name.
    """
    return Label(_package(name, version)["files"])

def zig_package_file(name, path, version = None):
    """The label of the file at `path` inside a Zig package, see `zig_package_files`."""
    return zig_package_files(name, version).same_package_label(path)

def zig_package_target(name, module = None, version = None):
    """The label of a generated `zig_library` of a Zig package, see `zig_package_files`.

    Defaults to the module of the same name as the package; pass `module` to
    select another module the package exposes.
    """
    package = _package(name, version)
    return Label(package["files"]).same_package_label(module or package["name"])

def zig_dep(name, module = None):
    """The label of the dependency `name` declared by the enclosing manifest.

    Resolves to the dependency's module of the same name as its package; pass
    `module` to select another module the dependency exposes.
    """
    return zig_package_target(name, module = module)
'''

def _zig_deps_hub_impl(repository_ctx):
    graph = json.decode(repository_ctx.attr.graph)
    packages, versions = index_packages(
        graph,
        {key: str(label) for key, label in repository_ctx.attr.package_files.items()},
    )

    # Each consumer manifest's declared dependencies, scoped to the manifest's
    # repository and Bazel package.
    registry = {}
    for manifest in json.decode(repository_ctx.attr.manifests):
        registry.setdefault(manifest["repo"], {})[manifest["package"]] = manifest["deps"]

    repository_ctx.file("BUILD.bazel", "")
    defs = _DEFS.replace("%PACKAGES%", json.encode(packages))
    defs = defs.replace("%VERSIONS%", json.encode(versions))
    defs = defs.replace("%MANIFESTS%", json.encode(registry))
    repository_ctx.file("defs.bzl", defs)

zig_deps_hub = repository_rule(
    _zig_deps_hub_impl,
    attrs = ATTRS,
    doc = DOC,
)
