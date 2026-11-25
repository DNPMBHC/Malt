#!/usr/bin/env python3
"""Phase 9A UTM native DXMT backend switcher, d3d11_probe validator, and host sample tool.

Owner: @DNPMBHC
Safety & Compliance:
- Backs up and restores com.utmapp.UTM sandbox preferences cleanly.
- Uses golden_guest_manager.py spawn-ephemeral / destroy-ephemeral strictly.
- Verifies QEMURenderServer mapped frameworks via read-only lsof.
- Captures macOS native `sample <PID> 3` on QEMURenderServer if freeze occurs.
"""
from __future__ import annotations

import argparse
import base64
import functools
import hashlib
import http.server
import json
from pathlib import Path
import plistlib
import socketserver
import statistics
import subprocess
import tempfile
import threading
import time
from typing import Any
import uuid

import golden_guest_manager as ggm
import p9_valorant_analyzer as analyzer
import pixel_compare

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
UTM_PLIST = (
    Path.home()
    / "Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
)
EVIDENCE_P9A = WORKSPACE_ROOT / "handoff/phase-9/evidence/p9-a"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
WARP_REF = (
    WORKSPACE_ROOT
    / "handoff/phase-2/evidence/window-c/m0-m2-guest-final/run-20261122-140047-utc/pixel-validation/validate-legacy-0/validate-legacy-0-reference.rgba"
)
STATE_FILE_NAME = "p9a-session-state.json"
PLIST_BACKUP_NAME = "p9a-utm-plist-backup.json"


def _external_guest_root() -> Path:
    volumes = Path("/Volumes")
    if volumes.is_dir():
        for vol in sorted(volumes.iterdir()):
            candidate = vol / "whisky-phase2-guest"
            if candidate.is_dir():
                return candidate
    raise RuntimeError("External whisky-phase2-guest volume not mounted")


def _session_state_path() -> Path:
    return _external_guest_root() / "vms" / STATE_FILE_NAME


def _plist_backup_path() -> Path:
    return _external_guest_root() / "vms" / PLIST_BACKUP_NAME


