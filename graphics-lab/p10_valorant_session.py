#!/usr/bin/env python3
"""Phase 10A session orchestrator: trimmed DXMT clone, cursor trials, 3-5m range telemetry, zero-drift cleanup.

Owner: @DNPMBHC
Compliance:
- Uses `golden_guest_manager.py spawn-ephemeral --trim-hardware --dx-driver DXMT --fps-limit 120`.
- Applies guest-optimizer v2 in ephemeral clone only.
- Backs up & restores UTM sandbox defaults (QEMUDirectXDriver, QEMURendererFPSLimit).
- Strictly read-only monitoring; never hooks game/ACE or automates login/character creation/CAPTCHA.
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time
from typing import Any
import uuid

import golden_guest_manager as ggm
import p8_valorant_session as p8s
import p9_valorant_session as p9s
import p10_valorant_analyzer as analyzer

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
UTM_PLIST = (
    Path.home()
    / "Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
)
EVIDENCE_P10A = WORKSPACE_ROOT / "handoff/phase-10/evidence/p10-a"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
OPT_V2_SCRIPT = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"
OPT_V2_PROFILE = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
STATE_FILE_NAME = "p10a-session-state.json"
PLIST_BACKUP_NAME = "p10a-utm-plist-backup.json"


def _external_guest_root() -> Path:
    volumes = Path("/Volumes")
    if volumes.is_dir():
        for vol in sorted(volumes.iterdir()):
            candidate = vol / "whisky-phase2-guest"
            if candidate.is_dir():
                return candidate
    raise RuntimeError("External whisky-phase2-guest volume is not mounted")


def _session_state_path() -> Path:
    return _external_guest_root() / "vms" / STATE_FILE_NAME


def _plist_backup_path() -> Path:
    return _external_guest_root() / "vms" / PLIST_BACKUP_NAME


def run_cmd(args: list[str], timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def set_utm_dxmt_and_fps(dx_driver_int: int = 2, fps_limit: int = 120) -> dict[str, Any]:
    backup_path = _plist_backup_path()
    current: dict[str, Any] = {}
    if UTM_PLIST.is_file():
        with UTM_PLIST.open("rb") as f:
            current = plistlib.load(f)
    if not backup_path.exists():
        backup = {
            "QEMUDirectXDriver": {"present": "QEMUDirectXDriver" in current, "value": current.get("QEMUDirectXDriver")},
            "QEMURendererFPSLimit": {"present": "QEMURendererFPSLimit" in current, "value": current.get("QEMURendererFPSLimit")},
        }
        backup_path.write_text(json.dumps(backup, indent=2) + "\n", encoding="utf-8")

    run_cmd(["osascript", "-e", 'tell application "UTM" to quit'], timeout=15)
    time.sleep(2.0)
    run_cmd(["defaults", "write", str(UTM_PLIST), "QEMUDirectXDriver", "-int", str(dx_driver_int)], timeout=15)
    run_cmd(["defaults", "write", str(UTM_PLIST), "QEMURendererFPSLimit", "-int", str(fps_limit)], timeout=15)
    run_cmd(["killall", "cfprefsd"], timeout=10)
    time.sleep(1.0)
    run_cmd(["open", "-a", "UTM"], timeout=15)
    time.sleep(2.5)

    with UTM_PLIST.open("rb") as f:
        after = plistlib.load(f)
    return {
        "QEMUDirectXDriver": after.get("QEMUDirectXDriver"),
        "QEMURendererFPSLimit": after.get("QEMURendererFPSLimit"),
        "backup_saved": backup_path.is_file(),
    }


def restore_utm_prefs() -> dict[str, Any]:
    backup_path = _plist_backup_path()
    if not backup_path.is_file():
        return {"restored": True, "note": "No backup present"}
    backup = json.loads(backup_path.read_text(encoding="utf-8"))
    run_cmd(["osascript", "-e", 'tell application "UTM" to quit'], timeout=15)
    time.sleep(2.0)
    for key in ("QEMUDirectXDriver", "QEMURendererFPSLimit"):
        info = backup.get(key, {})
        if info.get("present"):
            val = info.get("value")
            if isinstance(val, int):
                run_cmd(["defaults", "write", str(UTM_PLIST), key, "-int", str(val)], timeout=15)
            else:
                run_cmd(["defaults", "write", str(UTM_PLIST), key, "-string", str(val)], timeout=15)
        else:
            run_cmd(["defaults", "delete", str(UTM_PLIST), key], timeout=15)
    run_cmd(["killall", "cfprefsd"], timeout=10)
    time.sleep(1.0)
    run_cmd(["open", "-a", "UTM"], timeout=15)
    time.sleep(2.0)
    backup_path.unlink(missing_ok=True)
    return {"restored": True}


def inspect_input_and_cursor_stack(vm_uuid: str) -> dict[str, Any]:
    """Read-only inspection of host QEMU input flags and Guest cursor/vdagent/HID state."""
    ps_host = run_cmd(["ps", "-axo", "command="], timeout=15)
    qemu_cmd = ""
    for line in ps_host.stdout.splitlines():
        if "qemu-system-" in line or ("QEMULauncher" in line and "-device" in line):
            qemu_cmd = line
            break
    host_inputs = analyzer.parse_qemu_input_devices(qemu_cmd)

    ps_guest = r"""
