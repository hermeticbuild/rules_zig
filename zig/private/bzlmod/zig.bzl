"""Implementation of the `zig` module extension."""

load("@bazel_skylib//lib:sets.bzl", "sets")
load("//zig/private:platforms.bzl", "PLATFORMS")
load("//zig/private/common:semver.bzl", "semver")
load("//zig/private/repo:toolchains_repo.bzl", "sanitize_version", "toolchains_repo")
load("//zig/private/repo:zig_repository.bzl", "zig_repository")

DOC = """\
Installs a Zig toolchain.

Every module can define multiple toolchain versions. All these versions will be
registered as toolchains and you can select the toolchain using the
`@zig_toolchains//:version` build flag.

The latest version will be the default unless the root module explicitly
declares one as the default.
"""

_DEFAULT_NAME = "zig"

zig_toolchain = tag_class(
    attrs = {
        "name": attr.string(
            doc = "A descriptive suffix for generated toolchain targets. Leave empty for the default wrapper names.",
            mandatory = False,
            default = "",
        ),
        "zig_version": attr.string(doc = "The Zig SDK version.", mandatory = True),
        "default": attr.bool(
            doc = "Make this the default Zig SDK version. Can only be used once, and only in the root module.",
            mandatory = False,
            default = False,
        ),
        "extra_exec_compatible_with": attr.label_list(
            doc = "Additional execution platform constraints for generated Zig SDK toolchain targets.",
            mandatory = False,
            default = [],
        ),
        "extra_target_compatible_with": attr.label_list(
            doc = "Additional target platform constraints for generated Zig SDK toolchain targets.",
            mandatory = False,
            default = [],
        ),
        "extra_target_settings": attr.label_list(
            doc = "Additional target settings for generated Zig SDK toolchain targets.",
            mandatory = False,
            default = [],
        ),
    },
    doc = """\
Fetch and define toolchain targets for the given Zig SDK version.

Defaults to the latest known version.
""",
)

zig_extra_exec_compatible_with = tag_class(
    attrs = {
        "constraints": attr.label_list(
            doc = "Additional execution platform constraints for generated Zig SDK toolchain targets.",
            mandatory = False,
            default = [],
        ),
    },
    doc = """\
Add execution platform constraints to all generated Zig SDK toolchain targets.
""",
)

zig_extra_target_compatible_with = tag_class(
    attrs = {
        "constraints": attr.label_list(
            doc = "Additional target platform constraints for generated Zig SDK toolchain targets.",
            mandatory = False,
            default = [],
        ),
    },
    doc = """\
Add target platform constraints to all generated Zig SDK toolchain targets.
""",
)

zig_extra_target_settings = tag_class(
    attrs = {
        "settings": attr.label_list(
            doc = "Additional target settings for generated Zig SDK toolchain targets.",
            mandatory = False,
            default = [],
        ),
    },
    doc = """\
Add target settings to all generated Zig SDK toolchain targets.
""",
)

zig_index = tag_class(
    attrs = {
        "file": attr.label(doc = "The Zig version index JSON file.", mandatory = True),
    },
    doc = """\
Extend the set of known Zig SDK versions based on a Zig version index.

The provided index must use a schema that is compatible with the [upstream index].

[upstream index]: https://ziglang.org/download/index.json
""",
)

zig_mirrors = tag_class(
    attrs = {
        "urls": attr.string_list(doc = "The mirrors base URLs.", mandatory = True),
    },
)

TAG_CLASSES = {
    "toolchain": zig_toolchain,
    "extra_exec_compatible_with": zig_extra_exec_compatible_with,
    "extra_target_compatible_with": zig_extra_target_compatible_with,
    "extra_target_settings": zig_extra_target_settings,
    "index": zig_index,
    "mirrors": zig_mirrors,
}

