"""Implementation of the zls_completion macro."""

load("@aspect_bazel_lib//lib:utils.bzl", "utils")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load("//zig:defs.bzl", "zig_binary", "zig_test")
load("//zig/zls:zls_write_build_config.bzl", "zls_write_build_config")
load("//zig/zls:zls_write_runner_zig_src.bzl", "zls_write_runner_zig_src")

def zls_completion(name, deps, testonly = False, **kwargs):
    """Entry point for ZLS completion.

    Args:
        name: The name of the completion target.
        deps: The List of Zig modules to include for completion.
        testonly: Whether generated targets should be test-only.
        **kwargs: Additional keyword arguments passed to the `zig_binary`;
          `target_compatible_with` also applies to the ZLS runner.
    """

    # Generate the ZLS BuildConfig file.
    # It contains the list of Zig packages alongside their main Zig file paths.
    build_config = name + ".build_config"
    build_config_file = name + ".build_config.json"
    zls_write_build_config(
        name = build_config,
        out = build_config_file,
        deps = deps,
        testonly = testonly,
    )

    # Create a target that will be invoked by ZLS using our customer build_runner.
    build_config_printer = "{}.print_build_config".format(name)
    zig_binary(
        name = build_config_printer,
        main = Label("//zig/zls:workspace_printer.zig"),
        data = [
            ":{}".format(build_config),
            ":{}".format(build_config_file),
        ],
        args = [
            "$(rlocationpath :{})".format(build_config_file),
            "$(execpath :{})".format(build_config_file),
        ],
        deps = [
            Label("//zig/runfiles"),
        ],
        visibility = ["//visibility:private"],
        testonly = testonly,
    )

    # Used to verify that the build config printer works as expected.
    # Prevent regressions.
    zig_test(
        name = "{}_test".format(build_config_printer),
        size = "small",
        main = Label("//zig/zls:workspace_printer_test.zig"),
        srcs = [Label("//zig/zls:workspace_printer.zig")],
        data = deps + [
            ":{}".format(build_config),
            ":{}".format(build_config_file),
            ":{}".format(build_config_printer),
        ],
        zigopts = [
            "-lc",
        ],
        env = {
            "COMPLETION_BUILD_CONFIG_RLOCATION": "$(rlocationpath :{})".format(build_config_file),
            "COMPLETION_PACKAGE": native.package_name(),
            "COMPLETION_PRINTER_RLOCATION": "$(rlocationpath :{})".format(build_config_printer),
        },
        deps = [
            Label("//zig/runfiles"),
        ],
        testonly = testonly,
    )

    # Generate the Zig build runner that will be used by ZLS to query the build config.
    expand_template(
        name = name + ".build_runner",
        out = name + ".build_runner.zig",
        substitutions = {
            "__TARGET__": str(utils.to_label(build_config_printer)),
        },
        template = Label("//zig/zls:zls_build_runner.zig"),
        testonly = testonly,
    )

    # Generate the Zig source file for the ZLS runner binary which embeds the
    # rlocationpath of all runtime dependencies of the ZLS runner binary.
    zls_write_runner_zig_src(
        name = name + ".runner",
        out = name + ".runner.zig",
        runner_tpl = select({
            Label("//zig/zls:native_protocol"): Label("//zig/zls:zls_runner_017.zig"),
            "//conditions:default": Label("//zig/zls:zls_runner.zig"),
        }),
        build_runner = select({
            Label("//zig/zls:native_protocol"): None,
            "//conditions:default": name + ".build_runner.zig",
        }),
        # These tools run in the editor, even when build actions run remotely.
        exec_compatible_with = [Label(constraint) for constraint in HOST_CONSTRAINTS],
        printer_target = str(utils.to_label(build_config_printer)),
        testonly = testonly,
        target_compatible_with = kwargs.get("target_compatible_with"),
    )

    zig_binary(
        name = name,
        main = name + ".runner",
        data = [
            name + ".runner",
        ] + select({
            Label("//zig/zls:native_protocol"): [],
            "//conditions:default": [name + ".build_runner"],
        }),
        deps = [
            Label("//zig/zls:zls_runner_common"),
        ] + select({
            Label("//zig/zls:native_protocol"): [
                Label("//zig/zls:owned_process"),
                Label("//zig/zls:zls_bsp"),
            ],
            "//conditions:default": [],
        }),
        zigopts = kwargs.pop("zigopts", []) + select({
            Label("//zig/zls:native_protocol"): ["-lc"],
            "//conditions:default": [],
        }),
        testonly = testonly,
        **kwargs
    )
