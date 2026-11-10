"""Reproducible ZLS 0.17 path-fix backport, using the upstream build graph."""

load("//zig/private/providers:zig_toolchain_info.bzl", "zig_toolchain_executable", "zig_toolchain_lib_dir_path")

_VERSION = "0.17.0+bazel.bbd60390"
_SOURCE = "542462c4ddf045493fa9ca028ee6bc3f38b2754a"
_PLATFORMS = {
    "x86_64-linux": ("x86_64", "linux"),
    "aarch64-linux": ("aarch64", "linux"),
    "x86_64-macos": ("x86_64", "macos"),
    "aarch64-macos": ("aarch64", "macos"),
}

# The enabled dependency closure from the pinned build.zig.zon. Tracy is disabled.
_PACKAGES = [
    ("ziglibs/known-folders", "6da0d0c41b78b9ed2d34fa364fcb81b5ebece6c4", "known_folders-0.0.0-Fy-PJiDLAAB98m3uYUzatrTb2mO2fpvwx2zpSroEtfbO", "194aaa7566f3d9b4e893e3e53ef46ce880d4fc3631535ccea05405f558070f39"),
    ("ziglibs/diffz", "aac8aa99c436ab8277b0711922aad062c0167b12", "diffz-0.0.1-G2tlISvOAQDORzPTSxDgiKwlHuADKeJMdJrw4kRfLufj", "33036e596176426449617975113eeddf513c991f42e10df855ccfb0e6f103fae"),
    ("zigtools/lsp-kit", "3e1058db66079911fdde82f833fdce6856e0a706", "lsp_kit-0.1.0-bi_PL9o2DADHS1PDra3MGz1MXnsboN_ewNvrc419z7Fb", "06dab48dad0dd5770bdcaa64fe13b386e479a67dc81899005d04f48897ec2003"),
]

def _source_repository_impl(ctx):
    ctx.download_and_extract(
        url = "https://codeload.github.com/zigtools/zls/tar.gz/" + _SOURCE,
        type = "tar.gz",
        sha256 = "3eb3107317ef948783cdc3daae07238f1fe7c6cf28fe8ed1a776ff38df781224",
        stripPrefix = "zls-" + _SOURCE,
    )
    ctx.patch(ctx.path(ctx.attr._patch), strip = 1)
    for repo, revision, package_hash, sha256 in _PACKAGES:
        ctx.download_and_extract(
            url = "https://codeload.github.com/{}/tar.gz/{}".format(repo, revision),
            type = "tar.gz",
            sha256 = sha256,
            stripPrefix = repo.split("/")[-1] + "-" + revision,
            output = "deps/" + package_hash,
        )
    build = """\
load("@rules_zig//zig/zls/private:source.bzl", "zls_source_binary")
load("@rules_zig//zig/zls:toolchain.bzl", "zls_toolchain")
"""
    for target, (cpu, os) in _PLATFORMS.items():
        build += """
config_setting(
    name = "{target}",
    constraint_values = ["@platforms//os:{os}", "@platforms//cpu:{cpu}"],
)
""".format(target = target, cpu = cpu, os = os)
    build += """

zls_source_binary(
    name = "zls",
    build_file = "build.zig",
    srcs = glob(["**"], exclude = ["BUILD.bazel"]),
    target = select({targets}),
    visibility = ["//visibility:public"],
)
zls_toolchain(name = "implementation", bin = "zls", zls_version = "{version}")
""".format(version = _VERSION, targets = repr({":" + target: target for target in _PLATFORMS}))
    for version in ["0.17.0", "0.17.1"]:
        build += """
config_setting(
    name = "sdk_{version}",
    flag_values = {{"@zig_toolchains//:version": "{version}"}},
)
""".format(version = version)
        for target, (cpu, os) in _PLATFORMS.items():
            build += """
toolchain(
    name = "{target}_{version}",
    exec_compatible_with = ["@platforms//os:{os}", "@platforms//cpu:{cpu}"],
    target_settings = [":sdk_{version}"],
    toolchain = "implementation",
    toolchain_type = "@rules_zig//zig/zls:toolchain_type",
    visibility = ["//visibility:public"],
)
""".format(target = target, cpu = cpu, os = os, version = version)
    ctx.file("BUILD.bazel", build)
    return ctx.repo_metadata(reproducible = True)

zls_source_repository = repository_rule(
    implementation = _source_repository_impl,
    attrs = {
        "_patch": attr.label(default = Label("//zig/zls/private:zls-0.17.0-bbd60390.patch")),
    },
    doc = "Fetch the pinned ZLS 0.17.0 source and upstream absolute-path correction. Register the generated native toolchains explicitly.",
)

def _source_binary_impl(ctx):
    sdk = ctx.toolchains["//zig:toolchain_type"].zigtoolchaininfo
    if sdk.zig_version not in ["0.17.0", "0.17.1"]:
        fail("The corrected ZLS source build requires Zig 0.17.0 or 0.17.1.")
    executable = ctx.actions.declare_file(ctx.label.name + "/zls")
    cache = ctx.actions.declare_directory(ctx.label.name + ".cache")
    inputs = ctx.files.srcs + [sdk.validation]
    if sdk.zig_lib.file:
        inputs.append(sdk.zig_lib.file)
    ctx.actions.run(
        executable = zig_toolchain_executable(sdk),
        inputs = inputs,
        outputs = [executable, cache],
        arguments = [
            "build",
            "--build-file",
            ctx.file.build_file.path,
            "--system",
            ctx.file.build_file.dirname + "/deps",
            "--cache-dir",
            cache.path + "/local",
            "--prefix",
            executable.dirname,
            "--prefix-exe-dir",
            ".",
            "-Doptimize=ReleaseFast",
            # Explicit architecture/OS uses SDK baseline CPU and OS versions,
            # rather than querying untracked executor CPUID or OS-version state.
            "-Dtarget=" + ctx.attr.target,
            "-Dversion-string=" + _VERSION,
        ],
        env = {
            "ZIG_LIB_DIR": zig_toolchain_lib_dir_path(sdk),
            "ZIG_GLOBAL_CACHE_DIR": cache.path + "/global",
            # This takes precedence over --system. Never inherit a user's package cache.
            "ZIG_LOCAL_PKG_DIR": ctx.file.build_file.dirname + "/deps",
        },
        mnemonic = "ZlsSourceBuild",
        progress_message = "Building corrected ZLS " + _VERSION,
    )
    return [DefaultInfo(executable = executable, files = depset([executable]), runfiles = ctx.runfiles(files = [executable]))]

zls_source_binary = rule(
    implementation = _source_binary_impl,
    attrs = {
        "build_file": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "target": attr.string(mandatory = True, values = _PLATFORMS.keys()),
    },
    executable = True,
    toolchains = ["//zig:toolchain_type"],
)
