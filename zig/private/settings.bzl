"""Implementation of the settings rule."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")

DOC = """\
Collection of all Zig build settings.

This rule is only intended for internal use.
It collects the values of all relevant build settings,
such as `@rules_zig//zig/settings:mode`.

You can build the settings target to obtain a JSON file
capturing all configured Zig build settings.
"""

MODE_ARGS = {
    "debug": ["-O", "Debug"],
    "release_safe": ["-O", "ReleaseSafe"],
    "release_small": ["-O", "ReleaseSmall"],
    "release_fast": ["-O", "ReleaseFast"],
}

MODE_VALUES = ["auto", "debug", "release_safe", "release_small", "release_fast"]

COMPILATION_MODE_TO_MODE = {
    "dbg": "debug",
    "fastbuild": "debug",
    "opt": "release_fast",
}

THREADED_ARGS = {
    "multi": ["-fno-single-threaded"],
    "single": ["-fsingle-threaded"],
}

THREADED_VALUES = ["multi", "single"]

STRIP_VALUES = ["always", "never", "sometimes"]

ATTRS = {
    "mode": attr.label(
        doc = "The build mode setting.",
        mandatory = True,
    ),
    "host_mode": attr.label(
        doc = "The build mode setting for the host configuration.",
        mandatory = True,
    ),
    "use_cc_common_link": attr.label(
        doc = "Whether to use cc_common.link to link zig binaries and shared libraries.",
        mandatory = True,
    ),
    "host_use_cc_common_link": attr.label(
        doc = "Whether to use cc_common.link to link zig binaries and shared libraries in the host configuration.",
        mandatory = True,
    ),
    "threaded": attr.label(
        doc = "The Zig multi- or single-threaded setting.",
        mandatory = True,
    ),
    "host_threaded": attr.label(
        doc = "The Zig multi- or single-threaded setting for the host configuration.",
        mandatory = True,
    ),
    "zigopt": attr.label(
        doc = """
Additional list of flags passed to the zig compiler for all Zig compile actions.

The flags specified by this setting do not override those specified via the `zigopts` attribute of `zig_*` rules.
Instead, they are prepended to the command line before module specific flags.

This is an advanced feature that can conflict with attributes, build settings, and other flags defined by the toolchain itself.
Use this at your own risk of hitting undefined behaviors.
""",
        mandatory = True,
    ),
    "host_zigopt": attr.label(
        doc = """
Additional list of flags passed to the zig compiler for all Zig compile actions
when building for the host configuration.

The flags specified by this setting do not override those specified via the `zigopts` attribute of `zig_*` rules.
Instead, they are prepended to the command line before module specific flags.

This is an advanced feature that can conflict with attributes, build settings, and other flags defined by the toolchain itself.
Use this at your own risk of hitting undefined behaviors.
""",
        mandatory = True,
    ),
    "_bazel_strip": attr.label(
        doc = "The selected Bazel --strip option value.",
        default = "//zig/settings:strip",
    ),
}

BazelStripInfo = provider(
    doc = "The selected Bazel --strip option value.",
    fields = ["strip"],
)

def _is_exec_configuration(ctx):
    return ctx.genfiles_dir.path.find("-exec") != -1

def _resolve_mode(ctx, mode):
    if mode != "auto":
        return mode

    compilation_mode = ctx.var["COMPILATION_MODE"]
    if compilation_mode not in COMPILATION_MODE_TO_MODE:
        fail("Unrecognized Bazel compilation mode {}.".format(compilation_mode))

    return COMPILATION_MODE_TO_MODE[compilation_mode]

def _resolve_strip(ctx, strip):
    if strip == "always":
        return True
    if strip == "never":
        return False
    if strip == "sometimes":
        return ctx.var["COMPILATION_MODE"] == "fastbuild"

    fail("Unrecognized Bazel strip setting {}.".format(strip))

def _settings_impl(ctx):
    args = []

    is_exec_configuration = _is_exec_configuration(ctx)

    mode = ctx.attr.host_mode[BuildSettingInfo].value if is_exec_configuration else ctx.attr.mode[BuildSettingInfo].value
    mode = _resolve_mode(ctx, mode)
    args.extend(MODE_ARGS[mode])

    threaded = ctx.attr.host_threaded[BuildSettingInfo].value if is_exec_configuration else ctx.attr.threaded[BuildSettingInfo].value
    args.extend(THREADED_ARGS[threaded])

    use_cc_common_link = ctx.attr.host_use_cc_common_link[BuildSettingInfo].value if is_exec_configuration else ctx.attr.use_cc_common_link[BuildSettingInfo].value

    strip = _resolve_strip(ctx, ctx.attr._bazel_strip[BazelStripInfo].strip)
    if strip:
        args.append("-fstrip")

    args.extend(ctx.attr.host_zigopt[BuildSettingInfo].value if is_exec_configuration else ctx.attr.zigopt[BuildSettingInfo].value)

    settings_info = ZigSettingsInfo(
        mode = mode,
        threaded = threaded,
        use_cc_common_link = use_cc_common_link,
        strip = strip,
        args = args,
    )

    settings_json = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(settings_json, json.encode(settings_info), is_executable = False)

    default_info = DefaultInfo(
        files = depset([settings_json]),
    )

    return [
        default_info,
        settings_info,
    ]

settings = rule(
    _settings_impl,
    attrs = ATTRS,
    doc = DOC,
)

def _bazel_strip_impl(ctx):
    return [BazelStripInfo(strip = ctx.attr.strip)]

bazel_strip = rule(
    _bazel_strip_impl,
    attrs = {
        "strip": attr.string(
            doc = "The Bazel --strip option value.",
            mandatory = True,
            values = STRIP_VALUES,
        ),
    },
    doc = "Captures the selected Bazel --strip option value.",
)
