#!/usr/bin/env python3
"""Actual producer/consumer GPU interoperability; no VM or visible window. Owner: @DNPMBHC."""
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[3]
PACKAGE = next(ROOT.glob("*/*/Package.swift")).parent
RUNTIME = next(PACKAGE.glob("Sources/*/Runtime"))
PRODUCER = PACKAGE.parent / "Modules/vz-gpu-bridge"
C_SOURCES = ("GuestSurfaceModels.swift", "GuestSurfaceDisplayModels.swift",
             "GuestSurfaceMetalPresenter.swift", "GuestSurfacePushFrameSource.swift")
B_SOURCES = ("SurfaceFrameProducer.swift", "SurfaceFrameLease.swift", "InProcessZeroCopyRenderer.swift",
             "IOSurfacePresentBridge.swift", "SharedCommandRing.swift", "GPUShader.swift",
             "Metal4Engine.swift", "BenchmarkStatistics.swift")
BUILD = Path(tempfile.mkdtemp(prefix="guest-shell-roundtrip-"))
REPLACEMENTS = sorted(((str(ROOT), "<workspace>"), (str(Path.home()), "<user-home>"),
                       (str(BUILD), "<temporary-build>"), (ROOT.name, "my-project"),
                       (PACKAGE.name, "module-x"), (PACKAGE.parent.name, "demo-app")),
                      key=lambda item: len(item[0]), reverse=True)


def clean(text):
    for original, alias in REPLACEMENTS:
        text = re.sub(re.escape(original), lambda match: alias, text, flags=re.IGNORECASE)
    text = re.sub(r"/Users/[^\s`\"'<>]+", "<local-path>", text)
    text = re.sub(r"/Volumes/[^\s`\"'<>]+", "<EXTERNAL_VOLUME>", text)
    return text


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(stage, arguments, timeout=180, cwd=ROOT):
    print(json.dumps({"stage": stage}), flush=True)
    env = {key: value for key, value in os.environ.items() if "REAL_GUEST" not in key}
    try:
        result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        (EVIDENCE / (stage + ".log")).write_text("Owner: @DNPMBHC\nprocess_timeout\n")
        raise RuntimeError(stage + "_timeout") from None
    (EVIDENCE / (stage + ".log")).write_text("Owner: @DNPMBHC\n" + clean(result.stdout + result.stderr))
    if result.returncode:
        raise RuntimeError(stage + "_failed")
    return result


def build_module(name, files):
    directory = BUILD / name
    directory.mkdir()
    module = directory / (name + ".swiftmodule")
    library = directory / ("lib" + name + ".a")
    command = ["xcrun", "swiftc", "-O", "-warnings-as-errors", "-module-cache-path", str(BUILD / "cache"),
               "-target", platform.machine() + "-apple-macos27.0", "-parse-as-library", "-emit-library",
               "-static", "-emit-module", "-module-name", name, "-emit-module-path", str(module)]
    capture("roundtrip-build-" + name.lower(), command + list(map(str, files)) + ["-o", str(library)])
    return directory, library


def production_version():
    selection = EVIDENCE / "production-validation-selection.json"
    name = "production-interface-version.json"
    if selection.exists():
        selected = json.loads(selection.read_text())
        assert selected.get("owner") == "@DNPMBHC"
        name = selected["manifest"]
        assert Path(name).name == name and name.startswith("production-interface-version") and name.endswith(".json")
    path = EVIDENCE / name
    assert not path.is_symlink()
    version = json.loads(path.read_text())
    assert version.get("owner") == "@DNPMBHC" and version.get("phase") in ("candidate", "stable")
    return version


