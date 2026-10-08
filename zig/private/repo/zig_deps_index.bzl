"""Tables and lookups of the `@zig_deps` hub, shared by its rule and `defs.bzl`."""

def index_packages(graph, package_files):
    """Build the hub's package tables.

    Args:
      graph: map from each package's Zig hash key to its `{name, version, deps}`.
      package_files: map from each package's Zig hash key to its `files` label.

    Returns:
      `(packages, versions)`: `packages` maps each hash key to its `{name,
      version, files, deps}`; `versions` maps a package name to a map from
      version to the sorted hash keys of the packages with that name and
      version.
    """
    packages = {}
    versions = {}
    for key in sorted(graph):
        info = graph[key]
        packages[key] = {
            "name": info["name"],
            "version": info["version"],
            "files": package_files[key],
            "deps": info["deps"],
        }
        versions.setdefault(info["name"], {}).setdefault(info["version"], []).append(key)
    return packages, versions

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
    by_version = versions.get(name)
    if by_version == None:
        return ("unknown Zig package '{}'; available: {}".format(name, sorted(versions)), None)
    keys = by_version.get(version)
    if keys == None:
        return ("unknown version '{}' of Zig package '{}'; available: {}".format(version, name, sorted(by_version)), None)
    if len(keys) > 1:
        return ("Zig package '{}' version '{}' is ambiguous, it matches {}; reference it through a manifest dependency instead".format(name, version, keys), None)
    return (None, keys[0])