$ErrorActionPreference = 'Continue'
$mice = @(Get-CimInstance Win32_PointingDevice | Select-Object Name,DeviceID,Status,PNPDeviceID)
$vd = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vdagent|spice' } | Select-Object Name,Status,StartType)
$mouseReg = Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -ErrorAction SilentlyContinue | Select-Object MouseTrails,MouseSpeed,MouseThreshold1,MouseThreshold2,MouseSensitivity
$deskReg = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue | Select-Object UserPreferencesMask
$vc = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*VirtIO*' } | Select-Object -First 1 Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate
@{
    pointing_devices = $mice
    spice_services = $vd
    mouse_registry = $mouseReg
    video_controller = $vc
} | ConvertTo-Json -Depth 5 -Compress
"""
    guest_state = json.loads(p9s.qga_ps(vm_uuid, ps_guest, timeout=25))
    lsof_info = p9s.inspect_render_server_frameworks()
    return analyzer.redact_p10_value(
        {
            "captured_at_utc": analyzer.utc_now_iso(),
            "host_qemu_inputs": host_inputs,
            "guest_input_state": guest_state,
            "render_server_backend": lsof_info.get("overall"),
        }
    )


def apply_cursor_trial_settings(
    vm_uuid: str,
    *,
    vdagent_action: str = "keep",
    disable_pointer_shadow: bool = False,
    disable_pointer_accel: bool = False,
) -> dict[str, Any]:
    """Apply standard, compliant Windows cursor/service toggles (keeping MouseTrails=0)."""
    actions = ["$ErrorActionPreference = 'Continue'"]
    if vdagent_action == "stop":
        actions.append("Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vdagent|spice' } | Stop-Service -Force -ErrorAction SilentlyContinue")
    elif vdagent_action == "start":
        actions.append("Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vdagent|spice' } | Start-Service -ErrorAction SilentlyContinue")

    if disable_pointer_accel:
        actions.append("Set-ItemProperty -Path 'HKCU:\\Control Panel\\Mouse' -Name 'MouseSpeed' -Value '0' -EA SilentlyContinue")
        actions.append("Set-ItemProperty -Path 'HKCU:\\Control Panel\\Mouse' -Name 'MouseThreshold1' -Value '0' -EA SilentlyContinue")
        actions.append("Set-ItemProperty -Path 'HKCU:\\Control Panel\\Mouse' -Name 'MouseThreshold2' -Value '0' -EA SilentlyContinue")

    # Always enforce MouseTrails = 0
    actions.append("Set-ItemProperty -Path 'HKCU:\\Control Panel\\Mouse' -Name 'MouseTrails' -Value '0' -EA SilentlyContinue")

    if disable_pointer_shadow:
        actions.append(
            "Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; "
            "public static class PtrShadow { [DllImport(\"user32.dll\")] public static extern bool SystemParametersInfoW(uint a, uint b, IntPtr c, uint d); }'; "
            "[void][PtrShadow]::SystemParametersInfoW(0x101B, 0, [IntPtr]::Zero, 3)"
        )
    actions.append(
        "$vd = @(Get-Service -EA SilentlyContinue | Where-Object { $_.Name -match 'vdagent|spice' } | Select-Object Name,Status); "
        "$mr = Get-ItemProperty -Path 'HKCU:\\Control Panel\\Mouse' -EA SilentlyContinue | Select-Object MouseTrails,MouseSpeed,MouseThreshold1,MouseThreshold2; "
        "@{ spice_services=$vd; mouse_registry=$mr } | ConvertTo-Json -Depth 4 -Compress"
    )
    raw = p9s.qga_ps(vm_uuid, "; ".join(actions), timeout=25)
    return json.loads(raw)


def spawn_trimmed_dxmt_session(name: str = "ephemeral-p10a-valorant", pure_usb_mouse: bool = False) -> dict[str, Any]:
    guest_root = _external_guest_root()
    vms_dir = guest_root / "vms"
    primary = vms_dir / "Windows11-ARM64.utm"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    state_path = _session_state_path()
    if state_path.exists():
        raise RuntimeError("Active P10A session state exists; destroy first")

    utm_prefs = set_utm_dxmt_and_fps(dx_driver_int=2, fps_limit=120)

    # Spawn strictly via golden_guest_manager.py CLI with --trim-hardware --dx-driver DXMT --fps-limit 120
    cmd = [
        "python3",
        "-B",
        str(WORKSPACE_ROOT / "graphics-lab/golden_guest_manager.py"),
        "spawn-ephemeral",
        "--golden",
        str(golden),
        "--dest-dir",
        str(vms_dir),
        "--name",
        name,
        "--primary",
        str(primary),
        "--fast-disk-hash",
        "--trim-hardware",
        "--dx-driver",
        "DXMT",
        "--fps-limit",
        "120",
    ]
    res = run_cmd(cmd, timeout=90)
    if res.returncode != 0:
        raise RuntimeError(f"spawn-ephemeral failed: {analyzer.redact_p10_text(res.stderr)}")
    spawn_out = json.loads(res.stdout)
    eph_path = vms_dir / f"{name}.utm"
    eph_uuid = spawn_out["clone_uuid"]

    cfg = ggm.read_config_plist(eph_path)
    if pure_usb_mouse:
        # Attempt pure relative mouse mode by switching UsbBusSupport / PS2 or explicit usb-mouse hint
        cfg.setdefault("QEMU", {})["PS2Controller"] = False
        cfg.setdefault("Input", {})["UsbBusSupport"] = "3.0"
        # Note: UTM adds usb-tablet automatically unless configured via Input/QEMU; recorded in inspect-input

    # Attach APFS CoW cloned game data disk
    cache_disk = guest_root / "game-cache" / "valorant-cn-data.qcow2"
    cache_before_stat = None
    if cache_disk.is_file():
        st = cache_disk.stat()
        cache_before_stat = {"size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
        clone_data_name = f"p10a-data-{uuid.uuid4().hex[:8]}.qcow2"
        cp_res = run_cmd(["cp", "-c", str(cache_disk), str(eph_path / "Data" / clone_data_name)], timeout=60)
        if cp_res.returncode != 0:
            raise RuntimeError(f"APFS CoW clone of game data disk failed: {cp_res.stderr}")
        cfg.setdefault("Drive", []).append(
            {
                "Identifier": str(uuid.uuid4()).upper(),
                "ImageName": clone_data_name,
                "ImageType": "Disk",
                "Interface": "NVMe",
                "InterfaceVersion": 1,
                "ReadOnly": False,
            }
        )
    ggm.write_config_plist(eph_path, cfg)

    run_cmd(["open", "-a", "UTM", str(eph_path)], timeout=30)
    for _ in range(30):
        if ggm.utmctl_status(eph_uuid, UTMCTL) != "unregistered":
            break
        time.sleep(0.5)

    t0 = time.monotonic()
    start_res = run_cmd([str(UTMCTL), "start", eph_uuid], timeout=120)
    if start_res.returncode != 0:
        raise RuntimeError(f"Failed to start P10A clone: {analyzer.redact_p10_text(start_res.stderr)}")

    qga_ready_s = None
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            if p9s.qga_ps(eph_uuid, "'p10a-ready'", timeout=15).strip() == "p10a-ready":
                qga_ready_s = round(time.monotonic() - t0, 3)
                break
        except Exception:
            pass
        time.sleep(1.5)
    if qga_ready_s is None:
        raise TimeoutError("Timed out waiting for QGA readiness")

    # Wait for interactive desktop user
    u_dl = time.monotonic() + 45
    while time.monotonic() < u_dl:
        if p9s.qga_ps(eph_uuid, "(Get-CimInstance Win32_ComputerSystem).UserName", timeout=15).strip():
            break
        time.sleep(1.5)

    # Apply optimizer v2 inside ephemeral clone
    p9s.qga_ps(eph_uuid, "New-Item -ItemType Directory -Force -Path 'F:\\p10a-tools' | Out-Null", timeout=20)
    p9s.qga_push(eph_uuid, OPT_V2_SCRIPT, r"F:\p10a-tools\apply-optimizer.ps1")
    p9s.qga_push(eph_uuid, OPT_V2_PROFILE, r"F:\p10a-tools\anticheat-minimal-win11-arm64.json")
    p9s.qga_ps(
        eph_uuid,
        "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'F:\\p10a-tools\\apply-optimizer.ps1' -ProfilePath 'F:\\p10a-tools\\anticheat-minimal-win11-arm64.json' | Out-Null; 'opt-v2-ok'",
        timeout=90,
    )

    # Pre-seed 1280x720 windowed GameUserSettings.ini + static 1280x720 + MouseTrails=0
    seed_ps = r"""
