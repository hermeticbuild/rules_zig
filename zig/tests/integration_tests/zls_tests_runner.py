"""Real consumer toolchain, Bazel refresh and LSP assertions in a copied workspace."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time


class Session:
    def __init__(self, launcher, workspace, env, build_on_save=False):
        self.workspace = workspace
        self.process = subprocess.Popen([str(launcher)], cwd=workspace, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.messages = queue.Queue()
        self.logs = []
        self.diagnostics = {}
        self.documents = {}
        self.next_id = 0
        threading.Thread(target=self.read, daemon=True).start()
        threading.Thread(target=lambda: self.logs.append(self.process.stderr.read().decode()), daemon=True).start()
        self.request("initialize", {"processId": None, "rootUri": workspace.as_uri(),
                     "capabilities": {"textDocument": {"publishDiagnostics": {}}},
                     "initializationOptions": {"enable_build_on_save": build_on_save},
                     "workspaceFolders": [{"name": "fixture", "uri": workspace.as_uri()}]})
        self.send("initialized", {})

    def read(self):
        try:
            while True:
                headers = {}
                while (line := self.process.stdout.readline()) != b"\r\n":
                    if not line:
                        raise EOFError("ZLS exited")
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                self.messages.put(json.loads(self.process.stdout.read(int(headers["content-length"]))))
        except Exception as error:
            self.messages.put(error)

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        data = json.dumps(message).encode()
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send(method, params, self.next_id)
        deadline = time.monotonic() + 120
        while True:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if "method" in message:
                self.logs.append(json.dumps(message))
                if message["method"] == "textDocument/publishDiagnostics" and message["params"].get("diagnostics"):
                    print(json.dumps(message), flush=True)
                if message["method"] == "textDocument/publishDiagnostics":
                    self.diagnostics[message["params"]["uri"]] = message["params"]["diagnostics"]
            if message.get("id") == self.next_id:
                assert "error" not in message, message
                return message.get("result")

    def lookup(self, name, token):
        path = self.workspace / name
        if name not in self.documents:
            self.documents[name] = path.read_text()
            self.send("textDocument/didOpen", {"textDocument": {"uri": path.as_uri(), "languageId": "zig",
                                                             "version": 1, "text": self.documents[name]}})
        text = self.documents[name]
        index = text.index(token) + len(token) - 1
        return self.request("textDocument/definition", {"textDocument": {"uri": path.as_uri()},
                            "position": {"line": text[:index].count("\n"), "character": len(text[:index].rsplit("\n", 1)[-1])}})

    def definition(self, token, expected, name="root.zig"):
        deadline = time.monotonic() + 150
        while True:
            result = self.lookup(name, token)
            if result and result.get("uri") == expected.as_uri():
                assert result["range"]["start"]["line"] == 0, result
                return
            invalid = [line for line in self.logs if "Invalid Bazel metadata" in line]
            assert not invalid, invalid
            assert time.monotonic() < deadline, (token, expected, result, self.logs)
            time.sleep(0.1)

    def reload(self):
        path = self.workspace / "build.zig"
        if "build.zig" not in self.documents:
            text = path.read_text()
            self.documents["build.zig"] = text
            self.send("textDocument/didOpen", {"textDocument": {"uri": path.as_uri(), "languageId": "zig", "version": 1, "text": text}})
        self.send("textDocument/didSave", {"textDocument": {"uri": path.as_uri()}})

    def close(self):
        self.request("shutdown", None)
        self.send("exit", None)
        assert self.process.wait(timeout=15) == 0, self.logs

    def cleanup(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=15)


def test_workspace(workspace, env):
    def bazel(*args):
        subprocess.run(["bazel", *args], cwd=workspace, env=env, check=True, timeout=600)

    settings = workspace / ".bazelrc.user"
    sessions = []
    try:
        bazel("build", "--config=remote-cache", "//:completion")
        output = (workspace / "bazel-bin").resolve()
        launcher = output / "completion"
        version = subprocess.check_output([launcher, "--version"], cwd=workspace, env=env, text=True).strip()
        assert version == "0.17.0+hermetic.1", version

        session = Session(launcher, workspace, env)
        sessions.append(session)
        session.definition("dep.leaf.answer", workspace / "leaf_a.zig")
        session.definition('@import("dep").leaf.answer', workspace / "leaf_a.zig", name="second.zig")
        session.definition('@import("linked").answer', workspace / "real.zig")
        session.definition('@import("external").answer', workspace / "external_a/main.zig")
        session.definition('@import("generated").answer', output / "generated_a.zig")
        assert session.lookup("root.zig", '@import("undeclared").answer') is None

        settings.write_text("build --config=reload\n")
        session.reload()
        session.definition("dep.leaf.answer", workspace / "leaf_b.zig")
        session.definition('@import("generated").answer', output / "generated_b.zig")
        session.definition('@import("external").answer', workspace / "external_b/main.zig")
        assert (output / "generated_b.zig").is_file()

        # A failed refresh keeps the last usable graph until Bazel works again.
        marker_uri = (workspace / "build.zig").as_uri()
        session.diagnostics.pop(marker_uri, None)
        settings.write_text("build --config=broken\n")
        session.reload()
        deadline = time.monotonic() + 60
        while not session.diagnostics.get(marker_uri):
            session.lookup("root.zig", "dep.leaf.answer")
            assert time.monotonic() < deadline, session.logs
            time.sleep(0.1)
        assert any("Bazel metadata query failed" in item["message"] for item in session.diagnostics[marker_uri]), session.diagnostics
        session.definition("dep.leaf.answer", workspace / "leaf_b.zig")

        settings.write_text("")
        session.reload()
        session.definition("dep.leaf.answer", workspace / "leaf_a.zig")
        deadline = time.monotonic() + 15
        while session.diagnostics.get(marker_uri):
            session.lookup("root.zig", "dep.leaf.answer")
            assert time.monotonic() < deadline, session.diagnostics
        session.close()

        build_on_save = Session(launcher, workspace, env, build_on_save=True)
        sessions.append(build_on_save)
        build_on_save.definition("dep.leaf.answer", workspace / "leaf_a.zig")
        deadline = time.monotonic() + 30
        while not any("build applications with Bazel" in line for line in build_on_save.logs):
            build_on_save.lookup("root.zig", "dep.leaf.answer")
            assert time.monotonic() < deadline, build_on_save.logs
            time.sleep(0.1)
        build_on_save.close()
        assert not (output / "application").exists()
    finally:
        for session in sessions:
            session.cleanup()
        bazel("shutdown")


def main():
    source_workspace = Path(os.environ["BIT_WORKSPACE_DIR"])
    source_root = source_workspace.parents[3]
    with tempfile.TemporaryDirectory(prefix="zls-integration-", dir=os.environ.get("TEST_TMPDIR")) as temporary:
        temp = Path(temporary).resolve()
        repo = temp / "repo"
        shutil.copytree(source_root, repo, ignore=shutil.ignore_patterns("bazel-*", "__pycache__"))
        workspace = repo / source_workspace.relative_to(source_root)
        # Copytree dereferences runfiles. Restore the fixture's source symlink.
        linked = workspace / "linked.zig"
        linked.unlink()
        linked.symlink_to("real.zig")

        env = dict(os.environ, PATH=f"{workspace / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}",
                   BUILD_WORKSPACE_DIRECTORY=str(workspace), TMPDIR=str(temp))
        # The pinned Bazel wrapper needs the outer runfiles. The launcher uses its own.
        env["ZLS_TEST_RUNFILES_DIR"] = env.pop("RUNFILES_DIR", "")
        env["ZLS_TEST_RUNFILES_MANIFEST_FILE"] = env.pop("RUNFILES_MANIFEST_FILE", "")
        env.pop("JAVA_RUNFILES", None)
        test_workspace(workspace, env)
        assert not list(temp.glob("rules-zig-zls-*"))


if __name__ == "__main__":
    main()
