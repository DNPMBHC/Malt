#!/usr/bin/env python3
"""Link the full runtime static product to the actual producer. Owner: @DNPMBHC."""
import hashlib
import importlib.util
import json
import platform
import plistlib
import shutil
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gpu_test_tools", EVIDENCE / "run_module_bridge_roundtrip.py")
gpu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpu)
spec = importlib.util.spec_from_file_location("local_test_tools", EVIDENCE / "run_local_validation.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
PRODUCTS = Path("/tmp/guest-shell-p5c-build/out/Products/Debug")

ORIGINAL_CAPTURE = gpu.capture
CAPTURE_PREFIX = "runtime"


def capture(stage, arguments, **kwargs):
    if stage.startswith("roundtrip-"):
        stage = CAPTURE_PREFIX + "-" + stage
    elif stage.startswith("runtime-") and CAPTURE_PREFIX != "runtime":
        stage = CAPTURE_PREFIX + stage[len("runtime"):]
    return ORIGINAL_CAPTURE(stage, arguments, **kwargs)


gpu.capture = capture



def main(client_name="module-bridge-roundtrip.swift", result_name="runtime-binary-roundtrip", visible_window=False):
    global CAPTURE_PREFIX
    CAPTURE_PREFIX = "native" if visible_window else "runtime"
    report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "complete_runtime_static_archive_plus_actual_producer_sources",
              "consumer_module_alias": "ModuleC", "source_subset_recompiled": False,
              "vm_actions": 0, "visible_window_created": False, "pointer_capture_used": False,
              "native_fullscreen_verified": False, "real_guest_verified": False,
              "virtual_hid_verified": False, "passed": False}
    if visible_window:
        report.update(scope="complete_runtime_native_nswindow_cametal_layer", visible_window_created=True)
    try:
        version = gpu.production_version()
        snapshot_revision = version.get("snapshot_revision", version["contract_revision"])
        expected = {entry["file"]: entry["sha256"] for entry in version["files"]}
        assert all(gpu.digest(gpu.RUNTIME / name) == value for name, value in expected.items())
        before = local.fingerprint()
        report["source_fingerprint_before"] = before
        producer_before = {name: gpu.digest(gpu.PRODUCER / name) for name in gpu.B_SOURCES}
        client = EVIDENCE / client_name
        gpu.capture("runtime-roundtrip-strict-lint", [str(gpu.ROOT / "handoff/task-07/.tools/swiftlint"),
                    "lint", "--strict", "--quiet", str(client)], cwd=gpu.PACKAGE.parent)
        gpu.capture("runtime-roundtrip-strict-format", ["xcrun", "swift-format", "lint", "--strict",
                    "--configuration", str(EVIDENCE / "swift-format-configuration.json"), str(client)])
        client_before = gpu.digest(client)
        gpu.capture("runtime-roundtrip-build-production", ["swift", "build", "--package-path", str(gpu.PACKAGE),
                    "--scratch-path", "/tmp/guest-shell-p5c-build", "--disable-automatic-resolution"])
        assert local.fingerprint() == before
        production = PRODUCTS / ("lib" + gpu.PACKAGE.name + ".a")
        module = PRODUCTS / (gpu.PACKAGE.name + ".swiftmodule")
        assert production.is_file() and module.is_dir()
        archive = gpu.BUILD / "libRuntimeProduction.a"
        shutil.copyfile(production, archive)
        archive_before = gpu.digest(production)
        module_hashes = {p.name: gpu.digest(p) for p in module.iterdir() if p.is_file()}
        assert module_hashes
        report["production_archive_sha256"] = archive_before
        report["consumer_module_sha256"] = module_hashes
        report["production_contract_revision"] = version["contract_revision"]
        report["production_snapshot_revision"] = snapshot_revision
        members = gpu.capture("runtime-roundtrip-archive-members", ["ar", "-t", str(archive)])
        report["archive_member_count"] = len(members.stdout.splitlines())
        report["complete_runtime_object_in_archive"] = (gpu.PACKAGE.name + ".o") in members.stdout.splitlines()
        producer_snapshot = gpu.BUILD / "source-b"
        producer_snapshot.mkdir()
        sources = []
        for name in gpu.B_SOURCES:
            destination = producer_snapshot / name
            shutil.copyfile(gpu.PRODUCER / name, destination)
            sources.append(destination)
        b_directory, b_library = gpu.build_module("ModuleX", sources)
        executable = gpu.BUILD / "runtime-surface-roundtrip"
        sign_target = executable
        if visible_window:
            app = gpu.BUILD / "GuestShellDiagnostics.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            executable = contents / "MacOS/GuestShellDiagnostics"
            info = {"CFBundleExecutable": "GuestShellDiagnostics", "CFBundleIdentifier": "org.example.guestshell.diagnostics",
                    "CFBundleName": "Guest Shell Diagnostics", "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                    "NSHighResolutionCapable": True, "owner": "@DNPMBHC"}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            sign_target = app
        gpu.capture("runtime-roundtrip-build-client", ["xcrun", "swiftc", "-O", "-warnings-as-errors",
                    "-parse-as-library", "-target", platform.machine() + "-apple-macos27.0",
                    "-module-cache-path", str(gpu.BUILD / "cache"),
                    "-module-alias", "ModuleC=" + gpu.PACKAGE.name,
                    "-I", str(PRODUCTS), "-F", str(PRODUCTS / "PackageFrameworks"),
                    "-I", str(b_directory), "-L", str(b_directory), "-lModuleX",
                    str(archive), str(client), "-o", str(executable)])
        gpu.capture("runtime-roundtrip-sign-client", ["codesign", "--force", "--sign", "-", "--options", "runtime",
                    "--entitlements", str(gpu.PRODUCER / "vz_bridge.entitlements"), str(sign_target)])
        runs = []
        report["runs"] = runs
        for trial in (1, 2):
            stage = "runtime-roundtrip-execution-" + str(trial)
            if visible_window:
                result_path = gpu.BUILD / ("native-result-" + str(trial) + ".json")
                gpu.capture(stage, ["open", "-W", "-n", str(app), "--args", str(result_path)], timeout=30)
                result = json.loads(result_path.read_text())
                log = EVIDENCE / ("native-roundtrip-execution-" + str(trial) + ".log")
                log.write_text(log.read_text() + json.dumps(result) + "\n")
                runs.append(result)
                if result.get("passed") is False or not result.get("checks"):
                    raise RuntimeError("native_roundtrip_reported_failure")
            else:
                execution = gpu.capture(stage, [str(executable)], timeout=30)
                runs.append(json.loads(execution.stdout))
        report["runs"] = runs
        report["automatic_relaunch_verified"] = len(runs) == 2
        report["producer_source_hashes"] = producer_before
        report["producer_library_sha256"] = gpu.digest(b_library)
        report["client_source_sha256"] = client_before
        report["runner_source_sha256"] = gpu.digest(Path(__file__))
        report["executable_sha256"] = gpu.digest(executable)
        report["source_fingerprint_after"] = local.fingerprint()
        report["inputs_stable"] = (before == report["source_fingerprint_after"]
                                  and gpu.digest(client) == client_before
                                  and gpu.digest(production) == archive_before
                                  and all(gpu.digest(gpu.PRODUCER / name) == value
                                          for name, value in producer_before.items())
                                  and all(gpu.digest(module / name) == value
                                          for name, value in module_hashes.items()))
        report["production_fingerprint"] = version["production_fingerprint"]
        report["production_revision_matches_manifest"] = all(gpu.digest(gpu.RUNTIME / name) == value
                                                             for name, value in expected.items())
        report["production_revision_2_unchanged"] = snapshot_revision == 2 and report["production_revision_matches_manifest"]
        report["source_pixel_readback_used"] = False
        report["gpu_byte_exact_comparison"] = not visible_window
        if visible_window:
            report["native_fullscreen_verified"] = all(run["checks"].get("native_fullscreen_transition_notified") for run in runs)
            report["native_window_and_cametal_layer_verified"] = all(run["checks"].get("native_cametal_layer_attached") for run in runs)
            report["native_drawable_pixel_comparison_performed"] = False
            report["native_app_launched_via_launch_services"] = True
            report["native_app_waited_until_termination"] = True
        report["gpu_comparison_statistic_bytes_read"] = 0 if visible_window else 4
        report["passed"] = (report["inputs_stable"] and report["production_revision_matches_manifest"]
                            and report["complete_runtime_object_in_archive"]
                            and all(run["framesConsumed"] == 12 and all(run["checks"].values()) for run in runs))
    except (RuntimeError, OSError, ValueError, AssertionError, AttributeError) as error:
        report["error"] = gpu.clean(str(error)) or type(error).__name__
    (EVIDENCE / (result_name + ".json")).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"owner": "@DNPMBHC", "passed": report["passed"],
                      "scope": report["scope"], "real_guest_verified": False}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
