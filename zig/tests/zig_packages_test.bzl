"""Unit tests for the `zig_packages` module extension helpers."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//zig/private/bzlmod:zig_packages.bzl",
    "check_cells",
    "collect_configs",
    "package_cells",
    "package_name_version",
    "resolve_cell",
    "select_by_precedence",
)
load("//zig/private/repo:zig_deps_index.bzl", "has_modules", "index_packages", "resolve_version")

def _config_tag(name, optimize = "", target = "", select_on = [], zig_flags = []):
    return struct(name = name, optimize = optimize, target = target, select_on = select_on, zig_flags = zig_flags)

def _configure_tag(configs, fallback, package = "", version = ""):
    return struct(configs = configs, fallback = fallback, package = package, version = version)

def _module(name, is_root, config = [], configure = []):
    return struct(name = name, is_root = is_root, tags = struct(config = config, configure = configure))

def _cell(name, config_setting, select_on = [], zig_options = [], tag = None):
    return struct(name = name, config_setting = config_setting, select_on = select_on, zig_options = zig_options, tag = tag)

def _package_name_version_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ("clap", "0.10.0"),
        package_name_version("clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS"),
    )

    # The version and the digest may contain `-`.
    asserts.equals(
        env,
        ("zls", "0.15.0-dev.129"),
        package_name_version("zls-0.15.0-dev.129-Ux6O2xUBAABN-ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS"),
    )

    return unittest.end(env)

_package_name_version_test = unittest.make(_package_name_version_test_impl)

def _entry(module, key, value):
    return struct(module = module, is_root = module == "root", key = key, value = value, tag = None)

def _select_by_precedence_test_impl(ctx):
    env = unittest.begin(ctx)

    root = _entry("root", "any", "//root")
    dep_specific = _entry("dep", "specific", "//dep")
    other_specific = _entry("other", "specific", "//other")

    # The root module's entry wins even under a less specific key, overriding
    # every dependency module's.
    asserts.equals(
        env,
        (None, root, [dep_specific]),
        select_by_precedence({"specific": [dep_specific], "any": [root]}, ["specific", "any"]),
    )

    # Without a root entry, the most specific dependency entry applies.
    asserts.equals(
        env,
        (None, dep_specific, []),
        select_by_precedence({"specific": [dep_specific], "any": [_entry("dep", "any", "//any")]}, ["specific", "any"]),
    )

    # Equal dependency entries under one key collapse.
    asserts.equals(
        env,
        (None, dep_specific, []),
        select_by_precedence({"specific": [dep_specific, _entry("other", "specific", "//dep")]}, ["specific"]),
    )

    # Disagreeing dependency entries under one key conflict.
    asserts.equals(
        env,
        ((dep_specific, other_specific), None, []),
        select_by_precedence({"specific": [dep_specific, other_specific]}, ["specific"]),
    )

    # The root module settles what would otherwise conflict.
    asserts.equals(
        env,
        (None, root, [dep_specific, other_specific]),
        select_by_precedence({"specific": [dep_specific, other_specific], "any": [root]}, ["specific", "any"]),
    )

    asserts.equals(env, (None, None, []), select_by_precedence({"other": [root]}, ["specific"]))

    return unittest.end(env)

_select_by_precedence_test = unittest.make(_select_by_precedence_test_impl)

# Two copies of `lib` 1.0.0 (e.g. two revisions of one release) and `lib` 2.0.0.
_LIB_A = "lib-1.0.0-AAAA"
_LIB_B = "lib-1.0.0-BBBB"
_LIB_2 = "lib-2.0.0-CCCC"

def _index():
    return index_packages(
        {
            _LIB_A: {"name": "lib", "version": "1.0.0"},
            _LIB_B: {"name": "lib", "version": "1.0.0"},
            _LIB_2: {"name": "lib", "version": "2.0.0"},
        },
        {key: "@" + key + "//:files" for key in [_LIB_A, _LIB_B, _LIB_2]},
    )

def _index_packages_test_impl(ctx):
    env = unittest.begin(ctx)

    packages, versions = _index()

    # Packages sharing a name and version stay separate entries.
    asserts.equals(env, "@" + _LIB_A + "//:files", packages[_LIB_A]["files"])
    asserts.equals(env, "@" + _LIB_B + "//:files", packages[_LIB_B]["files"])
    asserts.equals(env, {"1.0.0": [_LIB_A, _LIB_B], "2.0.0": [_LIB_2]}, versions["lib"])

    return unittest.end(env)

_index_packages_test = unittest.make(_index_packages_test_impl)

def _resolve_version_test_impl(ctx):
    env = unittest.begin(ctx)

    _, versions = _index()

    asserts.equals(env, (None, _LIB_2), resolve_version(versions, "lib", "2.0.0"))

    error, key = resolve_version(versions, "lib", "1.0.0")
    asserts.equals(env, None, key)
    asserts.true(env, "ambiguous" in error, error)

    error, key = resolve_version(versions, "lib", "3.0.0")
    asserts.equals(env, None, key)
    asserts.true(env, "unknown version '3.0.0'" in error, error)

    error, key = resolve_version(versions, "nope", "1.0.0")
    asserts.equals(env, None, key)
    asserts.true(env, "unknown Zig package 'nope'" in error, error)

    # Packages without a manifest are indexed, but `N`/`V` names none of them.
    _, naked_versions = index_packages(
        {"N-V-AAAA": {"name": "N", "version": "V"}},
        {"N-V-AAAA": "@N-V-AAAA//:files"},
    )
    error, key = resolve_version(naked_versions, "N", "V")
    asserts.equals(env, None, key)
    asserts.true(env, "without a `build.zig.zon`" in error, error)

    return unittest.end(env)

_resolve_version_test = unittest.make(_resolve_version_test_impl)

def _has_modules_test_impl(ctx):
    env = unittest.begin(ctx)

    packages, _ = index_packages(
        {
            _LIB_A: {"name": "lib", "version": "1.0.0"},
            "N-V-AAAA": {"name": "N", "version": "V"},
        },
        {_LIB_A: "@" + _LIB_A + "//:files", "N-V-AAAA": "@N-V-AAAA//:files"},
    )
    asserts.true(env, has_modules(packages[_LIB_A]))
    asserts.false(env, has_modules(packages["N-V-AAAA"]))

    return unittest.end(env)

_has_modules_test = unittest.make(_has_modules_test_impl)

def _resolve_cell_test_impl(ctx):
    env = unittest.begin(ctx)

    # `optimize` expands to a condition label and a `-Doptimize` build option.
    error, cell = resolve_cell(_config_tag("opt", optimize = "release_fast"))
    asserts.equals(env, None, error)
    asserts.equals(env, "opt", cell.name)
    asserts.equals(env, ["@rules_zig//zig/config/mode:release_fast"], cell.select_on)
    asserts.equals(env, ["-Doptimize=fast"], cell.zig_options)

    # `target` expands to a `-Dtarget` build option, keyed by caller-supplied
    # `select_on` conditions.
    error, cell = resolve_cell(_config_tag(
        "win",
        target = "x86_64-windows-gnu",
        select_on = ["@platforms//cpu:x86_64", "@platforms//os:windows"],
    ))
    asserts.equals(env, None, error)
    asserts.equals(env, ["@platforms//cpu:x86_64", "@platforms//os:windows"], cell.select_on)
    asserts.equals(env, ["-Dtarget=x86_64-windows-gnu"], cell.zig_options)

    # `select_on` is appended verbatim; `zig_flags` become `-DNAME=VALUE`.
    error, cell = resolve_cell(_config_tag(
        "custom",
        select_on = ["//conditions:foo"],
        zig_flags = ["enable=true"],
    ))
    asserts.equals(env, None, error)
    asserts.equals(env, ["//conditions:foo"], cell.select_on)
    asserts.equals(env, ["-Denable=true"], cell.zig_options)

    # An error carries the offending tag, so the extension can forward it to
    # `fail()` and point at the declaration.
    bad = _config_tag("bad", optimize = "nope")
    error, cell = resolve_cell(bad)
    asserts.true(env, error != None)
    asserts.equals(env, bad, error.tag)
    asserts.equals(env, None, cell)

    error, cell = resolve_cell(_config_tag("bad", zig_flags = ["novalue"]))
    asserts.true(env, error != None)
    asserts.equals(env, None, cell)

    return unittest.end(env)

_resolve_cell_test = unittest.make(_resolve_cell_test_impl)

def _check_cells_test_impl(ctx):
    env = unittest.begin(ctx)

    # Fallbacks precede deduplicated non-fallback cells; cells sharing
    # conditions and options collapse to one.
    error, cells = check_cells("clap", [
        _cell("base", "", zig_options = ["-Doptimize=debug"]),
        _cell("fast", "fast", select_on = ["//a"], zig_options = ["-Doptimize=fast"]),
        _cell("fast_dup", "fast_dup", select_on = ["//a"], zig_options = ["-Doptimize=fast"]),
    ])
    asserts.equals(env, None, error)
    asserts.equals(env, ["base", "fast"], [c.name for c in cells])

    # A non-fallback cell needs conditions to select on.
    error, _ = check_cells("clap", [_cell("x", "x")])
    asserts.true(env, error != None)

    # Same conditions but different options is a conflict.
    error, _ = check_cells("clap", [
        _cell("a", "a", select_on = ["//c"], zig_options = ["-Dx=1"]),
        _cell("b", "b", select_on = ["//c"], zig_options = ["-Dx=2"]),
    ])
    asserts.true(env, error != None)

    # One cell's conditions being a subset of another's is ambiguous.
    error, _ = check_cells("clap", [
        _cell("a", "a", select_on = ["//c"]),
        _cell("b", "b", select_on = ["//c", "//d"]),
    ])
    asserts.true(env, error != None)

    return unittest.end(env)

_check_cells_test = unittest.make(_check_cells_test_impl)

def _package_cells_test_impl(ctx):
    env = unittest.begin(ctx)

    cells_by_name = {
        "base": resolve_cell(_config_tag("base"))[1],
        "fast": resolve_cell(_config_tag("fast", optimize = "release_fast"))[1],
    }

    # No configure tag configures the package once at the host default.
    error, cells = package_cells("clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS", cells_by_name, None, {})
    asserts.equals(env, None, error)
    asserts.equals(env, None, cells)

    # A global configure applies its ordered configs, fallback first.
    error, cells = package_cells(
        "clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS",
        cells_by_name,
        _configure_tag(["base", "fast"], "base"),
        {},
    )
    asserts.equals(env, None, error)
    asserts.equals(env, ["base", "fast"], [c.name for c in cells])
    asserts.equals(env, ["", "fast"], [c.config_setting for c in cells])

    # A per-package configure overrides the global one.
    error, cells = package_cells(
        "clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS",
        cells_by_name,
        _configure_tag(["base", "fast"], "base"),
        {("clap", "0.10.0"): _configure_tag(["fast"], "fast")},
    )
    asserts.equals(env, None, error)
    asserts.equals(env, ["fast"], [c.name for c in cells])

    # The fallback must be among the configs.
    error, _ = package_cells(
        "clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS",
        cells_by_name,
        _configure_tag(["fast"], "base"),
        {},
    )
    asserts.true(env, error != None)

    # An unknown config name is an error.
    error, _ = package_cells(
        "clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS",
        cells_by_name,
        _configure_tag(["ghost"], "ghost"),
        {},
    )
    asserts.true(env, error != None)

    return unittest.end(env)

_package_cells_test = unittest.make(_package_cells_test_impl)

def _package_cells_target_override_test_impl(ctx):
    env = unittest.begin(ctx)

    cells_by_name = {
        "win": resolve_cell(_config_tag(
            "win",
            target = "x86_64-windows-gnu",
            select_on = ["@platforms//os:windows"],
        ))[1],
        "plain": resolve_cell(_config_tag("plain"))[1],
    }

    key = "notgt-0.0.0-abc"
    global_configure = _configure_tag(["win"], "win")

    # A per-package configure pointing at a target-less config exempts a package
    # that cannot consume a target from the global target matrix: no `-Dtarget`
    # flag reaches it.
    error, cells = package_cells(
        key,
        cells_by_name,
        global_configure,
        {("notgt", ""): _configure_tag(["plain"], "plain")},
    )
    asserts.equals(env, None, error)
    asserts.equals(env, ["plain"], [c.name for c in cells])
    for cell in cells:
        for option in cell.zig_options:
            asserts.false(env, option.startswith("-Dtarget="))

    # Without the per-package configure the global target matrix applies.
    error, cells = package_cells(key, cells_by_name, global_configure, {})
    asserts.equals(env, None, error)
    asserts.equals(env, ["win"], [c.name for c in cells])
    asserts.true(env, "-Dtarget=x86_64-windows-gnu" in cells[0].zig_options)

    return unittest.end(env)

_package_cells_target_override_test = unittest.make(_package_cells_target_override_test_impl)

def _collect_configs_test_impl(ctx):
    env = unittest.begin(ctx)

    error, result = collect_configs([
        _module("root", True, config = [
            _config_tag("base"),
            _config_tag("fast", optimize = "release_fast"),
        ], configure = [
            _configure_tag(["base", "fast"], "base"),
            _configure_tag(["fast"], "fast", package = "clap"),
        ]),
        _module("dep", False, config = [_config_tag("ignored")]),
    ])
    asserts.equals(env, None, error)
    asserts.equals(env, ["base", "fast"], sorted(result.cells_by_name.keys()))
    asserts.true(env, result.global_configure != None)
    asserts.true(env, ("clap", "") in result.per_package_configure)
    asserts.equals(env, ["dep"], [ignored.module for ignored in result.ignored])

    # Two config tags with the same name but different content conflict.
    error, _ = collect_configs([
        _module("root", True, config = [
            _config_tag("x", optimize = "debug"),
            _config_tag("x", optimize = "release_fast"),
        ]),
    ])
    asserts.true(env, error != None)

    # At most one global configure tag is allowed.
    error, _ = collect_configs([
        _module("root", True, configure = [
            _configure_tag(["a"], "a"),
            _configure_tag(["b"], "b"),
        ]),
    ])
    asserts.true(env, error != None)

    return unittest.end(env)

_collect_configs_test = unittest.make(_collect_configs_test_impl)

def zig_packages_test_suite(name):
    """Instantiate the zig_packages test suite.

    Args:
      name: the test suite's name.
    """
    unittest.suite(
        name,
        partial.make(_package_name_version_test),
        partial.make(_select_by_precedence_test),
        partial.make(_index_packages_test),
        partial.make(_resolve_version_test),
        partial.make(_has_modules_test),
        partial.make(_resolve_cell_test),
        partial.make(_check_cells_test),
        partial.make(_package_cells_test),
        partial.make(_package_cells_target_override_test),
        partial.make(_collect_configs_test),
    )
