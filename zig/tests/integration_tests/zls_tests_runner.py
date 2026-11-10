"""Real consumer toolchain, Bazel refresh and LSP assertions in a copied workspace."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from zls_lsp_client import Session


def main():
    version = os.environ["ZLS_TEST_ZIG_VERSION"]
    source_workspace = Path(os.environ["BIT_WORKSPACE_DIR"])
    source_root = source_workspace.parents[3]
    with tempfile.TemporaryDirectory(prefix="zls-integration-", dir=os.environ.get("TEST_TMPDIR")) as temporary:
        temp = Path(temporary)
        repo = temp / "repo"
        shutil.copytree(source_root, repo, ignore=shutil.ignore_patterns("bazel-*", "__pycache__"))
        workspace = repo / "zig/tests/integration_tests/workspace"
        module = workspace / "MODULE.bazel"
        # A consumer must not need to register unrelated SDK versions merely
        # because ZLS supports both 0.17 patches.
        contents = module.read_text()
        begin = contents.index('zig.toolchain(zig_version = "0.17.0-dev.')
        end = contents.index('use_repo(zig, "zig_toolchains")', begin)
        contents = contents[:begin] + f'zig.toolchain(default = True, zig_version = "{version}")\n' + contents[end:]
        module.write_text(contents)
        module.write_text(module.read_text() + '''
bazel_dep(name = "bazel_skylib", version = "1.9.0")
zls = use_extension("@rules_zig//zig/zls:extensions.bzl", "zls")
use_repo(zls, "zls_toolchains")
register_toolchains("@zls_toolchains//:all")
bazel_dep(name = "zls_external", version = "0.0.0")
local_path_override(module_name = "zls_external", path = "zls_external_a")
''')
        zls_version = "0.16.0" if version == "0.16.0" else "0.17.0+hermetic.1"
        module.write_text(module.read_text() + f'zls.toolchain(zig_version = "{version}", zls_version = "{zls_version}")\n')
        original_module = module.read_text()
        for name in ["a", "b"]:
            external = workspace / ("zls_external_" + name)
            external.mkdir()
            (external / "MODULE.bazel").write_text('module(name="zls_external", version="0.0.0")\nbazel_dep(name="rules_zig", version="0.0.0")\n')
            (external / "BUILD.bazel").write_text('load("@rules_zig//zig:defs.bzl", "zig_library")\nzig_library(name="external", main="main.zig", visibility=["//visibility:public"])\n')
            (external / "main.zig").write_text('pub const answer = 5;\n')
        fixture = workspace / "zls_fixture"
        fixture.mkdir()
        (fixture / "build.zig").write_text('pub fn build(_: *@import("std").Build) void { @panic("Bazel owns builds"); }\n')
        (fixture / "root.zig").write_text('''comptime { @compileError("application compilation forbidden"); }
pub const dep = @import("dep");
pub const a = dep.leaf.answer;
pub const b = @import("generated").answer;
pub const c = @import("linked").answer;
pub const d = @import("undeclared").answer;
pub const e = @import("external").answer;
''')
        (fixture / "second.zig").write_text('pub const a = @import("dep").leaf.answer;\n')
        (fixture / "dep.zig").write_text('pub const leaf = @import("leaf");\n')
        (fixture / "leaf_a.zig").write_text('pub const answer = 1;\n')
        (fixture / "leaf_b.zig").write_text('pub const answer = 2;\n')
        (fixture / "real.zig").write_text('pub const answer = 3;\n')
        (fixture / "linked.zig").symlink_to("real.zig")
        other = fixture / "other"
        other.mkdir()
        (other / "main.zig").write_text('pub fn main() void {}\n')
        (other / "BUILD.bazel").write_text('load("@rules_zig//zig:defs.bzl", "zig_binary")\nzig_binary(name="application", main="main.zig", visibility=["//visibility:public"])\n')
        build = fixture / "BUILD.bazel"
        original = '''load("@rules_zig//zig:defs.bzl", "zig_binary", "zig_library")
load("@rules_zig//zig/zls:defs.bzl", "zls_completion")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
zig_library(name="leaf_a", import_name="leaf", main="leaf_a.zig")
zig_library(name="leaf_b", import_name="leaf", main="leaf_b.zig")
alias(name="selected", actual=":leaf_a")
zig_library(name="dep", main="dep.zig", deps=[":selected"])
write_file(name="source", out="generated_a.zig", content=["pub const answer = 7;"])
zig_library(name="generated", main=":source")
zig_library(name="linked", main="linked.zig")
zig_binary(name="application", main="root.zig", deps=[":dep", ":generated", ":linked", "@zls_external//:external"])
zig_library(name="second", main="second.zig", deps=[":dep"])
zls_completion(name="completion", deps=[":application", ":second", "//zls_fixture/other:application"])
'''
        build.write_text(original)
        binary = Path(os.environ["BIT_BAZEL_BINARY"]).resolve()
        shim_dir = temp / "bin"
        shim_dir.mkdir()
        shim = shim_dir / "bazel"
        log = temp / "bazel-commands.jsonl"
        bazel_runfiles = {key: os.environ[key] for key in ["RUNFILES_DIR", "RUNFILES_MANIFEST_FILE", "JAVA_RUNFILES"] if key in os.environ}
        shim_program = shim_dir / "bazel.py"
        shim_program.write_text("import os,sys,json\n"
                       + f"with open({str(log)!r},'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                       + f"env=dict(os.environ); env.update({bazel_runfiles!r})\n"
                       + f"os.execve({str(binary)!r},[{str(binary)!r},'--output_user_root={temp / 'bazel'}',*sys.argv[1:]],env)\n")
        shim.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                        + shlex.quote(str(shim_program)) + ' "$@"\n')
        shim.chmod(0o755)
        env = dict(os.environ, PATH=str(shim_dir) + os.pathsep + os.environ.get("PATH", ""),
                   BUILD_WORKSPACE_DIRECTORY=str(workspace), TMPDIR=str(temp))
        # Runfiles from this outer test must not redirect the built consumer binary.
        for key in ["RUNFILES_DIR", "RUNFILES_MANIFEST_FILE", "JAVA_RUNFILES"]:
            env.pop(key, None)
        def bazel(*args):
            return subprocess.check_output([str(shim), *args], cwd=workspace, env=env, timeout=600, text=True)
        flag = "--@zig_toolchains//:version=" + version
        sessions = []
        try:
            bazel("build", "--config=remote-cache", flag, "//zls_fixture:completion")
            launcher = workspace / "bazel-bin/zls_fixture/completion"
            actual = subprocess.check_output([str(launcher), "--version"], cwd=fixture, env=env, text=True).strip()
            assert actual == zls_version, actual
            print("Executed ZLS", actual, "with Zig", version, flush=True)
            session = Session(launcher, fixture, env)
            sessions.append(session)
            session.definition("dep.leaf.answer", fixture / "leaf_a.zig")
            session.definition('@import("dep").leaf.answer', fixture / "leaf_a.zig", name="second.zig")
            session.definition('@import("linked").answer', fixture / "real.zig")
            session.definition('@import("external").answer', workspace / "zls_external_a/main.zig")
            assert session.lookup("root.zig", '@import("undeclared").answer') is None
            graph = json.loads(bazel("run", "--config=remote-cache", flag, "//zls_fixture:completion.print_build_config"))
            assert len(graph["compilations"]) == 3, graph["compilations"]
            assert all(root["root_module"] in graph["modules"] for root in graph["compilations"])
            generated = Path(next(path for path in graph["modules"] if path.endswith("/generated_a.zig")))
            session.definition('@import("generated").answer', generated)
            before = sum("completion.print_build_config" in line for line in log.read_text().splitlines())
            build.write_text(original.replace('actual=":leaf_a"', 'actual=":leaf_b"').replace('out="generated_a.zig"', 'out="generated_b.zig"'))
            module.write_text(original_module.replace('path = "zls_external_a"', 'path = "zls_external_b"'))
            session.reload()
            session.definition("dep.leaf.answer", fixture / "leaf_b.zig")
            session.definition('@import("generated").answer', generated.with_name("generated_b.zig"))
            session.definition('@import("external").answer', workspace / "zls_external_b/main.zig")
            assert generated.with_name("generated_b.zig").is_file()
            after = sum("completion.print_build_config" in line for line in log.read_text().splitlines())
            assert after > before, (before, after)
            assert session.process.poll() is None
            # A failed refresh must not replace the usable graph; repair reloads it.
            marker_uri = (fixture / "build.zig").as_uri()
            session.diagnostics.pop(marker_uri, None)
            before_failure = len(session.logs)
            build.write_text("this is not valid Starlark\n")
            session.reload()
            deadline = time.monotonic() + 60
            def failed_refresh_observed():
                if version == "0.16.0":
                    return any("Failed to load build configuration" in line and marker_uri in line for line in session.logs[before_failure:])
                return bool(session.diagnostics.get(marker_uri))
            while not failed_refresh_observed():
                session.lookup("root.zig", "dep.leaf.answer")
                assert time.monotonic() < deadline, session.logs
                time.sleep(0.1)
            if version != "0.16.0":
                assert any("Bazel metadata query failed" in item["message"] for item in session.diagnostics[marker_uri]), session.diagnostics
            session.definition("dep.leaf.answer", fixture / "leaf_b.zig")
            build.write_text(original)
            session.reload()
            session.definition("dep.leaf.answer", fixture / "leaf_a.zig")
            deadline = time.monotonic() + 15
            while version != "0.16.0" and session.diagnostics.get(marker_uri):
                session.lookup("root.zig", "dep.leaf.answer")
                assert time.monotonic() < deadline, session.diagnostics
            session.close()
            if version != "0.16.0":
                unsafe = Session(launcher, fixture, env, build_on_save=True)
                sessions.append(unsafe)
                unsafe.definition("dep.leaf.answer", fixture / "leaf_a.zig")
                deadline = time.monotonic() + 30
                while not any("build applications with Bazel" in line for line in unsafe.logs):
                    unsafe.lookup("root.zig", "dep.leaf.answer")
                    assert time.monotonic() < deadline, unsafe.logs
                    time.sleep(0.1)
                unsafe.close()
            assert not (workspace / "bazel-bin/zls_fixture/application").exists()
            assert not list(temp.glob("rules-zig-zls-*"))
            print("LSP roots, imports, canonical paths, fresh Bazel/generated reload, failed refresh, repair and cleanup passed", flush=True)
        finally:
            for session in sessions:
                session.cleanup()
            bazel("shutdown")


if __name__ == "__main__":
    main()
