"""Handle C library dependencies."""

load("@bazel_skylib//lib:paths.bzl", "paths")

_LIBC_HELPERS = (
    Label("//zig/lib:libc"),
    Label("//zig/lib:libc++"),
)

def zig_cdeps_libc_flags(linker_input):
    """Returns the compile flags from a Zig libc or libc++ dependency.

    Args:
        linker_input: cc_common.LinkerInput instance.

    Returns:
        List of Zig compiler flags or None for other linker inputs.
    """
    if linker_input.owner in _LIBC_HELPERS:
        return linker_input.user_link_flags
    return None

def zig_cdeps_copts(compilation_context):
    """Renders CcInfo.compilation_context as Zig flags.

    Zig requires C dependency flags to be set within the consuming module's
    command-line section, i.e. before its `-M` flag. Therefore, C dependency
    flags cannot be accumulated across the entire compiler invocation and
    emitted globally.

    This function is intended to be called from an `Args.add_all(..., map_each =
    ...)` callback. It flattens `CompilationContext` `depset`s via `to_list`,
    which [Bazel performance guidelines][1] warn against.

    This is safe, because `Args.add_all` does not materialize the argument list,
    but stores it for [lazy expansion][2]. Full expansion only occurs [during
    execution][3] (see [`StarlarkCustomCommandLine`][4] [`preprocess`][5]).

    Action key calculation does [invoke][6] the `map_each` callback (and thus
    this `to_list`) for [fingerprinting][7], including at analysis time for
    shared-action [conflict checking][8]. But it does not flatten the module
    depset; it walks the structure with [per-subtree digest memoization][9]. The
    `CompilationContext` `depset`s this `to_list` flattens are separately cached
    on their `NestedSet` behind a [GC-evictable weak reference][10], so they are
    recomputed only under memory pressure.

    [1]: https://bazel.build/rules/performance#avoid-depset-to-list
    [2]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/analysis/starlark/Args.java#L448-L463
    [3]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/analysis/actions/SpawnAction.java#L366-L379
    [4]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/analysis/starlark/StarlarkCustomCommandLine.java#L92-L104
    [5]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/analysis/starlark/StarlarkCustomCommandLine.java#L328-L350
    [6]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/analysis/actions/SpawnAction.java#L398-L408
    [7]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/analysis/starlark/StarlarkCustomCommandLine.java#L544-L559
    [8]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/actions/Actions.java#L76-L93
    [9]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/collect/nestedset/NestedSetFingerprintCache.java#L99-L116
    [10]: https://github.com/bazelbuild/bazel/blob/7bfc0881726bbdd6394f210f6132c6973f5532bb/src/main/java/com/google/devtools/build/lib/collect/nestedset/NestedSet.java#L153-L160

    Args:
        compilation_context: `CompilationContext`.

    Returns:
        list of string, Zig compiler flags.
    """
    copts = []
    copts.extend(["-D%s" % define for define in compilation_context.defines.to_list()])
    copts.extend(["-I%s" % include for include in compilation_context.includes.to_list()])

    # Note, Zig does not support `-iquote` as of Zig 0.12.0
    copts.extend(["-I%s" % include for include in compilation_context.quote_includes.to_list()])
    for include in compilation_context.system_includes.to_list():
        copts.extend(["-isystem", include])
    if hasattr(compilation_context, "external_includes"):
        # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
        for include in compilation_context.external_includes.to_list():
            copts.extend(["-isystem", include])
    copts.extend(["-F%s" % include for include in compilation_context.framework_includes.to_list()])
    return copts

def zig_cdeps_linker_inputs(*, linking_context, solib_parents, os, abi, inputs, args, data):
    """Compiler arguments and inputs from a CcInfo.linking_context.

    Args:
        linking_context: cc_common.LinkingContext instance.
        solib_parents: A list of strings representing the solib parent directories.
        os: String; The target operating system.
        abi: String; The target ABI.
        inputs: List; mutable, Append linker inputs to this collection.
        args: Args; mutable, Append the C linker flags to this object.
        data: List; mutable, Append data files to this collection.
    """
    all_libraries = []
    dynamic_libraries = []
    for link in linking_context.linker_inputs.to_list():
        # These helpers' flags were added to the Zig compile arguments.
        if link.owner not in _LIBC_HELPERS:
            if os == "linux" and abi and abi.split(".")[0] == "gnu":
                # The C driver accepts -pthread. Zig's native link CLI uses
                # -lpthread to request its bundled glibc instead.
                args.add_all(["-lpthread" if flag == "-pthread" else flag for flag in link.user_link_flags])
            else:
                args.add_all(link.user_link_flags)
        inputs.extend(link.additional_inputs)
        for lib in link.libraries:
            # TODO[AH] Handle the remaining LibraryToLink metadata as needed:
            #   lto_bitcode_files
            #   pic_lto_bitcode_files
            #   resolved_symlink_dynamic_library
            #   resolved_symlink_interface_library
            archive = lib.static_library or lib.pic_static_library
            if archive:
                if lib.alwayslink:
                    # Including every member preserves whole-archive semantics.
                    # The archive basename does not reliably identify the PIC variant.
                    objects = lib.objects if lib.static_library else lib.pic_objects
                    if not objects:
                        fail("Cannot link alwayslink archive {} from {} with Zig: no member objects are available. Use use_cc_common_link for archive-only imports.".format(archive.path, link.owner))
                    all_libraries.extend([(object, False) for object in objects])
                    inputs.extend(objects)
                else:
                    # Keep ordinary archives available for lazy member extraction.
                    all_libraries.append((archive, False))
                    inputs.append(archive)
            else:
                file = lib.interface_library or lib.dynamic_library
                if not file:
                    continue
                all_libraries.append((file, True))
                inputs.append(file)
                if lib.dynamic_library:
                    dynamic_libraries.append(lib.dynamic_library)

    args.add_all(
        all_libraries,
        map_each = _lib_flags,
        uniquify = True,
    )
    data.extend(dynamic_libraries)
    args.add_all(
        dynamic_libraries,
        map_each = _make_to_rpath(solib_parents, os),
        allow_closure = True,
        before_each = "-rpath",
        uniquify = True,
    )

def _lib_flags(arg):
    (file, dynamic) = arg
    if dynamic:
        ext_skip = len(file.extension) + 1
        if file.basename.startswith("lib"):
            libname = file.basename[3:-ext_skip]
        else:
            libname = file.basename[:-ext_skip]
        return ["-L" + file.dirname, "-l" + libname]
    else:
        return file.path

def _make_to_rpath(solib_parents, os):
    origin = "$ORIGIN"

    # Based on `zig targets | jq .os`
    if os in ["freebsd", "ios", "macos", "netbsd", "openbsd", "tvos", "watchos"]:
        origin = "@loader_path"

    def to_rpath(lib):
        result = []
        for parent in solib_parents:
            result.append(paths.join(origin, parent, paths.dirname(lib.short_path)))
        return result

    return to_rpath
