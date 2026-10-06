#!/usr/bin/env python3

import argparse
import json
from string import Template
import urllib.request


_ZIG_INDEX_URL = "https://ziglang.org/download/index.json"

_UNSUPPORTED_VERSIONS = [
    "0.15.2",
    "0.15.1",
    "0.14.1",
    "0.14.0",
    "0.13.0",
    "0.12.1",
    "0.12.0",
    "0.11.0",
    "0.10.1",
    "0.10.0",
    "0.9.1",
    "0.9.0",
    "0.8.1",
    "0.8.0",
    "0.7.1",
    "0.7.0",
    "0.6.0",
    "0.5.0",
    "0.4.0",
    "0.3.0",
    "0.2.0",
    "0.1.1"]

_SUPPORTED_PLATFORMS = [
    "aarch64-linux",
    "aarch64-macos",
    "aarch64-windows",
    "x86_64-linux",
    "x86_64-macos",
    "x86_64-windows",
    "x86-linux",
    "x86-windows"]


def fetch_zig_versions(url):
    with urllib.request.urlopen(url) as response:
        if response.status != 200:
            raise Exception(f"HTTP error: {response.status}")
        data = response.read()
        return json.loads(data.decode('utf-8'))


def _parse_semver(version_str):
    """Split a semantic version into its components.

    Raises an error if the version is malformed.

    If the version contains no pre-release component, then a sentinel of
    `0x10FFFF` is returned. The intent is that it sorts higher than any other
    code-point, therefore making versions without pre-release component sort
    higher than this with.

    If the version is the string `master` then it returns a maximum version
    comprising `float("inf")` components and the pre-release sentinel.

    Returns:
      (major, minor, patch, pre_release)
    """
    max_component = float("inf")
    max_prerelease = chr(0x10FFFF)  # Highest valid code point in Unicode

    if version_str == "master":
        return max_component, max_component, max_component, max_prerelease

    pre_version, *_ = version_str.split("+", maxsplit=1)
    main_version, *pre_release = pre_version.split("-", maxsplit=1)
    major, minor, patch = map(int, main_version.split("."))

    pre_release_segment = pre_release[0] if pre_release else max_prerelease

    return major, minor, patch, pre_release_segment


def generate_json_content(data, unsupported_versions, supported_platforms):
    content = {}

    for version, platforms in sorted(data.items(), key=lambda x: _parse_semver(x[0]), reverse=True):
        if version in unsupported_versions or version == "master":
            continue

        for platform, info in sorted(platforms.items()):
            if platform not in supported_platforms or not isinstance(info, dict):
                continue

            content.setdefault(version, {})[platform] = {
                "tarball": info["tarball"],
                "shasum": info["shasum"],
            }

    return content


def main():
    parser = argparse.ArgumentParser(description="Generate JSON file for Zig compiler versions.")
    parser.add_argument("--output", type=argparse.FileType('w'), default='-', help="Output file path or '-' for stdout.")
    parser.add_argument("--url", default=_ZIG_INDEX_URL, help="URL to fetch Zig versions JSON")
    parser.add_argument("--unsupported-versions", nargs="*", default=_UNSUPPORTED_VERSIONS, help="List of unsupported Zig versions")
    parser.add_argument("--supported-platforms", nargs="*", default=_SUPPORTED_PLATFORMS, help="List of supported platforms")
    bzl_parser = parser.add_argument_group(title="Starlark module", description="Generate a Starlark module to capture the Zig versions")
    bzl_parser.add_argument("--template-bzl", type=argparse.FileType('r'), default=None, help="Template file, replace the $ZIG_VERSIONS_JSON placeholder")
    bzl_parser.add_argument("--output-bzl", type=argparse.FileType('w'), default=None, help="Output file")
    args = parser.parse_args()

    if args.template_bzl or args.output_bzl:
        if not (args.template_bzl and args.output_bzl):
            parser.exit(1, "Either both or none of --template-bzl and --output-bzl must be specified.\n")

    zig_data = fetch_zig_versions(args.url)
    json_content = generate_json_content(zig_data, set(args.unsupported_versions), set(args.supported_platforms))

    json.dump(json_content, args.output, indent=2)
    args.output.write("\n")

    if args.template_bzl or args.output_bzl:
        bzl = Template(args.template_bzl.read())
        args.output_bzl.write(bzl.substitute({
            "ZIG_VERSIONS_JSON": json.dumps(json_content, indent=2),
        }))


if __name__ == "__main__":
    main()
