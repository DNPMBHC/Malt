#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Maintainer: @DNPMBHC
"""Build isolated x64 Guest probes. Every artifact stays beside this script."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

root = Path(__file__).resolve().parent
compiler = shutil.which("x86_64-w64-mingw32-g++")
if not compiler:
    raise SystemExit("x64 Windows compiler unavailable")
common = [compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror", "-municode", "-static", "-static-libgcc", "-static-libstdc++"]
host_compiler = shutil.which("clang++") or shutil.which("c++")
if not host_compiler:
    raise SystemExit("Host C++ regression-test compiler unavailable")
host_test = root / "exit-resolution-test"
result = subprocess.run([host_compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
    str(root / "exit-resolution-test.cpp"), "-o", str(host_test)], capture_output=True, text=True,
    env={**__import__("os").environ, "TMPDIR": str(root)})
if result.returncode:
    print((result.stdout + result.stderr).replace(str(root), "<artifact-directory>"))
    raise SystemExit(result.returncode)
host_result = subprocess.run([str(host_test)], capture_output=True, text=True)
if host_result.returncode:
    raise SystemExit("Native exit-resolution regression failed")
host_checks = json.loads(host_result.stdout)
(root / "exit-resolution-tests.json").write_text(json.dumps(host_checks, indent=2) + "\n")
targets = {
    "desktop-helper": ["-lwtsapi32", "-luserenv", "-ladvapi32", "-lshell32", "-lole32", "-luuid"],
    "desktop-probe": ["-ld3d11", "-ldxgi", "-ldwmapi", "-lole32", "-luuid"],
}
for name, libraries in targets.items():
    command = common + [str(root / (name + ".cpp")), "-o", str(root / (name + ".exe"))] + libraries
    result = subprocess.run(command, capture_output=True, text=True, env={**__import__("os").environ, "TMPDIR": str(root)})
    if result.returncode:
        log = result.stdout + result.stderr
        log = log.replace(str(root), "<artifact-directory>")
        print(log)
        raise SystemExit(result.returncode)
resource_compiler = shutil.which("x86_64-w64-mingw32-windres")
if not resource_compiler:
    raise SystemExit("x64 Windows resource compiler unavailable")
resource = root / "elevation-resource.o"
result = subprocess.run([resource_compiler, "-i", "elevation.rc", "-o", str(resource)],
    cwd=root, capture_output=True, text=True, env={**__import__("os").environ, "TMPDIR": str(root)})
if result.returncode:
    print((result.stdout + result.stderr).replace(str(root), "<artifact-directory>"))
    raise SystemExit(result.returncode)
result = subprocess.run(common + [str(root / "desktop-probe.cpp"), str(resource), "-o",
    str(root / "desktop-elevation-probe.exe")] + targets["desktop-probe"],
    capture_output=True, text=True, env={**__import__("os").environ, "TMPDIR": str(root)})
if result.returncode:
    print((result.stdout + result.stderr).replace(str(root), "<artifact-directory>"))
    raise SystemExit(result.returncode)
hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in [
    "desktop-helper.cpp", "desktop-helper.exe", "desktop-probe.cpp", "desktop-probe.exe", "build.py",
    "desktop-elevation-probe.exe", "elevation.manifest", "elevation.rc",
    "verify-cancel-contract.ps1", "cancel-contract-plan.md", "force-cancel-plan.md", "protocol.md", "review.md",
    "exit-resolution.hpp", "exit-resolution-test.cpp", "exit-resolution-test", "exit-resolution-tests.json",
]}
(root / "build.json").write_text(json.dumps({
    "schemaVersion": 1,
    "maintainer": "@DNPMBHC",
    "guestArchitecture": "arm64",
    "artifactArchitecture": "x86_64",
    "executionRequiresGuestEmulation": True,
    "compiler": "x86_64-w64-mingw32-g++",
    "result": "built",
    "nativeExitResolutionTests": host_checks,
    "sha256": hashes,
}, indent=2) + "\n")
print("Built desktop helper and probes (x86_64); 7 native exit-resolution regressions passed; SHA-256 recorded.")