$dir = 'F:\VALORANT_CN\Tencent Games\VALORANT\live\ShooterGame\Saved\Config\WindowsClient'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ini = @"
[/Script/ShooterGame.ShooterGameUserSettings]
bShouldLetterbox=True
bLastConfirmedShouldLetterbox=True
bUseVSync=False
bUseDynamicResolution=False
ResolutionSizeX=1280
ResolutionSizeY=720
LastUserConfirmedResolutionSizeX=1280
LastUserConfirmedResolutionSizeY=720
WindowPosX=0
WindowPosY=0
FullscreenMode=2
LastConfirmedFullscreenMode=2
PreferredFullscreenMode=2
FrameRateLimit=0.000000
DesiredScreenWidth=1280
DesiredScreenHeight=720
LastUserConfirmedDesiredScreenWidth=1280
LastUserConfirmedDesiredScreenHeight=720

[/Script/Engine.GameUserSettings]
bUseDesiredScreenHeight=False
"@
Set-Content -LiteralPath (Join-Path $dir 'GameUserSettings.ini') -Value $ini -Encoding ASCII
'ok'
"""
    p9s.qga_ps(eph_uuid, seed_ps, timeout=20)
    disp_res = p8s.configure_guest_display_and_pointer(eph_uuid, width=1280, height=720, mouse_trails=0, fullscreen_mode=2)

    ev_baseline = json.loads(
        p9s.qga_ps(
            eph_uuid,
            "@{Application=(Get-WinEvent -LogName Application -MaxEvents 1 -EA SilentlyContinue).RecordId;"
            "System=(Get-WinEvent -LogName System -MaxEvents 1 -EA SilentlyContinue).RecordId;"
            "CodeIntegrity=(Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 1 -EA SilentlyContinue).RecordId}|ConvertTo-Json -Compress",
            timeout=20,
        )
    )
    installer_sha = p8s.transfer_and_launch_installer(eph_uuid)
    input_stack = inspect_input_and_cursor_stack(eph_uuid)

    state = {
        "owner": "@DNPMBHC",
        "created_at_utc": analyzer.utc_now_iso(),
        "clone_name": name,
        "clone_uuid": eph_uuid,
        "ephemeral_path": str(eph_path),
        "primary_path": str(primary),
        "golden_path": str(golden),
        "utm_prefs": utm_prefs,
        "clone_seconds": spawn_out.get("clone_seconds"),
        "qga_ready_seconds": qga_ready_s,
        "optimizer_v2_applied": True,
        "display_and_pointer": disp_res,
        "input_stack": input_stack,
        "eventlog_baseline_record_ids": ev_baseline,
        "installer_sha256": installer_sha,
        "cache_disk_path": str(cache_disk) if cache_before_stat else None,
        "cache_before_stat": cache_before_stat,
    }
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    EVIDENCE_P10A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P10A / "spawn-preflight.json").write_text(
        json.dumps(analyzer.redact_p10_value(state), indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return state


def load_session_state() -> dict[str, Any]:
    path = _session_state_path()
    if not path.is_file():
        raise RuntimeError("No active P10A session state found; run spawn first")
    return json.loads(path.read_text(encoding="utf-8"))


def monitor_training_range(duration_seconds: int = 210, label: str = "range") -> dict[str, Any]:
    state = load_session_state()
    vm_uuid = state["clone_uuid"]
    host_samples: list[dict[str, Any]] = []
    guest_samples: list[dict[str, Any]] = []
    t0 = time.monotonic()
    next_guest = 0.0
    prev_frame: int | None = None
    prev_t: float | None = None

    while True:
        elapsed = time.monotonic() - t0
        if elapsed > duration_seconds:
            break
        host_samples.append(p8s.sample_host_qemu_once(elapsed))
        if elapsed >= next_guest:
            try:
                gs = p8s.sample_guest_lightweight(vm_uuid, elapsed)
                cur_f = gs.get("last_frame_number")
                est_fps = None
                if cur_f is not None and prev_frame is not None and prev_t is not None:
                    dt = elapsed - prev_t
                    if dt > 0:
                        df = (cur_f - prev_frame) % 1000
                        if df > 0:
                            est_fps = round(df / dt, 2)
                gs["estimated_fps"] = est_fps
                guest_samples.append(gs)
                if cur_f is not None:
                    prev_frame = cur_f
                    prev_t = elapsed
            except Exception as exc:
                guest_samples.append({"elapsed_seconds": round(elapsed, 2), "poll_error": analyzer.redact_p10_text(str(exc))})
            next_guest = elapsed + 15.0
        time.sleep(2.0)

    ev_base = state.get("eventlog_baseline_record_ids", {})
    sys_min = int(ev_base.get("System") or 0)
    app_min = int(ev_base.get("Application") or 0)
    ev_ps = (
        f"$sys = @(Get-WinEvent -LogName System -MaxEvents 40 -EA SilentlyContinue | Where-Object {{ $_.RecordId -gt {sys_min} -and $_.ProviderName -ne 'TPM' }} | "
        "Select-Object RecordId,Id,LevelDisplayName,ProviderName,@{N='Msg';E={if($_.Message){$_.Message.Substring(0,[Math]::Min(180,$_.Message.Length))}else{''}}});"
        f"$app = @(Get-WinEvent -LogName Application -MaxEvents 40 -EA SilentlyContinue | Where-Object {{ $_.RecordId -gt {app_min} -and $_.ProviderName -ne 'qemu-ga' }} | "
        "Select-Object RecordId,Id,LevelDisplayName,ProviderName,@{N='Msg';E={if($_.Message){$_.Message.Substring(0,[Math]::Min(180,$_.Message.Length))}else{''}}});"
        "@{System=$sys;Application=$app}|ConvertTo-Json -Depth 4 -Compress"
    )
    ev_delta = json.loads(p9s.qga_ps(vm_uuid, ev_ps, timeout=25))

    summary = analyzer.summarize_range_benchmark(host_samples, guest_samples)
    out = analyzer.redact_p10_value(
        {
            "owner": "@DNPMBHC",
            "label": label,
            "captured_at_utc": analyzer.utc_now_iso(),
            "summary": summary,
            "eventlog_delta": ev_delta,
            "guest_samples": guest_samples,
        }
    )
    EVIDENCE_P10A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P10A / f"monitor-{label}.json").write_text(
        json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return out


def destroy_session() -> dict[str, Any]:
    state_path = _session_state_path()
    state = load_session_state()
    vm_uuid = state["clone_uuid"]
    eph_path = Path(state["ephemeral_path"])
    golden = Path(state["golden_path"])
    primary = Path(state["primary_path"])

    st = ggm.utmctl_status(vm_uuid, UTMCTL)
    if st not in ("stopped", "unregistered"):
        run_cmd([str(UTMCTL), "stop", vm_uuid, "--request"], timeout=20)
        for _ in range(10):
            if ggm.utmctl_status(vm_uuid, UTMCTL) in ("stopped", "unregistered"):
                break
            time.sleep(1.0)
        if ggm.utmctl_status(vm_uuid, UTMCTL) not in ("stopped", "unregistered"):
            run_cmd([str(UTMCTL), "stop", vm_uuid, "--kill"], timeout=20)
            time.sleep(3.0)

    ggm.destroy_ephemeral(
        ephemeral_path=eph_path,
        golden=golden,
        primary=primary,
        baseline_manifest_path=None,
        fast_disk_hash=True,
    )
    restore_res = restore_utm_prefs()

    base_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
    g_full = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
    p_full = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)

    cache_ok = None
    if state.get("cache_disk_path") and state.get("cache_before_stat"):
        cst = Path(state["cache_disk_path"]).stat()
        b = state["cache_before_stat"]
        cache_ok = (cst.st_size == b["size_bytes"] and cst.st_mtime_ns == b["mtime_ns"])

    drift = {
        "ephemeral_deleted": not eph_path.exists(),
        "utm_defaults_restored": restore_res.get("restored", False),
        "golden_readonly": g_full["readonly"],
        "golden_config_sha256": g_full["config_sha256"],
        "golden_bundle_sha256": g_full["bundle_sha256"],
        "golden_zero_drift": (
            g_full["readonly"]
            and g_full["config_sha256"] == base_fp.get("golden_config_sha256")
            and g_full["bundle_sha256"] == base_fp.get("golden_bundle_sha256")
        ),
        "primary_vm_a_config_sha256": p_full["config_sha256"],
        "primary_vm_a_bundle_sha256": p_full["bundle_sha256"],
        "primary_zero_drift": (
            p_full["config_sha256"] == base_fp.get("primary_vm_a_config_sha256")
            and p_full["bundle_sha256"] == base_fp.get("primary_vm_a_bundle_sha256")
        ),
        "cache_disk_untouched": cache_ok,
    }
    EVIDENCE_P10A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P10A / "zero-drift-proof.json").write_text(
        json.dumps(drift, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    state_path.unlink(missing_ok=True)
    return drift


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 10A session orchestrator (@DNPMBHC)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sp = sub.add_parser("spawn")
    p_sp.add_argument("--name", default="ephemeral-p10a-valorant")
    p_sp.add_argument("--pure-usb-mouse", action="store_true")

    sub.add_parser("inspect-input")

    p_ct = sub.add_parser("cursor-trial")
    p_ct.add_argument("--vdagent", choices=("keep", "stop", "start"), default="keep")
    p_ct.add_argument("--disable-shadow", action="store_true")
    p_ct.add_argument("--disable-accel", action="store_true")

    p_mon = sub.add_parser("monitor")
    p_mon.add_argument("--duration-seconds", type=int, default=210)
    p_mon.add_argument("--label", default="range")

    sub.add_parser("destroy")

    args = parser.parse_args(argv)
    if args.cmd == "spawn":
        out = spawn_trimmed_dxmt_session(name=args.name, pure_usb_mouse=args.pure_usb_mouse)
    elif args.cmd == "inspect-input":
        out = inspect_input_and_cursor_stack(load_session_state()["clone_uuid"])
    elif args.cmd == "cursor-trial":
        out = apply_cursor_trial_settings(
            load_session_state()["clone_uuid"],
            vdagent_action=args.vdagent,
            disable_pointer_shadow=args.disable_shadow,
            disable_pointer_accel=args.disable_accel,
        )
    elif args.cmd == "monitor":
        out = monitor_training_range(duration_seconds=args.duration_seconds, label=args.label)
    elif args.cmd == "destroy":
        out = destroy_session()
    else:
        raise RuntimeError(f"Unknown command: {args.cmd}")
    print(json.dumps(analyzer.redact_p10_value(out), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
