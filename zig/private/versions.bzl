"""Mirror of Zig release info.

Generated from https://ziglang.org/download/index.json.
"""

def _parse(json_string):
    result = {}

    data = json.decode(json_string)
    for version, platforms in data.items():
        for platform, info in platforms.items():
            result.setdefault(version, {})[platform] = struct(
                url = info["tarball"],
                sha256 = info["shasum"],
            )

    return result

TOOL_VERSIONS = _parse("""\
{
  "0.17.0": {
    "aarch64-linux": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz",
      "shasum": "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8"
    },
    "aarch64-macos": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
      "shasum": "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a"
    },
    "aarch64-windows": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-aarch64-windows-0.17.0.zip",
      "shasum": "0a59d91fa1cb40cf068e9b0954434ce973500c7a2ea749f1e01af62cdab52d26"
    },
    "x86-linux": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-x86-linux-0.17.0.tar.xz",
      "shasum": "55e39e175cd5b3098afc29ec47b2590134f5b874175369fb9ae7b8e836d7531a"
    },
    "x86-windows": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-x86-windows-0.17.0.zip",
      "shasum": "c7b83507549c7bcd42cd58c4910b47037f4150ed7778e11b3684f130620969d1"
    },
    "x86_64-linux": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz",
      "shasum": "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026"
    },
    "x86_64-macos": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-macos-0.17.0.tar.xz",
      "shasum": "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6"
    },
    "x86_64-windows": {
      "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
      "shasum": "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428"
    }
  },
  "0.16.0": {
    "aarch64-linux": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz",
      "shasum": "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"
    },
    "aarch64-macos": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz",
      "shasum": "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
    },
    "aarch64-windows": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-aarch64-windows-0.16.0.zip",
      "shasum": "aee38316ee4111717900f45dd3130145c39289e105541d737eb8c5ed653c78ef"
    },
    "x86-linux": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-x86-linux-0.16.0.tar.xz",
      "shasum": "4e34e279a9f856358de420490b531974c3d37f8f3707eef9f0342e92c14c301f"
    },
    "x86-windows": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-x86-windows-0.16.0.zip",
      "shasum": "8aee7e8a8deb998ba96cb95d89aa5fcdf32933fdc67de51d280d9e4d7396f1a0"
    },
    "x86_64-linux": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz",
      "shasum": "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
    },
    "x86_64-macos": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz",
      "shasum": "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7"
    },
    "x86_64-windows": {
      "tarball": "https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip",
      "shasum": "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e"
    }
  },
  "0.15.2": {
    "aarch64-linux": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz",
      "shasum": "958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f"
    },
    "aarch64-macos": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz",
      "shasum": "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
    },
    "aarch64-windows": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-aarch64-windows-0.15.2.zip",
      "shasum": "b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370"
    },
    "x86-linux": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-x86-linux-0.15.2.tar.xz",
      "shasum": "4c6e23f39daa305e274197bfdff0d56ffd1750fc1de226ae10505c0eff52d7a5"
    },
    "x86-windows": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-x86-windows-0.15.2.zip",
      "shasum": "7a6dfc00f4cc09ec46d3e10eb06f42538e92b6285e34debea7462edaf371da98"
    },
    "x86_64-linux": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz",
      "shasum": "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239"
    },
    "x86_64-macos": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz",
      "shasum": "375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f"
    },
    "x86_64-windows": {
      "tarball": "https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip",
      "shasum": "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c"
    }
  }
}
""")

# vim: ft=bzl
