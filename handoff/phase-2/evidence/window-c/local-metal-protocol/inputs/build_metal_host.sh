#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "${SCRIPT_DIR}" <<'PYBUILD'
from pathlib import Path
import fcntl
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

lab = Path(sys.argv[1]).resolve()
source = lab / "metal_host.swift"
build = lab / "build"
build.mkdir(parents=True, exist_ok=True)
tmp = build / "tmp"
cache = build / "swift-module-cache"
for directory in (tmp, cache):
    directory.mkdir(parents=True, exist_ok=True)
tmp.chmod(0o700)

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def scrub(message):
    message = message.replace(str(lab.parent), "my-project")
    message = message.replace(getpass.getuser(), "user-placeholder")
    message = re.sub(r"(?<![\w:])/(?:[^\s\"'<>)]*)", "/placeholder", message)
    message = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "identity-placeholder", message)
    return message

lock = open(build / "metal-host-build.lock", "a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("build_metal_host: another build is already active", file=sys.stderr)
    raise SystemExit(1)

env = os.environ.copy()
env["TMPDIR"] = str(tmp.resolve()) + os.sep
env["CLANG_MODULE_CACHE_PATH"] = str(cache.resolve())
staging = Path(tempfile.mkdtemp(prefix="metal-host-build-", dir=build))
diag_path = build / "metal-host-toolchain-diagnostic.json"
try:
    previous = json.loads(diag_path.read_text()) if diag_path.exists() else {}
except (ValueError, OSError):
    previous = {}
diagnostics = dict(previous)
diagnostics.update({"build_strategy": "swift-frontend-object-and-clang-link",
                    "scratch_directory": "graphics-lab/build/tmp",
                    "module_cache_directory": "graphics-lab/build/swift-module-cache"})
logs = []

def save_diagnostics():
    temporary = staging / "diagnostic.json"
    temporary.write_text(json.dumps(diagnostics, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, diag_path)
    (build / "metal-host-build.log").write_text("\n".join(logs) + "\n")

def run(label, arguments):
    result = subprocess.run(arguments, cwd=staging, env=env, capture_output=True, text=True)
    output = scrub(result.stdout + result.stderr)
    diagnostics[label + "_exit"] = result.returncode
    logs.append(label + "_exit=" + str(result.returncode))
    if output.strip():
        logs.append(output)
    if result.returncode != 0:
        print("build_metal_host: " + label + " failed", file=sys.stderr)
        if output.strip():
            print(output, file=sys.stderr)
        raise RuntimeError(label + " failed")
    return result.stdout.strip()

try:
    before = sha256(source)
    snapshot = staging / "metal_host.swift"
    snapshot.write_bytes(source.read_bytes())
    if sha256(snapshot) != before:
        raise RuntimeError("source changed before compilation")
    diagnostics["source_sha256"] = before
    frontend = Path(run("find_swift_frontend", ["xcrun", "--find", "swift-frontend"]))
    sdk = Path(run("find_sdk", ["xcrun", "--show-sdk-path"]))
    obj = staging / "metal_host.o"
    candidate = staging / "metal_host"
    run("swift_frontend_object", [str(frontend), "-c", "-O", "-module-name", "metal_host",
        "-sdk", str(sdk), "-module-cache-path", str(cache), "-primary-file", str(snapshot), "-o", str(obj)])
    runtime = frontend.parent.parent / "lib" / "swift" / "macosx"
    system_runtime = Path(os.sep).joinpath("usr", "lib", "swift")
    run("clang_link", ["xcrun", "clang", str(obj), "-o", str(candidate), "-isysroot", str(sdk),
        "-L" + str(runtime), "-L" + str(sdk / "usr" / "lib" / "swift"),
        "-Wl,-rpath," + str(system_runtime), "-lswiftCore",
        "-framework", "AppKit", "-framework", "Foundation", "-framework", "Metal",
        "-framework", "MetalFX", "-framework", "QuartzCore", "-framework", "CryptoKit"])
    if sha256(source) != before:
        raise RuntimeError("source changed during compilation; binary was retained")
    candidate.chmod(0o755)
    diagnostics["binary_sha256"] = sha256(candidate)
    diagnostics["formal_binary"] = "graphics-lab/build/metal_host"
    diagnostics["formal_build_status"] = "built"
    diagnostics.pop("formal_build_error", None)
    save_diagnostics()
    os.replace(candidate, build / "metal_host")
    print("status=built")
    print("built=build/metal_host")
    print("source_sha256=" + before)
    print("binary_sha256=" + diagnostics["binary_sha256"])
except Exception as error:
    diagnostics["formal_build_status"] = "failed"
    diagnostics["formal_build_error"] = scrub(str(error))
    try:
        save_diagnostics()
    except OSError:
        print("build_metal_host: could not save diagnostic output", file=sys.stderr)
    print("build_metal_host: " + scrub(str(error)), file=sys.stderr)
    raise SystemExit(1)
finally:
    shutil.rmtree(staging, ignore_errors=True)
PYBUILD