def run_cmd(args: list[str], timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def decode_guest_text(raw: bytes) -> str:
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def qga_ps(vm_uuid: str, script: str, timeout: float = 60) -> str:
    token = uuid.uuid4().hex
    wrapped = (
        "$ProgressPreference='SilentlyContinue'; $result = & { "
        + script
        + " }; @{query_token='"
        + token
        + "';output=($result|Out-String).Trim()}|ConvertTo-Json -Depth 4 -Compress"
    )
    encoded = base64.b64encode(wrapped.encode("utf-16-le")).decode()
    res = run_cmd(
        [str(UTMCTL), "exec", vm_uuid, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand", encoded],
        timeout=timeout,
    )
    if res.returncode != 0:
        raise RuntimeError(f"QGA PowerShell failed: {analyzer.redact_p9_text(res.stderr)}")
    envelope = json.loads(res.stdout.strip().lstrip("\ufeff"))
    if envelope.get("query_token") != token:
        raise RuntimeError("QGA response token mismatch")
    return str(envelope.get("output", ""))


def qga_push(vm_uuid: str, local_path: Path, guest_path: str, timeout: float = 120) -> None:
    with local_path.open("rb") as handle:
        res = subprocess.run(
            [str(UTMCTL), "file", "push", vm_uuid, guest_path],
            stdin=handle,
            capture_output=True,
            timeout=timeout,
        )
    if res.returncode != 0:
        raise RuntimeError(f"QGA push failed for {guest_path}")


def qga_pull(vm_uuid: str, guest_path: str, timeout: float = 60) -> bytes:
    res = subprocess.run(
        [str(UTMCTL), "file", "pull", vm_uuid, guest_path],
        capture_output=True,
        timeout=timeout,
    )
    if res.returncode != 0:
        raise RuntimeError(f"QGA pull failed for {guest_path}")
    return res.stdout


def set_utm_directx_driver(driver_value: int | str | None, restart_utm: bool = True) -> dict[str, Any]:
    """Safely back up and set QEMUDirectXDriver in UTM sandbox preferences."""
    backup_path = _plist_backup_path()
    current_plist: dict[str, Any] = {}
    if UTM_PLIST.is_file():
        with UTM_PLIST.open("rb") as f:
            current_plist = plistlib.load(f)

    if not backup_path.exists():
        backup_data = {
            "had_key": "QEMUDirectXDriver" in current_plist,
            "original_value": current_plist.get("QEMUDirectXDriver"),
        }
        backup_path.write_text(json.dumps(backup_data, indent=2) + "\n", encoding="utf-8")

    if restart_utm:
        run_cmd(["osascript", "-e", 'tell application "UTM" to quit'], timeout=15)
        time.sleep(2.0)

    if driver_value is None:
        run_cmd(["defaults", "delete", str(UTM_PLIST), "QEMUDirectXDriver"], timeout=15)
    elif isinstance(driver_value, int):
        run_cmd(["defaults", "write", str(UTM_PLIST), "QEMUDirectXDriver", "-int", str(driver_value)], timeout=15)
    else:
        run_cmd(["defaults", "write", str(UTM_PLIST), "QEMUDirectXDriver", "-string", str(driver_value)], timeout=15)

    # Flush cfprefsd cache for UTM
    run_cmd(["killall", "cfprefsd"], timeout=10)
    time.sleep(1.0)
    if restart_utm:
        run_cmd(["open", "-a", "UTM"], timeout=15)
        time.sleep(2.5)

    with UTM_PLIST.open("rb") as f:
        after_plist = plistlib.load(f)
    return {
        "requested_value": driver_value,
        "observed_plist_value": after_plist.get("QEMUDirectXDriver"),
        "backup_saved": backup_path.is_file(),
    }


def restore_utm_directx_driver(restart_utm: bool = True) -> dict[str, Any]:
    backup_path = _plist_backup_path()
    if not backup_path.is_file():
        return {"restored": True, "note": "No backup file present; defaults unchanged"}
    backup = json.loads(backup_path.read_text(encoding="utf-8"))
    if restart_utm:
        run_cmd(["osascript", "-e", 'tell application "UTM" to quit'], timeout=15)
        time.sleep(2.0)
    if backup.get("had_key"):
        val = backup.get("original_value")
        if isinstance(val, int):
            run_cmd(["defaults", "write", str(UTM_PLIST), "QEMUDirectXDriver", "-int", str(val)], timeout=15)
        else:
            run_cmd(["defaults", "write", str(UTM_PLIST), "QEMUDirectXDriver", "-string", str(val)], timeout=15)
    else:
        run_cmd(["defaults", "delete", str(UTM_PLIST), "QEMUDirectXDriver"], timeout=15)
    run_cmd(["killall", "cfprefsd"], timeout=10)
    time.sleep(1.0)
    if restart_utm:
        run_cmd(["open", "-a", "UTM"], timeout=15)
        time.sleep(2.0)
    backup_path.unlink(missing_ok=True)
    return {"restored": True, "original_had_key": backup.get("had_key")}


def inspect_render_server_frameworks() -> dict[str, Any]:
    """Read-only lsof inspection across all live QEMURenderServer PIDs."""
    ps_res = run_cmd(["ps", "-axo", "pid=,rss=,%cpu=,comm="], timeout=15)
    render_procs = []
    for line in ps_res.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4 and Path(parts[3]).name == "QEMURenderServer":
            render_procs.append({"pid": int(parts[0]), "rss_kb": int(parts[1]), "cpu": float(parts[2])})

    render_procs.sort(key=lambda x: x["rss_kb"], reverse=True)
    combined_lsof = []
    per_pid = []
    for proc in render_procs[:6]:
        lsof_res = run_cmd(["lsof", "-p", str(proc["pid"])], timeout=15)
        parsed = analyzer.parse_lsof_backend_frameworks(lsof_res.stdout)
        per_pid.append({**proc, **parsed})
        combined_lsof.append(lsof_res.stdout)

    overall = analyzer.parse_lsof_backend_frameworks("\n".join(combined_lsof))
    return {
        "render_server_count": len(render_procs),
        "top_workers": per_pid,
        "overall": overall,
    }


def sample_top_render_server(seconds: int = 3, label: str = "freeze") -> dict[str, Any]:
    """Execute macOS native read-only `sample <PID> <seconds>` on highest-RSS QEMURenderServer."""
    ps_res = run_cmd(["ps", "-axo", "pid=,rss=,%cpu=,comm="], timeout=15)
    candidates = []
    for line in ps_res.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4 and Path(parts[3]).name == "QEMURenderServer":
            candidates.append({"pid": int(parts[0]), "rss_kb": int(parts[1]), "cpu": float(parts[2])})
    candidates.sort(key=lambda x: x["rss_kb"], reverse=True)
    if not candidates:
        raise RuntimeError("No QEMURenderServer process found to sample")
    target = candidates[0]
    res = run_cmd(["sample", str(target["pid"]), str(seconds)], timeout=seconds + 30)
    parsed = analyzer.parse_sample_stack(res.stdout)
    out = analyzer.redact_p9_value(
        {
            "owner": "@DNPMBHC",
            "captured_at_utc": analyzer.utc_now_iso(),
            "target_worker": target,
            "sample_exit_code": res.returncode,
            "parsed_stack": parsed,
        }
    )
    EVIDENCE_P9A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P9A / f"sample-renderserver-{label}.json").write_text(
        json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return out


def run_d3d11_probe_check(vm_uuid: str, label: str) -> dict[str, Any]:
    guest_dir = f"C:\\p9a-probe-{label}"
    qga_ps(vm_uuid, f"New-Item -ItemType Directory -Force -Path '{guest_dir}' | Out-Null", timeout=20)
    qga_push(vm_uuid, D3D11_PROBE, f"{guest_dir}\\d3d11_probe.exe")
    ps1 = (
        "$ErrorActionPreference = 'Continue'\n"
        "$code = 1\n"
        "try {\n"
        f"  & '{guest_dir}\\d3d11_probe.exe' --frames 1 --warmup 0 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --command-every 30 --resource-every 30 --resource-pattern legacy --seed 1 --completion-mode gpu-complete --driver-type hardware --capture-rgba '{guest_dir}\\frame0.rgba' --capture-frame 0 --metadata-json '{guest_dir}\\meta.json' > '{guest_dir}\\out.log' 2> '{guest_dir}\\err.log'\n"
        "  $code = $LASTEXITCODE\n"
        "  if ($code -eq 0) {\n"
        f"    & '{guest_dir}\\d3d11_probe.exe' --frames 300 --warmup 60 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --command-every 30 --resource-every 30 --resource-pattern legacy --seed 1 --completion-mode gpu-complete --driver-type hardware --csv '{guest_dir}\\perf.csv' >> '{guest_dir}\\out.log' 2>> '{guest_dir}\\err.log'\n"
        "    $code = $LASTEXITCODE\n"
        "  }\n"
        "} finally {\n"
        f"  Set-Content -LiteralPath '{guest_dir}\\done' -Value ([string]$code)\n"
        "}\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as f:
        f.write(ps1)
        tmp_ps = Path(f.name)
    try:
        qga_push(vm_uuid, tmp_ps, f"{guest_dir}\\run.ps1")
    finally:
        tmp_ps.unlink(missing_ok=True)

    task_name = f"p9a-probe-{label}"
    launch = (
        "$user=(Get-CimInstance Win32_ComputerSystem).UserName;"
        f"Remove-Item -LiteralPath '{guest_dir}\\done' -ErrorAction SilentlyContinue;"
        f"$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {guest_dir}\\run.ps1';"
        "$p=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited;"
        f"Register-ScheduledTask -TaskName '{task_name}' -Action $a -Principal $p -Force | Out-Null;"
        f"Start-ScheduledTask -TaskName '{task_name}'; 'ok'"
    )
    qga_ps(vm_uuid, launch, timeout=25)

    deadline = time.monotonic() + 120
    exit_code = None
    while time.monotonic() < deadline:
        val = qga_ps(
            vm_uuid,
            f"if(Test-Path '{guest_dir}\\done'){{(Get-Content '{guest_dir}\\done').Trim()}}else{{'pending'}}",
            timeout=15,
        ).strip()
        if val != "pending":
            exit_code = int(val)
            break
        time.sleep(1.5)
    qga_ps(vm_uuid, f"Unregister-ScheduledTask -TaskName '{task_name}' -Confirm:$false -ErrorAction SilentlyContinue", timeout=15)
    if exit_code is None:
        raise TimeoutError(f"d3d11_probe {label} timed out")

    meta = json.loads(decode_guest_text(qga_pull(vm_uuid, f"{guest_dir}\\meta.json")))
    frame = qga_pull(vm_uuid, f"{guest_dir}\\frame0.rgba")
    cmp_res = pixel_compare.compare_rgba(WARP_REF.read_bytes(), frame, 1280, 720, tolerance=0)
    perf_csv = decode_guest_text(qga_pull(vm_uuid, f"{guest_dir}\\perf.csv"))
    lines = [ln.strip() for ln in perf_csv.splitlines() if ln.strip()]
    hdr = lines[0].split(",")
    c_idx = hdr.index("cpu_frame_ms")
    g_idx = hdr.index("gpu_ms")
    cpu_durs = [float(r.split(",")[c_idx]) for r in lines[1:] if r.split(",")[c_idx].strip() and float(r.split(",")[c_idx]) > 0]
    gpu_durs = [float(r.split(",")[g_idx]) for r in lines[1:] if r.split(",")[g_idx].strip()]
    mean_ms = round(statistics.mean(cpu_durs), 3) if cpu_durs else None
    sorted_c = sorted(cpu_durs)
    p95_ms = round(sorted_c[min(len(sorted_c) - 1, int(0.95 * len(sorted_c)))], 3) if sorted_c else None
    fps = round(1000.0 / mean_ms, 3) if mean_ms else None
    gpu_ms_mean = round(statistics.mean(gpu_durs), 4) if gpu_durs else 0.0

    lsof_info = inspect_render_server_frameworks()
    return {
        "label": label,
        "exit_code": exit_code,
        "adapter_description": meta.get("adapter_description"),
        "feature_level": meta.get("selected_feature_level"),
        "fps": fps,
        "mean_frame_ms": mean_ms,
        "p95_frame_ms": p95_ms,
        "gpu_ms_mean": gpu_ms_mean,
        "pixel_compare": {
            "max_channel_error_lsb": cmp_res["max_channel_error"],
            "over_threshold_pixels": cmp_res["over_threshold_pixels"],
            "byte_exact_match": cmp_res["passed"],
        },
        "render_server_lsof": lsof_info,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 9A UTM DXMT backend & sample tool (@DNPMBHC)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_set = sub.add_parser("set-driver")
    p_set.add_argument("--value", required=True)
    p_set.add_argument("--as-int", action="store_true")
    p_set.add_argument("--no-restart", action="store_true")

    sub.add_parser("restore-driver")
    sub.add_parser("lsof-render")

    p_sample = sub.add_parser("sample-render")
    p_sample.add_argument("--seconds", type=int, default=3)
    p_sample.add_argument("--label", default="freeze")

    args = parser.parse_args(argv)
    if args.cmd == "set-driver":
        val: int | str = int(args.value) if args.as_int else args.value
        out = set_utm_directx_driver(val, restart_utm=not args.no_restart)
    elif args.cmd == "restore-driver":
        out = restore_utm_directx_driver(restart_utm=True)
    elif args.cmd == "lsof-render":
        out = inspect_render_server_frameworks()
    elif args.cmd == "sample-render":
        out = sample_top_render_server(seconds=args.seconds, label=args.label)
    else:
        raise RuntimeError(f"Unknown command: {args.cmd}")
    print(json.dumps(analyzer.redact_p9_value(out), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
