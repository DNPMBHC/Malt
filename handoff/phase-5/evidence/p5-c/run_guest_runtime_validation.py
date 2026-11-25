#!/usr/bin/env python3
"""Run only the frozen D3D probe inside the proved C-owned clone. Owner: @DNPMBHC."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import tempfile
import uuid
from datetime import datetime
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[3]
spec = importlib.util.spec_from_file_location("clone_boundary", EVIDENCE / "guest_clone_control.py")
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)
PROBE_SHA256 = "09bb190bf5d763f9749345300b937728db886a4ec26c32c361a920c565cf1bee"


def selected_version():
    selection = json.loads((EVIDENCE / "production-validation-selection.json").read_text())
    name = selection["manifest"]
    if selection.get("owner") != "@DNPMBHC" or Path(name).name != name:
        raise RuntimeError("source_manifest_selection_invalid")
    return json.loads((EVIDENCE / name).read_text())


def authorize():
    previous = json.loads((clone.A_EVIDENCE / "vm-lease.json").read_text())
    allowed, reason = clone.guard.check(previous)
    if not allowed: raise RuntimeError(reason)
    lease = json.loads(clone.LEASE.read_text())
    if lease.get("status") != "held" or lease.get("source_fingerprint_unchanged") is not True:
        raise RuntimeError("C_owned_clone_proof_missing")
    if not all(lease.get(field) is True for field in ("writable_disks_contained", "shared_directory_disabled")):
        raise RuntimeError("C_clone_disk_or_sharing_proof_missing")
    released = previous.get("released_at") or previous.get("released_at_utc") or previous.get("releasedAt")
    if datetime.fromisoformat(lease["created_at"]) < datetime.fromisoformat(released.replace("Z", "+00:00")):
        raise RuntimeError("C_clone_created_before_A_release")
    owned, identifier = clone.own_clone(lease)
    source, _ = clone.source_bundle()
    clone.assert_no_source_control_process(source)
    baseline = json.loads((EVIDENCE / "own-source-before.json").read_text())
    print(json.dumps({"owner": "@DNPMBHC", "stage": "independent_source_check_before_runtime"}), flush=True)
    current = clone.fingerprint(source)
    if clone.signature(current) != clone.signature(baseline):
        raise RuntimeError("source_changed_before_runtime")
    clone.save(EVIDENCE / "own-source-before-runtime.json", dict(current, owner="@DNPMBHC"))
    return owned, identifier


def find_inputs():
    ready = json.loads((EVIDENCE / "guest-runtime-probe-readiness.json").read_text())
    version = selected_version()
    if not ready.get("passed") or ready.get("production_fingerprint") != version["production_fingerprint"]:
        raise RuntimeError("runtime_probe_build_proof_mismatch")
    package = next(ROOT.glob("*/*/Package.swift")).parent
    runtime = next(package.glob("Sources/*/Runtime"))
    if not all(clone.digest(runtime / entry["file"]) == entry["sha256"] for entry in version["files"]):
        raise RuntimeError("runtime_sources_changed_after_probe_build")
    binaries = [p / "guest-runtime-probe" for p in Path(tempfile.gettempdir()).glob("guest-shell-roundtrip-*")
                if (p / "guest-runtime-probe").is_file()
                and clone.digest(p / "guest-runtime-probe") == ready["executable_sha256"]]
    if len(binaries) != 1: raise RuntimeError("built_runtime_probe_not_unique")
    files = subprocess.run(["rg", "--files", "--hidden", "-g", "d3d11_probe.exe",
                            "-g", "desktop-helper.exe", "-g", "!**/.git/**"],
                           cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
    probes = [ROOT / name for name in files if Path(name).name == "d3d11_probe.exe"
              and clone.digest(ROOT / name) == PROBE_SHA256]
    helpers = [ROOT / name for name in files if Path(name).name == "desktop-helper.exe"]
    if not probes or len(helpers) != 1: raise RuntimeError("frozen_probe_or_helper_unavailable")
    return binaries[0], sorted(probes)[0], helpers[0], version


def run(control_id, discover=False, fingerprint=False, dpi_roundtrip=False, supported=False):
    owned, identifier = authorize()
    executable, probe, helper, version = find_inputs()
    if control_id is not None and not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", control_id):
        raise RuntimeError("observed_scale_control_id_invalid")
    configuration = {"identifier": identifier.upper(), "architecture": "aarch64",
                     "fileMappings": [{"hostDirectory": probe.parent.as_uri(),
                                       "guestDirectory": "C:\\guest-shell-lab\\probe"}],
                     "startupTimeoutSeconds": 300}
    payload = {"configuration": configuration, "executableURL": probe.as_uri(),
               "helperURL": helper.as_uri(), "guestHelperPath": "C:\\guest-shell-lab\\desktop-helper.exe",
               "arguments": ["--frames", "600", "--warmup", "60", "--width", "1280", "--height", "720",
                             "--commands", "16", "--resource-bytes", "65536", "--completion-mode", "gpu-complete"],
               "journalURL": (EVIDENCE / "guest-runtime-recovery-journal.json").as_uri(),
               "timeoutSeconds": 240, "scaleAutomationID": control_id, "operation": "discover" if discover else ("fingerprint" if fingerprint else ("dpiRoundTrip" if dpi_roundtrip else None))}
    if supported:
        modes = json.loads((EVIDENCE / "guest-supported-mode-inspection.json").read_text()).get("modes", [])
        if not any(x.get("width") == 1920 and x.get("height") == 1080 for x in modes):
            raise RuntimeError("live_target_mode_not_observed")
        payload.update(operation="supportedLifecycle", dynamicWindowWidth=1920, dynamicWindowHeight=1080)
    if fingerprint:
        payload["arguments"] += ["--metadata-json", r"C:\guest-shell-lab\d3d-metadata.json"]
    env = dict(os.environ, GUEST_SHELL_EXECUTION_PERMIT=str(uuid.uuid4()))
    print(json.dumps({"owner": "@DNPMBHC", "stage": "guarded_runtime_display_and_lifecycle"}), flush=True)
    response = subprocess.run([str(executable), "--guarded-execution"],
                              input=json.dumps(payload), capture_output=True, text=True, env=env, timeout=600)
    report = json.loads(response.stdout)
    report.update(owner="@DNPMBHC", production_snapshot_revision=version["snapshot_revision"],
                  production_fingerprint=version["production_fingerprint"],
                  frozen_probe_sha256=PROBE_SHA256, helper_sha256=clone.digest(helper),
                  runtime_binary_sha256=clone.digest(executable), executed=True,
                  target_game_verified=False, Windows_scanout_verified=False, virtual_hid_verified=False)
    if fingerprint:
        spec = importlib.util.spec_from_file_location("actual_probe_readback", EVIDENCE / "bootstrap_guest_clone.py")
        reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reader)
        metadata = reader.powershell(identifier, r"""