def handle_toolchain_tags(modules, *, known_versions):
    """Handle the zig module extension's toolchain tags.

    Exposed as a standalone function for unit testing.

    Args:
      modules: sequence of module objects.
      known_versions: sequence of string, The set of known Zig versions.

    Returns:
      (err, versions, variants), maybe an error, the ordered list of versions,
        and the list of requested toolchain wrappers.
    """
    default = None
    versions = sets.make()
    variants = []
    variant_keys = {}
    global_extra_exec_compatible_with = []
    global_extra_target_compatible_with = []
    global_extra_target_settings = []

    for mod in modules:
        for extra in mod.tags.extra_exec_compatible_with:
            if not mod.is_root:
                return (["Only the root module may specify extra Zig SDK execution constraints.", extra], None, None)

            global_extra_exec_compatible_with.extend([str(label) for label in extra.constraints])

        for extra in mod.tags.extra_target_compatible_with:
            if not mod.is_root:
                return (["Only the root module may specify extra Zig SDK target constraints.", extra], None, None)

            global_extra_target_compatible_with.extend([str(label) for label in extra.constraints])

        for extra in mod.tags.extra_target_settings:
            if not mod.is_root:
                return (["Only the root module may specify extra Zig SDK target settings.", extra], None, None)

            global_extra_target_settings.extend([str(label) for label in extra.settings])

    for mod in modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.default:
                if not mod.is_root:
                    return (["Only the root module may specify a default Zig SDK version.", toolchain], None, None)

                if default != None:
                    return (["You may only specify one default Zig SDK version.", toolchain], None, None)

                default = toolchain.zig_version

            sets.insert(versions, toolchain.zig_version)
            key = "{}\n{}".format(toolchain.zig_version, toolchain.name)
            extra_exec_compatible_with = global_extra_exec_compatible_with + [str(label) for label in toolchain.extra_exec_compatible_with]
            extra_target_compatible_with = global_extra_target_compatible_with + [str(label) for label in toolchain.extra_target_compatible_with]
            extra_target_settings = global_extra_target_settings + [str(label) for label in toolchain.extra_target_settings]
            variant_fingerprint = repr((extra_exec_compatible_with, extra_target_compatible_with, extra_target_settings))
            if key in variant_keys:
                if variant_keys[key] == variant_fingerprint:
                    continue

                return (["Conflicting Zig SDK toolchain variant name '{}' for version '{}'.".format(toolchain.name, toolchain.zig_version), toolchain], None, None)

            variant_keys[key] = variant_fingerprint
            variants.append(struct(
                name = toolchain.name,
                zig_version = toolchain.zig_version,
                extra_exec_compatible_with = extra_exec_compatible_with,
                extra_target_compatible_with = extra_target_compatible_with,
                extra_target_settings = extra_target_settings,
            ))

    if default != None:
        sets.remove(versions, default)

    versions = semver.sorted(sets.to_list(versions), reverse = True)

    if default != None:
        versions.insert(0, default)

    if len(versions) == 0:
        versions.append(known_versions[0])
        variants.append(struct(
            name = "",
            zig_version = known_versions[0],
            extra_exec_compatible_with = global_extra_exec_compatible_with,
            extra_target_compatible_with = global_extra_target_compatible_with,
            extra_target_settings = global_extra_target_settings,
        ))

    return None, versions, variants

def parse_zig_versions_json(json_string):
    """Parse a Zig SDK versions index in JSON format.

    Exposed as a standalone function for unit testing.

    Args:
      json_string: String, The version index in JSON format.

    Returns:
      (err, data), maybe an error or a
        `dict[version, dict[platform, struct(url, sha256)]]`.
    """
    result = {}

    data = json.decode(json_string, default = None)

    if data == None:
        return "Invalid JSON format in Zig SDK version index.", None

    for version, platforms in data.items():
        if "version" in platforms:
            version = platforms["version"]

        if not semver.is_valid(version):
            return "Malformed version number '{}' in Zig SDK version index.".format(version), None

        for platform, info in platforms.items():
            if type(info) != "dict" or not platform in PLATFORMS:
                continue

            if not "tarball" in info:
                return "Missing `tarball` field in Zig SDK version index.", None

            if not "shasum" in info:
                return "Missing `shasum` field in Zig SDK version index.", None

            result.setdefault(version, {})[platform] = struct(
                url = info["tarball"],
                sha256 = info["shasum"],
            )

    return None, result

