"""The editor's packaged ZLS and Zig must run on the local host."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest


LAUNCHER, RUNNER_SOURCE = sys.argv[1:]
del sys.argv[1:]


class RuntimeTest(unittest.TestCase):
    def test_packaged_tools_run_on_editor_host(self):
        version = subprocess.check_output(
            [LAUNCHER, "--version"], text=True, timeout=30
        ).strip()
        self.assertEqual(version, "0.16.0")

        # Check the SDK named by the launcher, rather than resolving a second
        # toolchain which could select a different execution platform.
        source = Path(RUNNER_SOURCE).read_text()
        match = re.search(r'const zig_exe_rpath = ("[^"]*");', source)
        self.assertIsNotNone(match, "launcher must name its runtime SDK")
        sdk = Path(os.environ["TEST_SRCDIR"]) / json.loads(match.group(1))
        version = subprocess.check_output(
            [str(sdk), "version"], text=True, timeout=30
        ).strip()
        self.assertEqual(version, "0.16.0")


if __name__ == "__main__":
    unittest.main()