$data=Get-Content -Raw -LiteralPath 'C:\guest-shell-lab\d3d-metadata.json'|ConvertFrom-Json
@{adapter_description=$data.adapter_description;vendor_id=$data.vendor_id;device_id=$data.device_id;
 adapter_flags=$data.adapter_flags;selected_feature_level=$data.selected_feature_level;
 windows_session_id=$data.windows_session_id;device_create_hresult=$data.device_create_hresult}
""")
        report["actual_adapter"] = metadata
        report["hardware_FL_11_1_verified"] = (metadata.get("selected_feature_level") == "11_1"
             and metadata.get("windows_session_id") == 1 and metadata.get("adapter_flags") == 0
             and metadata.get("adapter_description") == "Red Hat VirtIO GPU 3D controller")
        report["passed"] = report.get("passed") is True and report["hardware_FL_11_1_verified"]
    name = "guest-supported-display-lifecycle.json" if supported else ("guest-dpi-real-roundtrip.json" if dpi_roundtrip else ("guest-d3d-hardware-probe.json" if fingerprint else ("guest-dpi-controls.json" if discover else "guest-runtime-real-display-lifecycle.json")))
    clone.save(EVIDENCE / name, report)
    if response.returncode or report.get("passed") is not True:
        raise RuntimeError("guest_runtime_lifecycle_validation_failed")
    return {"owner": "@DNPMBHC", "guest_discovery_passed" if discover else ("guest_hardware_probe_passed" if fingerprint else "guest_lifecycle_passed"): True,
            "target_game_verified": False, "Windows_scanout_verified": False, "virtual_hid_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "discover", "fingerprint", "dpi-roundtrip", "supported-lifecycle", "run"), nargs="?", default="inspect")
    parser.add_argument("--observed-scale-control-id")
    args = parser.parse_args()
    try:
        if args.action == "inspect":
            allowed, reason = clone.guard.check(json.loads((clone.A_EVIDENCE / "vm-lease.json").read_text()))
            result = {"owner": "@DNPMBHC", "A_release_verified": allowed,
                      "C_lease_exists": clone.LEASE.exists(), "reason": reason, "vm_control_actions": 0}
        else:
            result = run(args.observed_scale_control_id, discover=args.action == "discover", fingerprint=args.action == "fingerprint", dpi_roundtrip=args.action == "dpi-roundtrip", supported=args.action == "supported-lifecycle")
        print(json.dumps(result), flush=True)
        return 0
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired):
        print(json.dumps({"owner": "@DNPMBHC", "error_code": "guarded_runtime_not_completed"}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
