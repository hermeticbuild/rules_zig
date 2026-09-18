"""Defines providers for the settings rule."""

DOC = """\
Collection of all active Zig build settings.
"""

FIELDS = {
    "mode": "The Zig build mode.",
    "use_cc_common_link": "Whether to use cc_common.link to link zig binaries, tests and shared libraries.",
    "threaded": "The Zig multi- or single-threaded setting.",
    "strip": "Whether Zig compile actions should remove debug symbols.",
    "args": "The collected compiler arguments excluding the Bazel-derived strip flag.",
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
      strip: bool; Whether to append the Bazel-derived strip flag.
    """
    if strip and settings.strip:
        args.add("-fstrip")
    args.add_all(settings.args)
