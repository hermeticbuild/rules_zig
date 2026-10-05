#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Set by GH actions, see
# https://docs.github.com/en/actions/learn-github-actions/environment-variables#default-environment-variables
TAG=${GITHUB_REF_NAME}
VERSION=${TAG:1}
# The prefix is chosen to match what GitHub generates for source archives
PREFIX="rules_zig-$VERSION"
ARCHIVE="$PREFIX.tar.gz"
git archive --format=tar --prefix=${PREFIX}/ ${TAG} | gzip > $ARCHIVE

ZIG_VERSION="$(jq -r 'keys_unsorted[0]' zig/private/versions.json)"
ZLS_VERSION="$(jq -r 'keys_unsorted[0]' zig/zls/private/versions.json)"

cat << EOF
## Setup Instructions

Add the following to your \`MODULE.bazel\` file to install rules_zig:

\`\`\`starlark
bazel_dep(name = "rules_zig", version = "$VERSION")
\`\`\`

Optionally add the following to your \`MODULE.bazel\` file to install a specific Zig toolchain version:

\`\`\`starlark
zig = use_extension("@rules_zig//zig:extensions.bzl", "zig")
zig.toolchain(zig_version = "$ZIG_VERSION")
\`\`\`

You can call \`zig.toolchain\` multiple times to install multiple Zig versions.

Optionally add the following to your \`MODULE.bazel\` file to install a specific ZLS toolchain version and declare what Zig version it applies to:

\`\`\`starlark
zls = use_extension("@rules_zig//zig/zls:extensions.bzl", "zls")
zls.toolchain(zig_version = "$ZLS_VERSION", zls_version = "$ZLS_VERSION")
\`\`\`

You can call \`zls.toolchain\` multiple times to install multiple ZLS versions.

Note, rules_zig requires bzlmod, WORKSPACE mode is no longer supported.
EOF
