#!/usr/bin/env python3
"""Build-only real Guest lifecycle probe; never controls a VM. Owner: @DNPMBHC."""
import importlib.util
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guest_build_tools", EVIDENCE / "run_module_bridge_roundtrip.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
spec = importlib.util.spec_from_file_location("guest_input_tools", EVIDENCE / "run_local_validation.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
PRODUCTS = Path("/tmp/guest-shell-p5c-build/out/Products/Debug")


def main():
    report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "complete_runtime_headless_guest_probe_build_only", "vm_actions": 0,
              "guest_execution_enabled": False, "guest_validation": "not_tested",
              "guest_scanout_verified": False, "virtual_hid_verified": False,
              "system_dpi_scaling_implemented": True, "passed": False}
    try:
        version = build.production_version()
        expected = {entry["file"]: entry["sha256"] for entry in version["files"]}
        assert all(build.digest(build.RUNTIME / name) == value for name, value in expected.items())
        before = local.fingerprint()
        source = EVIDENCE / "guest-runtime-probe.swift"
        support = EVIDENCE / "guest-runtime-probe-operations.swift"
        build.capture("guest-probe-strict-lint", [str(build.ROOT / "handoff/task-07/.tools/swiftlint"),
                      "lint", "--strict", "--quiet", str(source), str(support)], cwd=build.PACKAGE.parent)
        build.capture("guest-probe-strict-format", ["xcrun", "swift-format", "lint", "--strict",
                      "--configuration", str(EVIDENCE / "swift-format-configuration.json"), str(source), str(support)])
        build.capture("guest-probe-build-production", ["swift", "build", "--package-path", str(build.PACKAGE),
                      "--scratch-path", "/tmp/guest-shell-p5c-build", "--disable-automatic-resolution"])
        archive = PRODUCTS / ("lib" + build.PACKAGE.name + ".a")
        module = PRODUCTS / (build.PACKAGE.name + ".swiftmodule")
        executable = build.BUILD / "guest-runtime-probe"
        assert archive.is_file() and module.is_dir()
        archive_hash = build.digest(archive)
        build.capture("guest-probe-build-client", ["xcrun", "swiftc", "-O", "-warnings-as-errors",
                      "-parse-as-library", "-target", platform.machine() + "-apple-macos27.0",
                      "-module-cache-path", str(build.BUILD / "cache"),
                      "-module-alias", "ModuleC=" + build.PACKAGE.name,
                      "-I", str(PRODUCTS), "-F", str(PRODUCTS / "PackageFrameworks"),
                      str(archive), str(source), str(support), "-o", str(executable)])
        build.capture("guest-probe-sign-client", ["codesign", "--force", "--sign", "-",
                      "--options", "runtime", str(executable)])
        rejection = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
        rejected = json.loads(rejection.stdout)
        report["unguarded_execution_rejected_before_vm_access"] = (
            rejection.returncode == 1 and rejected.get("errorCode") == "guardedExecutionRequired")
        assert report["unguarded_execution_rejected_before_vm_access"]
        report.update(production_snapshot_revision=version["snapshot_revision"],
                      production_fingerprint=version["production_fingerprint"],
                      source_fingerprint_before=before, source_fingerprint_after=local.fingerprint(),
                      production_archive_sha256=archive_hash, source_sha256=build.digest(source), support_source_sha256=build.digest(support),
                      executable_sha256=build.digest(executable),
                      runner_source_sha256=build.digest(Path(__file__)),
                      consumer_module_sha256={p.name: build.digest(p) for p in module.iterdir() if p.is_file()},
                      isolated_build_directory=build.BUILD.name,
                      recovery_journal="atomic_baseline_before_first_display_apply",
                      cold_headless_start_verified=False,
                      required_initial_guest_state="stopped_paused_or_started_owned_clone",
                      required_execution_gate="current_released_A_lease_and_independent_C_clone_proofs")
        report["inputs_stable"] = (before == report["source_fingerprint_after"]
                                   and build.digest(archive) == archive_hash
                                   and all(build.digest(build.RUNTIME / name) == value
                                           for name, value in expected.items()))
        report["passed"] = report["inputs_stable"]
    except (RuntimeError, OSError, ValueError, AssertionError) as error:
        report["error"] = build.clean(str(error)) or type(error).__name__
    (EVIDENCE / "guest-runtime-probe-readiness.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"owner": "@DNPMBHC", "passed": report["passed"], "vm_actions": 0,
                      "guest_execution_enabled": False}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
