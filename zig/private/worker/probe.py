#!/usr/bin/env python3
"""Exercise the incremental worker with real Zig and Bazel; no extra packages.

Run from a rules_zig checkout: python3 zig/private/worker/probe.py
The generated Bazel package is temporary; tracked sources are never edited.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import select
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args}\n{result.stdout}\n{result.stderr}")
    return result


def digest(path):
    if path.is_dir():
        checksum = hashlib.sha256()
        for entry in sorted(path.rglob("*")):
            if entry.is_file():
                checksum.update(str(entry.relative_to(path)).encode() + b"\0" + entry.read_bytes())
        return checksum.hexdigest()
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expect_program(path, value):
    actual = run([str(path)]).stdout
    assert actual == f"{value}\n", (str(path), actual, value)


def protocol_checks(worker, zig, lib):
    with tempfile.TemporaryDirectory(prefix="zig-worker-protocol-") as directory:
        root = Path(directory)
        cwd = root / "execroot" / "main"
        cwd.mkdir(parents=True)
        (cwd / "main.zig").write_text(
            'const std = @import("std");\n'
            'const leaf = @import("leaf.zig");\n'
            'pub fn main(init: std.process.Init) void {\n'
            '  var buf: [32]u8 = undefined;\n'
            '  const text = std.fmt.bufPrint(&buf, "{d}\\n", .{leaf.value}) catch unreachable;\n'
            '  std.Io.File.writeStreamingAll(.stdout(), init.io, text) catch unreachable;\n'
            '}\n'
        )
        leaf = cwd / "leaf.zig"
        leaf.write_text("pub const value: u32 = 41;\n")
        log = open(root / "worker.log", "w+")
        state_root = None
        process = subprocess.Popen(
            [str(worker), f"--zig={zig}", f"--lib={lib}", "--persistent_worker"],
            cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
        )

        def request(files=("main.zig", "leaf.zig"), extra=(), compiler_args=None):
            arguments = compiler_args if compiler_args is not None else ["-O", "Debug", *extra, "-Mroot=main.zig"]
            metadata = {"command": "build-exe", "name": "root", "output_kind": "executable", "outputs": ["bin"]}
            payload = {
                "arguments": [json.dumps(metadata), "out/program", *arguments, "--", *[f"input={name}" for name in files]],
                "inputs": [{"path": name, "digest": digest(cwd / name)}
                    for name in files],
                "requestId": 0,
            }
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            assert select.select([process.stdout], [], [], 60)[0], "worker response timed out"
            response = process.stdout.readline()
            assert response, (process.poll(), (root / "worker.log").read_text())
            return json.loads(response)

        def succeeds(response):
            assert response["exitCode"] == 0, (response, (root / "worker.log").read_text())

        try:
            succeeds(request())
            expect_program(cwd / "out/program", 41)
            snapshot = root / "published"
            shutil.copy2(cwd / "out/program", snapshot)
            before = digest(snapshot)
            metadata = leaf.stat()
            leaf.write_text("pub const value: u32 = 42;\n")
            os.utime(leaf, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            succeeds(request())
            expect_program(cwd / "out/program", 42)
            assert digest(snapshot) == before
            expect_program(snapshot, 41)

            leaf.write_text('pub const value: u32 = "bad";\n')
            failed = request()
            assert failed["exitCode"] == 1 and "expected type" in failed["output"], failed
            leaf.write_text("pub const value: u32 = 43;\n")
            succeeds(request())
            expect_program(cwd / "out/program", 43)

            # Leaving a real file outside the declared set must not make it visible.
            failed = request(files=("main.zig",))
            assert failed["exitCode"] == 1 and "FileNotFound" in failed["output"], failed
            succeeds(request())
            expect_program(cwd / "out/program", 43)

            succeeds(request(extra=("-O", "ReleaseSafe")))
            expect_program(cwd / "out/program", 43)
            children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
            assert len(children) == 1, children
            os.kill(int(children[0]), signal.SIGKILL)
            succeeds(request(extra=("-O", "ReleaseSafe")))
            expect_program(cwd / "out/program", 43)
            telemetry = (root / "worker.log").read_text()
            assert "reused=true" in telemetry and telemetry.count("reused=false") >= 4, telemetry
            assert "transport failed" in telemetry, telemetry
            (cwd / "main.zig").write_text(
                'const std = @import("std");\n'
                'pub fn main(init: std.process.Init) void {\n'
                '  std.Io.File.writeStreamingAll(.stdout(), init.io, @embedFile("message.txt")) catch unreachable;\n'
                '}\n'
            )
            data = cwd / "message.txt"
            data.write_text("44\n")
            succeeds(request(files=("main.zig", "message.txt")))
            expect_program(cwd / "out/program", 44)
            metadata = data.stat()
            data.write_text("45\n")
            os.utime(data, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            succeeds(request(files=("main.zig", "message.txt")))
            expect_program(cwd / "out/program", 45)

            # Exercise a directory input and removal of one of its old members.
            (cwd / "assets").mkdir()
            (cwd / "assets/message.txt").write_text("46\n")
            (cwd / "main.zig").write_text((cwd / "main.zig").read_text().replace('"message.txt"', '"assets/message.txt"'))
            succeeds(request(files=("main.zig", "assets")))
            expect_program(cwd / "out/program", 46)
            (cwd / "assets/message.txt").unlink()
            failed = request(files=("main.zig", "assets"))
            assert failed["exitCode"] == 1 and "FileNotFound" in failed["output"], failed
            (cwd / "assets/message.txt").write_text("47\n")
            succeeds(request(files=("main.zig", "assets")))
            expect_program(cwd / "out/program", 47)

            # A generated input may change between a file and a directory.
            (cwd / "assets").rename(root / "old-assets")
            (cwd / "assets").write_text("49\n")
            (cwd / "main.zig").write_text((cwd / "main.zig").read_text().replace('"assets/message.txt"', '"assets"'))
            succeeds(request(files=("main.zig", "assets")))
            expect_program(cwd / "out/program", 49)
            (cwd / "assets").unlink()
            (cwd / "assets").mkdir()
            (cwd / "assets/message.txt").write_text("50\n")
            (cwd / "main.zig").write_text((cwd / "main.zig").read_text().replace('"assets"', '"assets/message.txt"'))
            succeeds(request(files=("main.zig", "assets")))
            expect_program(cwd / "out/program", 50)
            succeeds(request(files=("main.zig", "assets"), extra=("--dynamic-linker", "")))
            expect_program(cwd / "out/program", 50)

            # An alias into the SDK is still a declared source, not a tool path.
            (cwd / "message.txt").unlink()
            (cwd / "message.txt").symlink_to(lib / "std/std.zig")
            (cwd / "main.zig").write_text((cwd / "main.zig").read_text().replace('"assets/message.txt"', '"message.txt"'))
            succeeds(request(files=("main.zig", "message.txt")))
            assert run([str(cwd / "out/program")]).stdout == (lib / "std/std.zig").read_text()

            # Preserve argument tokens, including apostrophes and spaces, and
            # mirror Bazel's single-level sibling repository layout.
            quoted_main = "main's space.zig"
            (cwd / quoted_main).write_text(
                'const std = @import("std");\nconst dep = @import("dep");\n'
                'pub fn main(init: std.process.Init) !void {\n'
                '  try std.Io.File.stdout().writeStreamingAll(init.io, dep.message);\n}\n'
            )
            dependency = cwd.parent / "dep"
            dependency.mkdir()
            (dependency / "value.zig").write_text('pub const message = "48\\n";\n')
            flags = ["-O", "Debug", "--dep", "dep", f"-Mroot={quoted_main}", "-Mdep=../dep/value.zig"]
            succeeds(request(files=(quoted_main, "../dep/value.zig"), compiler_args=flags))
            expect_program(cwd / "out/program", 48)
            # Response encoding must preserve literal quotes and backslashes too.
            response_main = 'main"back\\slash.zig'
            (cwd / response_main).write_text((cwd / quoted_main).read_text())
            flags = ["-O", "Debug", "--dep", "dep", f"-Mroot={response_main}", "-Mdep=../dep/value.zig"]
            succeeds(request(files=(response_main, "../dep/value.zig"), compiler_args=flags))
            expect_program(cwd / "out/program", 48)
            (cwd / "oneshot.params").write_text("\n".join([
                json.dumps({"command": "build-exe", "name": "root", "output_kind": "executable", "outputs": ["bin"]}),
                "out/program", *flags, "--", f"input={response_main}", "input=../dep/value.zig",
            ]) + "\n")
            run([str(worker), f"--zig={zig}", f"--lib={lib}", "@oneshot.params"], cwd=cwd)
            expect_program(cwd / "out/program", 48)
            child = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()[0]
            state_root = Path(f"/proc/{child}/cwd").resolve().parents[2]
            assert state_root.name.startswith("rules-zig-worker-") and state_root.is_dir(), state_root

            print("PASS protocol: metadata-preserving edit, independent output, error recovery, "
                  "removed input, configuration change, compiler crash/restart, embedFile edit, "
                  "directory removal/topology changes, empty and quoted arguments, SDK alias, "
                  "sibling repository, one-shot contract", flush=True)
        finally:
            process.stdin.close()
            process.wait(timeout=30)
            log.close()
            if state_root is not None:
                assert not state_root.exists(), f"worker EOF left private state at {state_root}"


def bazel_checks(bazel, iterations, functions, backend):
    with tempfile.TemporaryDirectory(prefix="probe-", dir=HERE) as directory:
        package = Path(directory)
        label = "//" + str(package.relative_to(REPO))
        zigopts = json.dumps(["-j4", *( ["-fllvm", "-flld"] if backend == "llvm" else ["-fno-llvm", "-fno-lld"])])
        (package / "BUILD.bazel").write_text(
            'load("//zig:defs.bzl", "zig_binary", "zig_library")\n'
            'zig_library(name="module", main="module.zig", srcs=["leaf.zig"])\n'
            'zig_binary(name="ordinary", main="main.zig", deps=[":module"], '
            f'zigopts={zigopts})\n'
            'zig_binary(name="incremental", main="main.zig", deps=[":module"], '
            f'zigopts={zigopts})\n'
        )
        (package / "module.zig").write_text('pub const value = @import("leaf.zig").value;\n')
        (package / "main.zig").write_text(
            'const std = @import("std");\n'
            'const module = @import("module");\n'
            'export fn marker() u32 { return module.value; }\n'
            'pub fn main(init: std.process.Init) void {\n'
            '  var buf: [32]u8 = undefined;\n'
            '  const text = std.fmt.bufPrint(&buf, "{d}\\n", .{marker()}) catch unreachable;\n'
            '  std.Io.File.writeStreamingAll(.stdout(), init.io, text) catch unreachable;\n'
            '}\n' + ''.join(
                f'export fn func_{i}(x: u32) u32 {{ return x +% {i}; }}\n'
                for i in range(functions))
        )
        leaf = package / "leaf.zig"
        leaf.write_text("pub const value: u32 = 40;\n")
        common = [bazel, "build", "--config=remote-cache", "--worker_sandboxing",
                  "--worker_max_instances=ZigIncrementalCompile=1",
                  "--strategy=ZigIncrementalCompile=worker", "--worker_verbose"]
        results = {}
        bin_dir = Path(run([bazel, "info", "bazel-bin"], cwd=REPO).stdout.strip()) / package.relative_to(REPO)
        output_base = Path(run([bazel, "info", "output_base"], cwd=REPO).stdout.strip())
        for target in ("ordinary", "incremental"):
            common = [arg for arg in common if not arg.startswith("--//zig/settings:incremental=")]
            common.append("--//zig/settings:incremental=" + ("true" if target == "incremental" else "false"))
            run([*common, label + ":" + target], cwd=REPO)
            durations = []
            bazel_durations = []
            for value in range(41, 41 + iterations):
                leaf.write_text(f"pub const value: u32 = {value};\n")
                started = time.perf_counter()
                build = run([*common, label + ":" + target], cwd=REPO)
                durations.append(round(1000 * (time.perf_counter() - started), 2))
                bazel_durations.append(round(1000 * float(re.search(r"Elapsed time: ([0-9.]+)s", build.stderr)[1]), 2))
                expect_program(bin_dir / target, value)
            results[target] = {"median_ms": statistics.median(durations), "samples_ms": durations,
                               "bazel_median_ms": statistics.median(bazel_durations),
                               "bazel_samples_ms": bazel_durations}

        leaf.write_text('pub const value: u32 = "bad";\n')
        failed = subprocess.run([*common, label + ":incremental"], cwd=REPO, text=True, capture_output=True)
        assert failed.returncode and "expected type" in failed.stderr, failed.stderr
        leaf.write_text("pub const value: u32 = 71;\n")
        run([*common, label + ":incremental"], cwd=REPO)
        expect_program(bin_dir / "incremental", 71)
        logs = list((output_base / "bazel-workers").glob("*ZigIncrementalCompile.log"))
        assert any("reused=true" in path.read_text() for path in logs), logs
        # Keep the pool options unchanged until measurements finish. Bazel
        # stops workers when these options change, including during queries.
        run([*common, label + ":incremental"], cwd=REPO)
        before = {str(path): path.read_text() for path in logs}
        run([*common, label + ":incremental"], cwd=REPO)
        assert before == {str(path): path.read_text() for path in logs}, "no-op build invoked compiler"
        memory = []
        for status in Path("/proc").glob("[0-9]*/status"):
            try:
                command = (status.parent / "cmdline").read_bytes()
                if str(output_base).encode() in command and b"--listen=-" in command:
                    memory.append({line.split(":")[0]: line.split(":")[1].strip()
                                   for line in status.read_text().splitlines()
                                   if line.startswith(("VmRSS:", "VmHWM:"))})
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                pass
        leaf.write_text("pub const value: u32 = 72;\n")
        run([*common, "--strategy=ZigIncrementalCompile=sandboxed", label + ":incremental"], cwd=REPO)
        expect_program(bin_dir / "incremental", 72)
        graph = run([bazel, "aquery", 'mnemonic("ZigIncrementalCompile", ' + label + ':incremental)',
                     "--//zig/settings:incremental", "--output=text"], cwd=REPO).stdout
        assert "supports-workers" in graph and "requires-worker-protocol" in graph, graph
        print("PASS Bazel: sandboxed worker reuse, transitive module edit, "
              "failure/recovery, no-op build, one-shot fallback, generated action", flush=True)
        report = {"backend": backend, "functions": functions, "iterations": iterations,
                  "builds": results, "compiler_memory": memory}
        print(json.dumps(report, indent=2), flush=True)
        return report


def multi_target_checks(bazel, iterations, functions, sessions):
    """Measure alternating outputs, including retained compiler memory."""
    with tempfile.TemporaryDirectory(prefix="probe-", dir=HERE) as directory:
        package = Path(directory)
        label = "//" + str(package.relative_to(REPO))
        (package / "BUILD.bazel").write_text(
            'load("//zig:defs.bzl", "zig_binary")\n' + ''.join(
                f'zig_binary(name="{name}", main="main.zig", srcs=["leaf.zig"], '
                'zigopts=["-j4", "-fno-llvm", "-fno-lld"])\n' for name in ("a", "b")))
        (package / "main.zig").write_text(
            'pub fn main() u8 { return @import("leaf.zig").value; }\n' + ''.join(
                f'export fn func_{i}(x: u32) u32 {{ return x +% {i}; }}\n'
                for i in range(functions)))
        leaf = package / "leaf.zig"
        output_base = Path(run([bazel, "info", "output_base"], cwd=REPO).stdout.strip())
        bin_dir = Path(run([bazel, "info", "bazel-bin"], cwd=REPO).stdout.strip()) / package.relative_to(REPO)
        common = [bazel, "build", "--config=remote-cache", "--//zig/settings:incremental",
                  "--worker_sandboxing", "--worker_max_instances=ZigIncrementalCompile=1",
                  "--experimental_worker_strict_flagfiles", "--strategy=ZigIncrementalCompile=worker"]
        if sessions is not None:
            common.append(f"--worker_extra_flag=ZigIncrementalCompile=--max-sessions={sessions}")
        measurements = []
        for i in range(2 + iterations * 2):
            target = ("a", "b")[i % 2]
            leaf.write_text(f"pub const value: u8 = {i + 1};\n")
            previous_logs = {path: path.read_text() for path in (output_base / "bazel-workers").glob("*ZigIncrementalCompile.log")}
            result = run([*common, label + ":" + target], cwd=REPO)
            executed = subprocess.run([str(bin_dir / target)], check=False)
            assert executed.returncode == i + 1, executed.returncode
            records = []
            for path in (output_base / "bazel-workers").glob("*ZigIncrementalCompile.log"):
                content = path.read_text()
                previous = previous_logs.get(path, "")
                delta = content[len(previous):] if content.startswith(previous) else content
                records.extend(re.findall(r"zig-worker generation=.*", delta))
            assert len(records) == 1, records
            telemetry = records[0]
            memory_kib = 0
            compilers = 0
            for status in Path("/proc").glob("[0-9]*/status"):
                try:
                    command = (status.parent / "cmdline").read_bytes()
                    if str(output_base).encode() in command and b"--listen=-" in command:
                        parent = re.search(r"PPid:\s+(\d+)", status.read_text())[1]
                        startup = Path(f"/proc/{parent}/cmdline").read_bytes().split(b"\0")
                        limit_flags = [arg for arg in startup if arg.startswith(b"--max-sessions=")]
                        expected_flags = [] if sessions is None else [f"--max-sessions={sessions}".encode()]
                        if limit_flags != expected_flags:
                            continue
                        memory_kib += int(re.search(r"VmRSS:\s+(\d+)", status.read_text())[1])
                        compilers += 1
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    pass
            measurements.append({"target": target, "telemetry": telemetry,
                                 "bazel_ms": 1000 * float(re.search(r"Elapsed time: ([0-9.]+)s", result.stderr)[1]),
                                 "compiler_rss_kib": memory_kib, "compilers": compilers})
        report = {"sessions": sessions, "functions": functions, "samples": measurements,
                  "warm_median_ms": statistics.median(x["bazel_ms"] for x in measurements[2:])}
        print(json.dumps(report, indent=2), flush=True)
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default="bazel")
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--functions", type=int, default=2000)
    parser.add_argument("--backend", choices=("self-hosted", "llvm"), default="self-hosted")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--multi-target", action="store_true")
    parser.add_argument("--sessions", type=int)
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("Run this probe on x86_64 Linux; native macOS incremental linking is not supported.")
    if args.multi_target:
        report = multi_target_checks(args.bazel, args.iterations, args.functions, args.sessions)
        if args.report:
            args.report.write_text(json.dumps(report, indent=2) + "\n")
        return
    run([args.bazel, "build", "--config=remote-cache", "//zig/private/worker:worker"], cwd=REPO)
    output_base = Path(run([args.bazel, "info", "output_base"], cwd=REPO).stdout.strip())
    sdk = next((output_base / "external").glob("+zig+zig_0.17.0_*/zig"))
    worker = Path(run([args.bazel, "info", "bazel-bin"], cwd=REPO).stdout.strip()) / "zig/private/worker/worker"
    protocol_checks(worker.resolve(), sdk.resolve(), (sdk.parent / "lib").resolve())
    report = bazel_checks(args.bazel, args.iterations, args.functions, args.backend)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