def merge_version_specs(version_specs):
    """Merge Zig SDK version indices.

    Exposed as a standalone function for unit testing.

    Args:
      version_specs: sequence of `dict[version, dict[platform, struct(url, sha256)]]`.

    Returns:
      `dict[version, dict[platform, struct(url, sha256)]]`
    """
    result = {}

    for spec in version_specs:
        for version, platforms in spec.items():
            for platform, info in platforms.items():
                result.setdefault(version, {})[platform] = info

    return result

def _toolchain_extension(module_ctx):
    mirrors = []
    version_specs = []
    for mod in module_ctx.modules:
        for mirrors_tag in mod.tags.mirrors:
            mirrors.extend(mirrors_tag.urls)
        for index in mod.tags.index:
            file_path = module_ctx.path(index.file)
            file_content = module_ctx.read(file_path)
            (err, parsed) = parse_zig_versions_json(file_content)

            if err != None:
                fail(err, index)

            version_specs.append(parsed)

    known_versions = merge_version_specs(version_specs)

    (err, versions, toolchain_variants) = handle_toolchain_tags(module_ctx.modules, known_versions = known_versions.keys())
    if err != None:
        fail(*err)

    toolchain_names = []
    toolchain_labels = []
    toolchain_zig_versions = []
    toolchain_exec_platforms = []
    toolchain_exec_lengths = []
    toolchain_exec_constraints = []
    toolchain_target_compatible_lengths = []
    toolchain_target_compatible_constraints = []
    toolchain_target_settings_lengths = []
    toolchain_target_settings = []
    for zig_version in versions:
        sanitized_zig_version = sanitize_version(zig_version)
        for platform, meta in PLATFORMS.items():
            repo_name = _DEFAULT_NAME + "_" + sanitized_zig_version + "_" + platform
            zig_repository(
                name = repo_name,
                url = known_versions[zig_version][platform].url,
                mirrors = mirrors,
                sha256 = known_versions[zig_version][platform].sha256,
                zig_version = zig_version,
                platform = platform,
            )
            for variant in toolchain_variants:
                if variant.zig_version != zig_version:
                    continue

                name = repo_name
                if variant.name:
                    name = "{}_{}".format(name, variant.name)

                compatible_with = meta.compatible_with + variant.extra_exec_compatible_with
                toolchain_names.append(name)
                toolchain_labels.append("@{}//:zig_toolchain".format(repo_name))
                toolchain_zig_versions.append(zig_version)
                toolchain_exec_platforms.append(platform)
                toolchain_exec_lengths.append(len(compatible_with))
                toolchain_exec_constraints.extend(compatible_with)
                toolchain_target_compatible_lengths.append(len(variant.extra_target_compatible_with))
                toolchain_target_compatible_constraints.extend(variant.extra_target_compatible_with)
                toolchain_target_settings_lengths.append(len(variant.extra_target_settings))
                toolchain_target_settings.extend(variant.extra_target_settings)

    toolchains_repo(
        name = _DEFAULT_NAME + "_toolchains",
        names = toolchain_names,
        labels = toolchain_labels,
        zig_versions = toolchain_zig_versions,
        exec_platforms = toolchain_exec_platforms,
        exec_lengths = toolchain_exec_lengths,
        exec_constraints = toolchain_exec_constraints,
        target_compatible_lengths = toolchain_target_compatible_lengths,
        target_compatible_constraints = toolchain_target_compatible_constraints,
        target_settings_lengths = toolchain_target_settings_lengths,
        target_settings = toolchain_target_settings,
    )

zig = module_extension(
    implementation = _toolchain_extension,
    doc = DOC,
    tag_classes = TAG_CLASSES,
)
