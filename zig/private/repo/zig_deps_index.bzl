"""Tables and lookups of the `@zig_deps` hub, shared by its rule and `defs.bzl`."""

# The name and version Zig assigns every package without a `build.zig.zon`.
_NAKED_NAME_VERSION = ("N", "V")

def index_packages(graph, package_files):
    """Build the hub's package tables.

    Args:
      graph: map from each package's Zig hash key to its `{name, version}`.
      package_files: map from each package's Zig hash key to its `files` label.

    Returns:
      `(packages, versions)`: `packages` maps each hash key to its `{name,
      version, files}`; `versions` maps a package name to a map from version
      to the sorted hash keys of the packages with that name and version.
    """
    packages = {}
    versions = {}
    for key in sorted(graph):
        info = graph[key]
        packages[key] = {
            "name": info["name"],
            "version": info["version"],
            "files": package_files[key],
        }
        versions.setdefault(info["name"], {}).setdefault(info["version"], []).append(key)
    return packages, versions

def has_modules(package):
    """Whether a `packages` entry of `index_packages` has Zig modules, which a package without a `build.zig.zon` lacks."""
    return (package["name"], package["version"]) != _NAKED_NAME_VERSION

def resolve_version(versions, name, version):
    """Find the single package with the given name and version.

    Name and version need not identify a package: distinct packages, such as
    two revisions or forks of one release, may share both.

    Args:
      versions: the `versions` table of `index_packages`.
      name: the package name.
      version: the package version.

    Returns:
      `(error, key)`, `key` the package's Zig hash key.
    """
    if (name, version) == _NAKED_NAME_VERSION:
        return ("Zig packages without a `build.zig.zon` all share the name '{}' and version '{}'; reference one through a manifest dependency instead".format(name, version), None)
    by_version = versions.get(name)
    if by_version == None:
        return ("unknown Zig package '{}'; available: {}".format(name, sorted(versions)), None)
    keys = by_version.get(version)
    if keys == None:
        return ("unknown version '{}' of Zig package '{}'; available: {}".format(version, name, sorted(by_version)), None)
    if len(keys) > 1:
        return ("Zig package '{}' version '{}' is ambiguous, it matches {}; reference it through a manifest dependency instead".format(name, version, keys), None)
    return (None, keys[0])