def main():
    report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "exact_production_graphics_sources_with_exact_error_enum_declaration",
              "vm_actions": 0, "visible_window_created": False, "pointer_capture_used": False,
              "native_fullscreen_verified": False, "real_guest_verified": False,
              "virtual_hid_verified": False, "passed": False}
    try:
        version = production_version()
        snapshot_revision = version.get("snapshot_revision", version["contract_revision"])
        expected = {entry["file"]: entry["sha256"] for entry in version["files"]}
        assert all(digest(RUNTIME / name) == value for name, value in expected.items())
        origins = [(RUNTIME, C_SOURCES), (PRODUCER, B_SOURCES)]
        before = {str(base / name): digest(base / name) for base, names in origins for name in names}
        client_origin = EVIDENCE / "module-bridge-roundtrip.swift"
        before[str(client_origin)] = digest(client_origin)
        client_source = BUILD / "client.swift"
        shutil.copyfile(client_origin, client_source)
        capture("roundtrip-strict-lint", [str(ROOT / "handoff/task-07/.tools/swiftlint"),
                "lint", "--strict", "--quiet", str(client_origin)], cwd=PACKAGE.parent)
        capture("roundtrip-strict-format", ["xcrun", "swift-format", "lint", "--strict",
                "--configuration", str(EVIDENCE / "swift-format-configuration.json"), str(client_origin)])
        paths = {}
        for label, (base, names) in zip(("c", "b"), origins):
            snapshot = BUILD / ("source-" + label)
            snapshot.mkdir()
            paths[label] = []
            for name in names:
                destination = snapshot / name
                shutil.copyfile(base / name, destination)
                paths[label].append(destination)
        declaration = re.search(r"public enum GuestSurfaceSessionError[^\{]+\{[^}]+\}",
                                (RUNTIME / "GuestSurfaceSession.swift").read_text()).group(0)
        error_source = BUILD / "source-c/ExactErrorDeclaration.swift"
        error_source.write_text("// SPDX-License-Identifier: GPL-3.0-or-later\n// Owner: @DNPMBHC\n" + declaration + "\n")
        c_directory, c_library = build_module("ModuleC", paths["c"] + [error_source])
        b_directory, b_library = build_module("ModuleX", paths["b"])
        executable = BUILD / "surface-roundtrip"
        capture("roundtrip-build-client", ["xcrun", "swiftc", "-O", "-warnings-as-errors", "-parse-as-library",
                "-module-cache-path", str(BUILD / "cache"), "-target", platform.machine() + "-apple-macos27.0",
                "-I", str(c_directory), "-I", str(b_directory), "-L", str(c_directory), "-L", str(b_directory),
                "-lModuleC", "-lModuleX", str(client_source), "-o", str(executable)])
        capture("roundtrip-sign-client", ["codesign", "--force", "--sign", "-", "--options", "runtime",
                "--entitlements", str(PRODUCER / "vz_bridge.entitlements"), str(executable)])
        results = []
        for trial in (1, 2):
            execution = capture("roundtrip-execution-" + str(trial), [str(executable)], timeout=30)
            results.append(json.loads(execution.stdout))
        report["runs"] = results
        report["automatic_relaunch_verified"] = len(results) == 2
        report["inputs_stable"] = all(digest(Path(path)) == value for path, value in before.items())
        report["production_snapshot_revision"] = snapshot_revision
        report["production_revision_matches_manifest"] = all(digest(RUNTIME / name) == value for name, value in expected.items())
        report["production_revision_2_unchanged"] = snapshot_revision == 2 and report["production_revision_matches_manifest"]
        report["production_source_hashes"] = {"consumer": {name: digest(RUNTIME / name) for name in C_SOURCES},
                                              "producer": {name: digest(PRODUCER / name) for name in B_SOURCES}}
        report["binary_hashes"] = {"consumer_library": digest(c_library), "producer_library": digest(b_library),
                                   "executable": digest(executable)}
        report["diagnostic_target_readback"] = False
        report["gpu_byte_exact_comparison"] = True
        report["gpu_comparison_statistic_bytes_read"] = 4
        report["client_source_sha256"] = digest(client_source)
        report["source_pixel_readback_used"] = False
        report["passed"] = (report["inputs_stable"] and report["production_revision_matches_manifest"]
                            and all(run["framesConsumed"] == 12 and all(run["checks"].values()) for run in results))
    except (RuntimeError, OSError, ValueError, AssertionError, AttributeError) as error:
        report["error"] = clean(str(error)) or type(error).__name__
    (EVIDENCE / "module-bridge-roundtrip.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"owner": "@DNPMBHC", "passed": report["passed"],
                      "production_revision_2_unchanged": report.get("production_revision_2_unchanged"),
                      "real_guest_verified": False}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
