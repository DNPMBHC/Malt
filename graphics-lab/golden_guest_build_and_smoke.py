#!/usr/bin/env python3
"""End-to-end Golden Guest v1 builder, sealer, and ephemeral smoke validator.

Owner: @DNPMBHC
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

import golden_guest_manager as ggm
import pixel_compare

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
GUEST_TOOLS_ISO = (
    Path.home()
    / "Library/Containers/com.utmapp.UTM/Data/Library/Application Support/GuestSupportTools/utm-guest-tools-3d-latest.iso"
)
def _default_vms_dir() -> Path:
    volumes = Path("/Volumes")
    if volumes.is_dir():
        for vol in sorted(volumes.iterdir()):
            candidate = vol / "whisky-phase2-guest" / "vms"
            if candidate.is_dir():
                return candidate
    return Path("/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/vms")


DEFAULT_PRIMARY = _default_vms_dir() / "Windows11-ARM64.utm"
DEFAULT_GOLDEN = _default_vms_dir() / "golden-win11-arm64-v1.utm"
DEFAULT_EVIDENCE_DIR = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
WARP_REF = (
    WORKSPACE_ROOT
    / "handoff/phase-2/evidence/window-c/m0-m2-guest-final/run-20261122-140047-utc/pixel-validation/validate-legacy-0/validate-legacy-0-reference.rgba"
)
APPLY_OPTIMIZER_PS1 = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"
OPTIMIZER_PROFILE = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
SEAL_SCRIPT_PS1 = WORKSPACE_ROOT / "Whisky/Modules/guest-golden/scripts/seal-golden-guest.ps1"


def run_cmd(args: list[str], timeout: float = 60, **kw: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kw)


def qga_ps(vm_uuid: str, script: str, timeout: float = 90) -> str:
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
        raise RuntimeError(f"QGA PowerShell failed: {ggm.redact_text(res.stderr)}")
    envelope = json.loads(res.stdout.strip().lstrip("\ufeff"))
    if envelope.get("query_token") != token:
        raise RuntimeError("QGA response token mismatch")
    return str(envelope.get("output", ""))


def qga_push(vm_uuid: str, local_path: Path, guest_path: str, timeout: float = 180) -> None:
    with local_path.open("rb") as handle:
        res = subprocess.run(
            [str(UTMCTL), "file", "push", vm_uuid, guest_path],
            stdin=handle,
            capture_output=True,
            timeout=timeout,
        )
    if res.returncode != 0:
        raise RuntimeError(f"QGA file push failed for {guest_path}: {ggm.redact_text(res.stderr.decode(errors='replace'))}")


def qga_pull(vm_uuid: str, guest_path: str, timeout: float = 180) -> bytes:
    res = subprocess.run(
        [str(UTMCTL), "file", "pull", vm_uuid, guest_path],
        capture_output=True,
        timeout=timeout,
    )
    if res.returncode != 0:
        raise RuntimeError(f"QGA file pull failed for {guest_path}")
    return res.stdout


def decode_guest_text(raw: bytes) -> str:
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def register_and_start(bundle_path: Path, vm_uuid: str) -> dict[str, float]:
    t0 = time.monotonic()
    reg = run_cmd(["open", "-a", "UTM", str(bundle_path)], timeout=30)
    if reg.returncode != 0:
        raise RuntimeError(f"Failed to register bundle in UTM: {ggm.redact_text(reg.stderr)}")
    for _ in range(30):
        if ggm.utmctl_status(vm_uuid, UTMCTL) != "unregistered":
            break
        time.sleep(0.5)
    start_res = run_cmd([str(UTMCTL), "start", vm_uuid], timeout=120)
    if start_res.returncode != 0:
        raise RuntimeError(f"Failed to start VM: {ggm.redact_text(start_res.stderr)}")
    vm_started_sec = round(time.monotonic() - t0, 3)

    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            out = qga_ps(vm_uuid, "'qga-ok'", timeout=15)
            if out.strip() == "qga-ok":
                qga_ready_sec = round(time.monotonic() - t0, 3)
                return {
                    "vm_started_seconds": vm_started_sec,
                    "qga_ready_seconds": qga_ready_sec,
                }
        except Exception:
            pass
        time.sleep(1.5)
    raise TimeoutError("Timed out waiting for QGA readiness")


def stop_vm_only(vm_uuid: str) -> None:
    state = ggm.utmctl_status(vm_uuid, UTMCTL)
    if state not in ("stopped", "unregistered"):
        run_cmd([str(UTMCTL), "stop", vm_uuid, "--request"], timeout=30)
        for _ in range(45):
            state = ggm.utmctl_status(vm_uuid, UTMCTL)
            if state in ("stopped", "unregistered"):
                break
            time.sleep(1.0)
        if state not in ("stopped", "unregistered"):
            run_cmd([str(UTMCTL), "stop", vm_uuid, "--kill"], timeout=30)
            for _ in range(15):
                state = ggm.utmctl_status(vm_uuid, UTMCTL)
                if state in ("stopped", "unregistered"):
                    break
                time.sleep(1.0)


def stop_and_unregister(vm_uuid: str) -> None:
    stop_vm_only(vm_uuid)
    if ggm.utmctl_status(vm_uuid, UTMCTL) == "stopped":
        del_res = run_cmd([str(UTMCTL), "delete", vm_uuid], timeout=30)
        if del_res.returncode != 0:
            raise RuntimeError(f"Failed to unregister VM: {ggm.redact_text(del_res.stderr)}")


def install_whql_viogpu3d(vm_uuid: str) -> dict[str, object]:
    if not GUEST_TOOLS_ISO.is_file():
        raise FileNotFoundError(f"Guest Tools ISO missing: {GUEST_TOOLS_ISO}")
    mount_point = Path(tempfile.mkdtemp(prefix="utm-gt-"))
    try:
        att = run_cmd(
            ["hdiutil", "attach", str(GUEST_TOOLS_ISO), "-mountpoint", str(mount_point), "-readonly", "-nobrowse"],
            timeout=60,
        )
        if att.returncode != 0:
            raise RuntimeError(f"Failed to mount Guest Tools ISO: {att.stderr}")
        drv_dir = mount_point / "Drivers" / "viogpu3d" / "w11" / "ARM64"
        if not drv_dir.is_dir():
            raise FileNotFoundError(f"viogpu3d ARM64 driver directory missing in ISO: {drv_dir}")
        qga_ps(vm_uuid, "New-Item -ItemType Directory -Force -Path 'C:\\golden-staging\\viogpu3d' | Out-Null")
        pushed_files = []
        for item in sorted(drv_dir.iterdir()):
            if item.is_file():
                qga_push(vm_uuid, item, f"C:\\golden-staging\\viogpu3d\\{item.name}")
                pushed_files.append(item.name)
    finally:
        run_cmd(["hdiutil", "detach", str(mount_point), "-force"], timeout=30)
        shutil.rmtree(mount_point, ignore_errors=True)

    # Run pnputil via a pushed .ps1 script to avoid PowerShell string-escaping pitfalls
    install_ps1 = (
        "$ErrorActionPreference = 'Continue'\n"
        "& pnputil.exe /add-driver 'C:\\golden-staging\\viogpu3d\\viogpu3d.inf' /install *> 'C:\\golden-staging\\pnp.log'\n"
        "$code = $LASTEXITCODE\n"
        "Set-Content -LiteralPath 'C:\\golden-staging\\pnp.done' -Value ([string]$code)\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as tmp_ps:
        tmp_ps.write(install_ps1)
        tmp_ps_path = Path(tmp_ps.name)
    try:
        qga_push(vm_uuid, tmp_ps_path, r"C:\golden-staging\install_viogpu3d.ps1")
    finally:
        tmp_ps_path.unlink(missing_ok=True)

    launch_ps = (
        "Remove-Item -LiteralPath 'C:\\golden-staging\\pnp.done','C:\\golden-staging\\pnp.log' -ErrorAction SilentlyContinue;"
        "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','C:\\golden-staging\\install_viogpu3d.ps1') -WindowStyle Hidden | Out-Null;"
        "'launched'"
    )
    qga_ps(vm_uuid, launch_ps, timeout=30)

    deadline = time.monotonic() + 300
    exit_code = None
    while time.monotonic() < deadline:
        try:
            val = qga_ps(
                vm_uuid,
                "if(Test-Path 'C:\\golden-staging\\pnp.done'){(Get-Content 'C:\\golden-staging\\pnp.done').Trim()}else{'pending'}",
                timeout=20,
            ).strip()
            if val != "pending":
                exit_code = int(val)
                break
        except Exception:
            pass
        time.sleep(2.0)
    if exit_code is None:
        raise TimeoutError("pnputil viogpu3d install timed out after 300s")
    pnp_log = decode_guest_text(qga_pull(vm_uuid, r"C:\golden-staging\pnp.log"))
    return {"pushed_files": pushed_files, "pnputil": {"exit_code": exit_code, "output": pnp_log}}


def sample_host_idle_rss_mib(samples: int = 5, interval: float = 1.5) -> float:
    totals = []
    for _ in range(samples):
        res = run_cmd(["ps", "-axo", "rss=,comm="], timeout=15)
        rss_kb = 0
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                name = Path(parts[1]).name
                if name in ("QEMULauncher", "QEMURenderServer", "swtpm.0") or name.startswith("qemu-system-"):
                    rss_kb += int(parts[0])
        totals.append(rss_kb / 1024.0)
        time.sleep(interval)
    return round(statistics.mean(totals), 2)


def run_guest_3d_smoke(vm_uuid: str, work_dir: Path) -> dict[str, object]:
    if not D3D11_PROBE.is_file():
        raise FileNotFoundError(f"Missing probe: {D3D11_PROBE}")
    if not WARP_REF.is_file():
        raise FileNotFoundError(f"Missing WARP reference frame: {WARP_REF}")

    qga_ps(vm_uuid, "New-Item -ItemType Directory -Force -Path 'C:\\golden-smoke' | Out-Null")
    qga_push(vm_uuid, D3D11_PROBE, r"C:\golden-smoke\d3d11_probe.exe")

    # Wait for interactive logged-in user session
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        user = qga_ps(vm_uuid, "(Get-CimInstance Win32_ComputerSystem).UserName", timeout=15).strip()
        if user:
            break
        time.sleep(2.0)

    smoke_ps1 = (
        "$ErrorActionPreference = 'Continue'\n"
        "$code = 1\n"
        "try {\n"
        "  & 'C:\\golden-smoke\\d3d11_probe.exe' --frames 1 --warmup 0 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --command-every 30 --resource-every 30 --resource-pattern legacy --seed 1 --completion-mode gpu-complete --driver-type hardware --capture-rgba 'C:\\golden-smoke\\frame0.rgba' --capture-frame 0 --metadata-json 'C:\\golden-smoke\\meta.json' > 'C:\\golden-smoke\\out.log' 2> 'C:\\golden-smoke\\err.log'\n"
        "  $code = $LASTEXITCODE\n"
        "  if ($code -eq 0) {\n"
        "    & 'C:\\golden-smoke\\d3d11_probe.exe' --frames 300 --warmup 60 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --command-every 30 --resource-every 30 --resource-pattern legacy --seed 1 --completion-mode gpu-complete --driver-type hardware --csv 'C:\\golden-smoke\\perf.csv' >> 'C:\\golden-smoke\\out.log' 2>> 'C:\\golden-smoke\\err.log'\n"
        "    $code = $LASTEXITCODE\n"
        "  }\n"
        "} finally {\n"
        "  Set-Content -LiteralPath 'C:\\golden-smoke\\done' -Value ([string]$code)\n"
        "}\n"
    )
    smoke_ps1_path = work_dir / "smoke_probe.ps1"
    smoke_ps1_path.write_text(smoke_ps1, encoding="utf-8")
    qga_push(vm_uuid, smoke_ps1_path, r"C:\golden-smoke\smoke_probe.ps1")

    probe_cmd = (
        "$ErrorActionPreference='Stop';"
        "$user=(Get-CimInstance Win32_ComputerSystem).UserName;"
        "if(!$user){throw 'No interactive desktop user'};"
        "Remove-Item -LiteralPath 'C:\\golden-smoke\\done','C:\\golden-smoke\\out.log','C:\\golden-smoke\\err.log','C:\\golden-smoke\\frame0.rgba','C:\\golden-smoke\\meta.json','C:\\golden-smoke\\perf.csv' -ErrorAction SilentlyContinue;"
        "$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\golden-smoke\\smoke_probe.ps1';"
        "$p=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited;"
        "Register-ScheduledTask -TaskName 'golden-smoke-probe' -Action $a -Principal $p -Force | Out-Null;"
        "Start-ScheduledTask -TaskName 'golden-smoke-probe';"
        "'launched'"
    )
    qga_ps(vm_uuid, probe_cmd, timeout=30)

    deadline = time.monotonic() + 180
    exit_code = None
    while time.monotonic() < deadline:
        val = qga_ps(
            vm_uuid,
            "if(Test-Path 'C:\\golden-smoke\\done'){(Get-Content 'C:\\golden-smoke\\done').Trim()}else{'pending'}",
            timeout=15,
        ).strip()
        if val != "pending":
            exit_code = int(val)
            break
        time.sleep(1.0)
    if exit_code is None:
        raise TimeoutError("d3d11_probe smoke test timed out")

    meta_json = json.loads(qga_pull(vm_uuid, r"C:\golden-smoke\meta.json").decode("utf-8", errors="replace"))
    perf_csv = qga_pull(vm_uuid, r"C:\golden-smoke\perf.csv").decode("utf-8", errors="replace")
    frame_bytes = qga_pull(vm_uuid, r"C:\golden-smoke\frame0.rgba")
    qga_ps(vm_uuid, "Unregister-ScheduledTask -TaskName 'golden-smoke-probe' -Confirm:$false -ErrorAction SilentlyContinue")

    cmp_res = pixel_compare.compare_rgba(WARP_REF.read_bytes(), frame_bytes, 1280, 720, tolerance=0)

    # Parse frame intervals from perf.csv (frames after warmup)
    lines = [ln.strip() for ln in perf_csv.splitlines() if ln.strip()]
    header = lines[0].split(",") if lines else []
    fps_val = None
    mean_ms = None
    p95_ms = None
    if len(lines) > 1 and "cpu_frame_ms" in header:
        idx = header.index("cpu_frame_ms")
        durations = []
        for row_s in lines[1:]:
            cols = row_s.split(",")
            val = float(cols[idx])
            if val > 0.0:
                durations.append(val)
        if durations:
            mean_ms = round(statistics.mean(durations), 3)
            sorted_d = sorted(durations)
            p95_ms = round(sorted_d[min(len(sorted_d) - 1, int(0.95 * len(sorted_d)))], 3)
            fps_val = round(1000.0 / mean_ms, 3)

    return {
        "probe_exit_code": exit_code,
        "adapter_description": meta_json.get("adapter_description"),
        "vendor_id": meta_json.get("vendor_id"),
        "device_id": meta_json.get("device_id"),
        "adapter_is_software": meta_json.get("adapter_is_software"),
        "feature_level": "11_1" if meta_json.get("selected_feature_level") == 0xB100 else str(meta_json.get("selected_feature_level")),
        "d3d11_probe_fps": fps_val,
        "mean_frame_ms": mean_ms,
        "p95_frame_ms": p95_ms,
        "max_channel_error_lsb": cmp_res.get("max_channel_error"),
        "over_threshold_pixels": cmp_res.get("over_threshold_pixels"),
        "byte_exact_match": cmp_res.get("passed"),
    }


def run_smoke_and_finalize(primary: Path, golden: Path, evidence_dir: Path) -> None:
    guest_report_path = evidence_dir / "golden-guest-seal-check.json"
    manifest_path = evidence_dir / "golden-guest-manifest.json"
    if not guest_report_path.is_file():
        raise FileNotFoundError(f"Missing seal check report: {guest_report_path}")

    print("[5/6] Running spawn-ephemeral -> cold boot + 3D smoke -> destroy-ephemeral闭环...")
    ggm.verify_golden(
        golden=golden,
        primary=primary,
        guest_report_path=guest_report_path,
        output_path=manifest_path,
        fast_disk_hash=True,
    )

    spawn_res = ggm.spawn_ephemeral(
        golden=golden,
        name="ephemeral-p6a-smoke",
        primary=primary,
        register_utm=False,
        fast_disk_hash=True,
    )
    eph_path = Path(spawn_res["ephemeral_path"])
    eph_uuid = spawn_res["clone_uuid"]

    with tempfile.TemporaryDirectory(prefix="p6a-smoke-") as tmp_dir:
        try:
            boot_metrics = register_and_start(eph_path, eph_uuid)
            idle_rss = sample_host_idle_rss_mib()
            smoke_3d = run_guest_3d_smoke(eph_uuid, Path(tmp_dir))
            smoke_summary = {
                "ephemeral_clone_seconds": spawn_res["clone_seconds"],
                **boot_metrics,
                "idle_host_rss_mib": idle_rss,
                **smoke_3d,
            }
        finally:
            destroy_res = ggm.destroy_ephemeral(
                ephemeral_path=eph_path,
                golden=golden,
                primary=primary,
                baseline_manifest_path=manifest_path,
                fast_disk_hash=True,
            )

    print("[6/6] Computing final full SHA-256 manifest...")
    smoke_report_path = evidence_dir / "golden-smoke-metrics.json"
    ggm.write_redacted_json(smoke_report_path, {"smoke": smoke_summary, "destroy": destroy_res})
    final_manifest = ggm.verify_golden(
        golden=golden,
        primary=primary,
        guest_report_path=guest_report_path,
        smoke_report_path=smoke_report_path,
        output_path=manifest_path,
        fast_disk_hash=False,
    )
    final_manifest["graphics_driver"]["max_channel_error_lsb"] = smoke_summary.get("max_channel_error_lsb")
    final_manifest["graphics_driver"]["byte_exact_match"] = smoke_summary.get("byte_exact_match")
    final_manifest["smoke_metrics"] = smoke_summary
    final_manifest["lifecycle_verification"] = destroy_res
    ggm.write_redacted_json(manifest_path, final_manifest)
    print("DONE! Golden Guest v1 sealed and verified.")


def build_and_verify(primary: Path, golden: Path, evidence_dir: Path) -> None:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if golden.exists():
        raise RuntimeError(f"Golden bundle already exists at {ggm.redact_text(str(golden))}; refusing overwrite")

    print("[1/6] Staging golden-win11-arm64-v1 from primary vm-a (APFS CoW)...")
    prep = ggm.prepare_golden_from_primary(primary=primary, golden_dest=golden)
    golden_uuid = prep["golden_uuid"]

    try:
        print("[2/6] Booting staging golden VM and installing WHQL viogpu3d...")
        register_and_start(golden, golden_uuid)
        drv_res = install_whql_viogpu3d(golden_uuid)
        print("  pnputil exit:", drv_res["pnputil"]["exit_code"])
        print("  pnputil log:", drv_res["pnputil"]["output"].strip())

        # Cold stop + start so WDDM2 driver initializes cleanly
        print("[3/6] Cold-cycling VM to activate WDDM2 viogpu3d & applying 4C optimizer...")
        stop_vm_only(golden_uuid)
        register_and_start(golden, golden_uuid)

        # Ensure viogpu3d is bound to the VirtIO GPU 3D controller (in case first pnputil only staged oem*.inf)
        gpu_check = qga_ps(
            golden_uuid,
            "$vc = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*VirtIO GPU 3D*' -or $_.PNPDeviceID -like '*VEN_1AF4*DEV_1050*' } | Select-Object -First 1; "
            "if ($vc -and $vc.Status -eq 'OK' -and $vc.Name -like '*VirtIO GPU 3D*') { 'bound' } else { 'unbound' }",
            timeout=30,
        ).strip()
        if gpu_check != "bound":
            print("  Re-binding viogpu3d after cold restart...")
            qga_ps(
                golden_uuid,
                "& pnputil.exe /add-driver 'C:\\golden-staging\\viogpu3d\\viogpu3d.inf' /install *> 'C:\\golden-staging\\pnp-rebind.log'; $LASTEXITCODE",
                timeout=120,
            )

        qga_ps(golden_uuid, "New-Item -ItemType Directory -Force -Path 'C:\\golden-staging' | Out-Null")
        qga_push(golden_uuid, APPLY_OPTIMIZER_PS1, r"C:\golden-staging\apply-optimizer.ps1")
        qga_push(golden_uuid, OPTIMIZER_PROFILE, r"C:\golden-staging\anticheat-minimal-win11-arm64.json")
        qga_push(golden_uuid, SEAL_SCRIPT_PS1, r"C:\golden-staging\seal-golden-guest.ps1")

        qga_ps(
            golden_uuid,
            "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\golden-staging\\apply-optimizer.ps1' -ProfilePath 'C:\\golden-staging\\anticheat-minimal-win11-arm64.json' | Out-Null",
            timeout=120,
        )
        print("  4C optimizer applied.")

        qga_ps(
            golden_uuid,
            "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\golden-staging\\seal-golden-guest.ps1' -CleanCache > 'C:\\golden-staging\\seal.json' 2> 'C:\\golden-staging\\seal.err'",
            timeout=120,
        )
        seal_json_str = decode_guest_text(qga_pull(golden_uuid, r"C:\golden-staging\seal.json")).strip()
        if not seal_json_str:
            seal_err = decode_guest_text(qga_pull(golden_uuid, r"C:\golden-staging\seal.err"))
            raise RuntimeError(f"seal-golden-guest.ps1 produced empty stdout; stderr={seal_err}")
        seal_report = json.loads(seal_json_str)
        if not seal_report.get("all_golden_checks_passed"):
            raise RuntimeError(f"Golden guest sealing checks failed: {json.dumps(seal_report, indent=2)}")

        qga_ps(golden_uuid, "Remove-Item -LiteralPath 'C:\\golden-staging' -Recurse -Force -ErrorAction SilentlyContinue")
        print("[4/6] Cleanly shutting down & sealing golden-win11-arm64-v1 read-only...")
        stop_vm_only(golden_uuid)
        # Preserve bundle via APFS CoW before unregistering from UTM (utmctl delete removes bundle)
        sealed_tmp = golden.parent / f"{golden.name}.sealed"
        if sealed_tmp.exists():
            shutil.rmtree(sealed_tmp)
        ggm.apfs_cow_clone_bundle(golden, sealed_tmp)
        stop_and_unregister(golden_uuid)
        sealed_tmp.rename(golden)
    except Exception:
        stop_and_unregister(golden_uuid)
        raise

    ggm.set_bundle_readonly(golden, readonly=True)
    guest_report_path = evidence_dir / "golden-guest-seal-check.json"
    ggm.write_redacted_json(guest_report_path, seal_report)
    run_smoke_and_finalize(primary, golden, evidence_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build, seal, and smoke-test Golden Guest v1")
    parser.add_argument("--primary", type=Path, default=DEFAULT_PRIMARY)
    parser.add_argument("--golden", type=Path, default=DEFAULT_GOLDEN)
    parser.add_argument("--evidence-dir", type=Path, default=DEFAULT_EVIDENCE_DIR)
    parser.add_argument("--smoke-only", action="store_true")
    args = parser.parse_args()
    if args.smoke_only:
        run_smoke_and_finalize(args.primary, args.golden, args.evidence_dir)
    else:
        build_and_verify(args.primary, args.golden, args.evidence_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
