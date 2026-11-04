#!/usr/bin/env python3

import json
import re
import sys


BAZEL_BIN_RE = re.compile(r"__BAZEL_EXECUTION_ROOT__/bazel-out/[^/]+/bin/")


def normalize(value):
    if isinstance(value, dict):
        return {normalize(key): normalize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, str):
        return BAZEL_BIN_RE.sub("__BAZEL_BIN__/", value)
    return value


def main(argv):
    if len(argv) != 3:
        print("usage: normalize_zls_build_config.py <input> <output>", file=sys.stderr)
        return 2

    with open(argv[1], encoding="utf-8") as input_file:
        config = json.load(input_file)

    with open(argv[2], "w", encoding="utf-8", newline="\n") as output_file:
        json.dump(normalize(config), output_file, indent=2, sort_keys=True)
        output_file.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
