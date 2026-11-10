"""Exercise the packaged metadata service through its compiler entry point."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from zls_lsp_client import Session


def eventually(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("condition did not become true before deadline")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Protocol:
    def __init__(self, argv, cwd, env):
        self.process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.messages = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        while header := self.process.stdout.read(8):
            if len(header) != 8:
                self.messages.put(AssertionError("partial protocol header"))
                return
            tag, length = struct.unpack("<II", header)
            self.messages.put((tag, self.process.stdout.read(length)))
        self.messages.put(EOFError())

    def receive(self, expected):
        result = self.messages.get(timeout=15)
        if isinstance(result, Exception):
            raise result
        assert result[0] == expected, (hex(expected), hex(result[0]), result[1])
        return result[1]

    def send(self, tag, body=b""):
        self.process.stdin.write(struct.pack("<II", tag, len(body)) + body)
        self.process.stdin.flush()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()
        self.process.stdin.close()


class MetadataProtocolTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zls-contract-", dir=os.environ.get("TEST_TMPDIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "root.zig").write_text('@compileError("applications must not compile");\n')
        self.graph = {"modules": {str(self.root / "root.zig"): {"import_table": {}}},
                      "compilations": [{"root_module": str(self.root / "root.zig")}]}
        (self.root / "graph.json").write_text(json.dumps(self.graph))
        self.env = dict(os.environ, RULES_ZIG_ZLS_SDK="/unused/zig", TMPDIR=str(self.root), BUILD_WORKSPACE_DIRECTORY=str(self.root),
                        PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""))
        self.command('print(open("graph.json").read())')

    def command(self, source):
        path = self.root / "bazel"
        path.write_text("#!" + sys.executable + "\nimport os,signal,sys,time\n" + source + "\n")
        path.chmod(0o755)

    def start(self, extra=()):
        protocol = Protocol([LAUNCHER, "build", "--listen=-", *extra], self.root, self.env)
        self.addCleanup(protocol.close)
        protocol.receive(0x80000000)
        return protocol

    def assert_clean(self):
        self.assertEqual([], list(self.root.glob("rules-zig-zls-*")))

    def test_empty_cycle_succeeds_and_requested_build_cannot_compile(self):
        protocol = self.start()
        config = Path(protocol.receive(0x80000001).decode())
        self.assertTrue(config.is_file())
        protocol.send(0x80000000, struct.pack("<II", 0, 0))
        protocol.receive(0x80000003)
        protocol.receive(0x80000004)
        protocol.send(0x80000000, struct.pack("<III", 1, 0, 0))
        protocol.receive(0x80000003)
        protocol.receive(0x80000005)
        completed = protocol.receive(0x80000006)
        self.assertIn(b"cannot execute build steps", completed)
        self.assertNotEqual(0, struct.unpack("<IIIII", completed[:20])[1])
        protocol.receive(0x80000004)
        protocol.send(0)
        self.assertEqual(0, protocol.process.wait(timeout=5))
        self.assertFalse(config.exists())
        self.assert_clean()

    def test_build_arguments_are_rejected_before_query(self):
        self.command('open("query-ran", "w").write("unexpected")')
        protocol = self.start(("--build-file", "dangerous.zig"))
        self.assertIn(b"Unsupported ZLS build invocation", protocol.receive(0x80000002))
        self.assertEqual(0, protocol.process.wait(timeout=5))
        self.assertFalse((self.root / "query-ran").exists())
        self.assert_clean()

    def test_ordinary_sdk_command_preserves_output_and_failure_status(self):
        sdk = self.root / "sdk"
        sdk.write_text("#!" + sys.executable + '\nimport sys\nsys.stdout.write("SDK output\\n")\nsys.stderr.write("SDK failure\\n")\nsys.exit(37)\n')
        sdk.chmod(0o755)
        result = subprocess.run([LAUNCHER, "version"], cwd=self.root,
                                env=dict(self.env, RULES_ZIG_ZLS_SDK=str(sdk)), capture_output=True, timeout=5)
        self.assertEqual((37, b"SDK output\n", b"SDK failure\n"), (result.returncode, result.stdout, result.stderr))

    def test_real_zls_loads_named_imports_and_reloads_the_native_provider(self):
        (self.root / "build.zig").write_text('pub fn build(_: *@import("std").Build) void { @panic("must not execute"); }\n')
        (self.root / "root.zig").write_text('pub const value = @import("dep").answer;\n')
        for name in ["a", "b"]:
            (self.root / (name + ".zig")).write_text('pub const answer = 42;\n')
            self.graph["modules"][str(self.root / (name + ".zig"))] = {"import_table": {}}
        self.graph["modules"][str(self.root / "root.zig")]["import_table"] = {"dep": str(self.root / "a.zig")}
        (self.root / "graph.json").write_text(json.dumps(self.graph))
        env = dict(self.env)
        env.pop("RULES_ZIG_ZLS_SDK")
        session = Session(LAUNCHER, self.root, env)
        self.addCleanup(session.cleanup)
        session.definition('@import("dep").answer', self.root / "a.zig")
        self.graph["modules"][str(self.root / "root.zig")]["import_table"] = {"dep": str(self.root / "b.zig")}
        (self.root / "graph.json").write_text(json.dumps(self.graph))
        session.reload()
        session.definition('@import("dep").answer', self.root / "b.zig")
        session.close()
        self.assert_clean()

    def test_independent_process_survives_owned_query_cancellation(self):
        independent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            protocol, pid = self.held_query()
            protocol.process.stdin.close()
            protocol.process.wait(timeout=5)
            eventually(lambda: not alive(pid))
            self.assertIsNone(independent.poll())
        finally:
            independent.terminate()
            independent.wait(timeout=5)

    def test_metadata_failure_is_reported_as_structured_diagnostic(self):
        self.command('print("query exploded", file=sys.stderr); sys.exit(17)')
        protocol = self.start()
        self.assertIn(b"query exploded", protocol.receive(0x80000002))
        protocol.process.wait(timeout=5)
        self.assert_clean()

    def test_invalid_graph_is_reported_instead_of_publishing_configuration(self):
        (self.root / "graph.json").write_text('{"modules": {}, "compilations": [{"root_module":"missing"}]}')
        protocol = self.start()
        self.assertIn(b"MissingRootModule", protocol.receive(0x80000002))
        protocol.process.wait(timeout=5)
        self.assert_clean()

    def test_watch_request_is_explicitly_unsupported(self):
        protocol = self.start()
        protocol.receive(0x80000001)
        protocol.send(0x80000000, struct.pack("<II", 0, 1))
        self.assertIn(b"does not support build-on-save", protocol.receive(0x80000002))
        protocol.process.wait(timeout=5)
        self.assert_clean()

    def held_query(self):
        # Distinct boundary: the child closes both output pipes but keeps running.
        self.command('signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                     'os.close(1); os.close(2)\n'
                     'open("closed-streams", "w").write(str(os.getpid()))\n'
                     'while True: time.sleep(0.05)')
        protocol = self.start()
        eventually(lambda: (self.root / "closed-streams").exists())
        pid = int((self.root / "closed-streams").read_text())
        # Failure cleanup targets only this test's known child group.
        def cleanup():
            if alive(pid):
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.addCleanup(cleanup)
        return protocol, pid

    def test_caller_eof_cancels_child_after_its_streams_close(self):
        protocol, pid = self.held_query()
        protocol.process.stdin.close()
        protocol.process.wait(timeout=5)
        eventually(lambda: not alive(pid))
        self.assert_clean()

    def test_parent_signal_cancels_child_after_its_streams_close(self):
        protocol, pid = self.held_query()
        protocol.process.terminate()
        protocol.process.wait(timeout=5)
        eventually(lambda: not alive(pid))
        self.assert_clean()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--launcher", required=True)
    options, rest = parser.parse_known_args()
    LAUNCHER = str(Path(options.launcher).resolve())
    unittest.main(argv=[sys.argv[0], *rest])
