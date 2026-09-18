"""Defines providers for the settings rule."""

DOC = """\
Collection of all active Zig build settings.
"""

FIELDS = {
    "mode": "The Zig build mode.",
    "use_cc_common_link": "Whether to use cc_common.link to link zig binaries, tests and shared libraries.",
    "threaded": "The Zig multi- or single-threaded setting.",
    "strip": "Whether Zig compile actions should remove debug symbols.",
    "args": "The collected compiler arguments for all active settings.",
}

ZigSettingsInfo = provider(
    doc = DOC,
    fields = FIELDS,
)

def zig_settings(*, settings, args, strip = True):
    """Set flags for the given Zig build settings.

    Args:
      settings: ZigSettingsInfo, The active Zig build settings.
      args: Args; mutable, Append the needed Zig compiler flags to this object.
      strip: bool; Whether to append the Bazel-derived strip flag. Explicit zigopts are preserved.
    """
    if strip or not settings.strip:
        args.add_all(settings.args)
        return

    settings_args = []
    strip_removed = False
    for arg in settings.args:
        if not strip_removed and arg == "-fstrip":
            strip_removed = True
        else:
            settings_args.append(arg)
    args.add_all(settings_args)
