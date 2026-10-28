"""Defines providers for the Zig toolchain rule."""

DOC = """\
Information about how to invoke the Zig executable.
"""

FIELDS = {
    "mode": "String, Either 'file' for hermetic toolchains or 'path' for local absolute-path toolchains.",
    "zig_exe": "Struct containing either a File or absolute path for the Zig executable.",
    "zig_lib": "Struct containing either Files or an absolute path for the Zig lib directory.",
    "zig_version": "String, The Zig toolchain's version.",
    "zig_cache": "String, The Zig cache directory prefix used for the global and local cache.",
    "validation": "File, Validation output ensuring that the configured Zig version matches.",
}

ZigToolchainInfo = provider(
    doc = DOC,
    fields = FIELDS,
)

def zig_file_toolchain_info(*, zig_exe, zig_h, zig_lib, zig_version, zig_cache, validation):
    return ZigToolchainInfo(
        mode = "file",
        zig_exe = struct(
            file = zig_exe,
            path = None,
        ),
        zig_lib = struct(
            file = zig_lib,
            header = zig_h,
            path = None,
        ),
        zig_version = zig_version,
        zig_cache = zig_cache,
        validation = validation,
    )

def zig_path_toolchain_info(*, zig_exe_path, zig_lib_path, zig_version, zig_cache, validation):
    return ZigToolchainInfo(
        mode = "path",
        zig_exe = struct(
            file = None,
            path = zig_exe_path,
        ),
        zig_lib = struct(
            file = None,
            header = None,
            path = zig_lib_path,
        ),
        zig_version = zig_version,
        zig_cache = zig_cache,
        validation = validation,
    )

def zig_toolchain_executable(zigtoolchaininfo):
    if zigtoolchaininfo.zig_exe.file != None:
        return zigtoolchaininfo.zig_exe.file
    return zigtoolchaininfo.zig_exe.path

def zig_toolchain_executable_path(zigtoolchaininfo):
    if zigtoolchaininfo.zig_exe.file != None:
        return zigtoolchaininfo.zig_exe.file.path
    return zigtoolchaininfo.zig_exe.path

def zig_toolchain_lib_dir(zigtoolchaininfo):
    if zigtoolchaininfo.zig_lib.file != None:
        return zigtoolchaininfo.zig_lib.file
    return zigtoolchaininfo.zig_lib.path

def zig_toolchain_lib_dir_path(zigtoolchaininfo):
    if zigtoolchaininfo.zig_lib.file != None:
        return zigtoolchaininfo.zig_lib.file.path
    return zigtoolchaininfo.zig_lib.path

def zig_toolchain_header(zigtoolchaininfo):
    return zigtoolchaininfo.zig_lib.header
