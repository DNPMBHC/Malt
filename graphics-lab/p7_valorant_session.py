#!/usr/bin/env python3
"""Phase 7A isolated Golden Guest session orchestrator for target-cn blackscreen & Venus testing.

Owner: @DNPMBHC
Safety & Compliance:
- Spawns strictly from sealed read-only golden-win11-arm64-v1 via golden_guest_manager.py.
- Clones cached game data disk via APFS cp -c into the ephemeral clone (never touches source cache).
- Never automates agreements, login, identity checks, or CAPTCHA.
- Read-only telemetry capture inside Guest + zero-drift destruction on exit.
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
import tempfile
import time
from typing import Any
import uuid

import golden_guest_manager as ggm
import p7_valorant_analyzer as analyzer

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
EVIDENCE_P7A = WORKSPACE_ROOT / "handoff/phase-7/evidence/p7-a"
RUNS_DIR = WORKSPACE_ROOT / "handoff/module-f/valorant-phase7-runs"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
DXVK_X64_DIR = (
    Path.home()
    / "Library/Application Support/com.gamemac.www/wine-engine/downloads/dxvk-1.10.3/wine/x86_64-windows"
)
STATE_FILE_NAME = "p7a-session-state.json"


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


def run_cmd(args: list[str], timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def decode_guest_text(raw: bytes) -> str:
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


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
        raise RuntimeError(f"QGA PowerShell failed: {analyzer.redact_p7_text(res.stderr)}")
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
        raise RuntimeError(f"QGA push failed for {guest_path}")


def qga_pull(vm_uuid: str, guest_path: str, timeout: float = 180) -> bytes:
    res = subprocess.run(
        [str(UTMCTL), "file", "pull", vm_uuid, guest_path],
        capture_output=True,
        timeout=timeout,
    )
    if res.returncode != 0:
        raise RuntimeError(f"QGA pull failed for {guest_path}")
    return res.stdout


def sample_host_qemu_metrics(samples: int = 5, interval: float = 1.0) -> dict[str, Any]:
    cpu_render = []
    cpu_qemu = []
    rss_total_mib = []
    for _ in range(samples):
        res = run_cmd(["ps", "-axo", "%cpu=,rss=,comm="], timeout=15)
        r_cpu = 0.0
        q_cpu = 0.0
        rss_kb = 0
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) == 3:
                cpu_val = float(parts[0])
                rss_val = int(parts[1])
                name = Path(parts[2]).name
                if name == "QEMURenderServer":
                    r_cpu += cpu_val
                    rss_kb += rss_val
                elif name in ("QEMULauncher", "swtpm.0") or name.startswith("qemu-system-"):
                    q_cpu += cpu_val
                    rss_kb += rss_val
        cpu_render.append(r_cpu)
        cpu_qemu.append(q_cpu)
        rss_total_mib.append(rss_kb / 1024.0)
        time.sleep(interval)
    return {
        "samples": samples,
        "qemu_render_server_cpu_mean": round(statistics.mean(cpu_render), 2),
        "qemu_render_server_cpu_max": round(max(cpu_render), 2),
        "qemu_worker_cpu_mean": round(statistics.mean(cpu_qemu), 2),
        "total_hypervisor_rss_mib_mean": round(statistics.mean(rss_total_mib), 2),
    }


def spawn_session(name: str = "ephemeral-p7a-valorant", attach_data_disk: bool = True) -> dict[str, Any]:
    guest_root = _external_guest_root()
    vms_dir = guest_root / "vms"
    primary = vms_dir / "Windows11-ARM64.utm"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    state_path = _session_state_path()
    if state_path.exists():
        raise RuntimeError("An active P7A session state file already exists; inspect or destroy first")

    spawn_res = ggm.spawn_ephemeral(
        golden=golden,
        dest_dir=vms_dir,
        name=name,
        primary=primary,
        register_utm=False,
        fast_disk_hash=True,
    )
    eph_path = Path(spawn_res["ephemeral_path"])
    eph_uuid = spawn_res["clone_uuid"]

    data_disk_attached = False
    cache_disk = guest_root / "game-cache" / "valorant-cn-data.qcow2"
    cache_before_stat = None
    if attach_data_disk and cache_disk.is_file():
        st = cache_disk.stat()
        cache_before_stat = {"size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
        clone_data_name = f"p7a-data-{uuid.uuid4().hex[:8]}.qcow2"
        clone_data_path = eph_path / "Data" / clone_data_name
        cp_res = run_cmd(["cp", "-c", str(cache_disk), str(clone_data_path)], timeout=60)
        if cp_res.returncode != 0:
            raise RuntimeError(f"APFS CoW clone of game data disk failed: {cp_res.stderr}")
        cfg = ggm.read_config_plist(eph_path)
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
        data_disk_attached = True

    reg = run_cmd(["open", "-a", "UTM", str(eph_path)], timeout=30)
    if reg.returncode != 0:
        raise RuntimeError("Failed to register ephemeral clone in UTM")
    for _ in range(30):
        if ggm.utmctl_status(eph_uuid, UTMCTL) != "unregistered":
            break
        time.sleep(0.5)

    t0 = time.monotonic()
    start = run_cmd([str(UTMCTL), "start", eph_uuid], timeout=120)
    if start.returncode != 0:
        raise RuntimeError(f"Failed to start ephemeral clone: {analyzer.redact_p7_text(start.stderr)}")

    qga_ready_sec = None
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            if qga_ps(eph_uuid, "'p7a-ready'", timeout=15).strip() == "p7a-ready":
                qga_ready_sec = round(time.monotonic() - t0, 3)
                break
        except Exception:
            pass
        time.sleep(1.5)
    if qga_ready_sec is None:
        raise TimeoutError("Timed out waiting for QGA readiness in P7A clone")

    state = {
        "owner": "@DNPMBHC",
        "created_at_utc": analyzer.utc_now_iso(),
        "clone_name": name,
        "clone_uuid": eph_uuid,
        "ephemeral_path": str(eph_path),
        "primary_path": str(primary),
        "golden_path": str(golden),
        "clone_seconds": spawn_res["clone_seconds"],
        "qga_ready_seconds": qga_ready_sec,
        "data_disk_attached": data_disk_attached,
        "cache_disk_path": str(cache_disk) if data_disk_attached else None,
        "cache_before_stat": cache_before_stat,
    }
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    return state


def load_session_state() -> dict[str, Any]:
    state_path = _session_state_path()
    if not state_path.is_file():
        raise RuntimeError("No active P7A session state found; run spawn first")
    return json.loads(state_path.read_text(encoding="utf-8"))


def run_preflight(vm_uuid: str) -> dict[str, Any]:
    """Read-only check of Secure Boot, TPM, WHQL viogpu3d, DXGI/WMI VRAM, Vulkan ICDs, disks."""
    ps_script = r"""
$ErrorActionPreference = 'Continue'
$sb = $false
try { $sb = [bool](Confirm-SecureBootUEFI) } catch {}
$tpm = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue
$vc = Get-CimInstance Win32_VideoController | Select-Object Name,Status,ConfigManagerErrorCode,DriverVersion,AdapterRAM,PNPDeviceID
$disks = Get-PSDrive -PSProvider FileSystem | Select-Object Name,Root,@{N='UsedGB';E={[math]::Round($_.Used/1GB,2)}},@{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}}
$vkIcds = @()
foreach ($regPath in @(
    'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers',
    'HKLM:\SOFTWARE\WOW6432Node\Khronos\Vulkan\Drivers'
)) {
    if (Test-Path $regPath) {
        $props = (Get-ItemProperty -Path $regPath).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
        foreach ($p in $props) {
            $vkIcds += @{ registry=$regPath; path=$p.Name; disabled=$p.Value; exists=(Test-Path -LiteralPath $p.Name) }
        }
    }
}
$vkSys = @('vulkan-1.dll','vulkan_virtio_arm64.dll','vulkan_virtio_ec.dll','neptune_umd_arm64.dll','neptune_umd_ec.dll') | ForEach-Object {
    $sys32 = Join-Path $env:SystemRoot "System32\$_"
    $repo = @(Get-ChildItem -Path (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') -Recurse -Filter $_ -ErrorAction SilentlyContinue | Select-Object -First 1)
    @{ name=$_; in_system32=(Test-Path $sys32); in_driverstore=($repo.Count -gt 0) }
}
$evApp = (Get-WinEvent -LogName Application -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
$evSys = (Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
$evCi = (Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
@{
    secure_boot_enabled = $sb
    tpm_present = ($null -ne $tpm)
    tpm_enabled = if($tpm){[bool]$tpm.IsEnabled_InitialValue}else{$false}
    video_controllers = @($vc)
    drives = @($disks)
    vulkan_icds = $vkIcds
    graphics_binaries = $vkSys
    eventlog_baseline_record_ids = @{ Application=$evApp; System=$evSys; CodeIntegrity=$evCi }
} | ConvertTo-Json -Depth 6 -Compress
"""
    raw = qga_ps(vm_uuid, ps_script, timeout=90)
    return json.loads(raw)


def collect_readonly_snapshot(vm_uuid: str, label: str, baseline_record_ids: dict[str, Any], out_dir: Path) -> dict[str, Any]:
    """Read-only capture of game processes, modules, UE4 logs, ACE drivers, and EventLog delta."""
    out_dir.mkdir(parents=True, exist_ok=True)
    ps_script = f"""
$ErrorActionPreference = 'Continue'
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {{
    $_.ProcessName -match 'VALORANT|ShooterGame|Riot|WeGame|TGP|ACE|SGuard|AntiCheat|Unreal|CrashReport'
}} | ForEach-Object {{
    $mods = @()
    try {{
        $mods = @($_.Modules | Where-Object {{ $_.ModuleName -match 'dxgi|d3d11|d3d12|neptune|vulkan|dxvk|viogpu|ace|sguard|anti' }} | Select-Object -ExpandProperty ModuleName)
    }} catch {{}}
    @{{
        id = $_.Id
        name = $_.ProcessName
        main_window_title = $_.MainWindowTitle
        has_window = ($_.MainWindowHandle -ne [IntPtr]::Zero)
        working_set_mb = [math]::Round($_.WorkingSet64 / 1MB, 2)
        cpu_seconds = if($_.CPU){{[math]::Round($_.CPU, 2)}}else{{0}}
        loaded_graphics_or_ace_modules = $mods
    }}
}})

$aceSvcs = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object {{
    $_.Name -match 'ACE|AntiCheat|vgk|SGuard' -or $_.PathName -match 'AntiCheatExpert|ACE'
}} | Select-Object Name,DisplayName,State,Status,StartMode,ExitCode)

$userProfile = (Get-ChildItem 'C:\\Users' -Directory | Where-Object {{ $_.Name -notin @('Public','Default','Default User','All Users') }} | Select-Object -First 1).FullName
$logDirs = @()
if ($userProfile) {{
    foreach ($rel in @(
        'AppData\\Local\\VALORANT\\Saved\\Logs',
        'AppData\\Local\\ShooterGame\\Saved\\Logs',
        'AppData\\Local\\VALORANT\\Saved\\Crashes',
        'AppData\\Local\\ShooterGame\\Saved\\Crashes'
    )) {{
        $p = Join-Path $userProfile $rel
        if (Test-Path -LiteralPath $p) {{ $logDirs += $p }}
    }}
}}
$logFiles = @()
foreach ($d in $logDirs) {{
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)) {{
        $logFiles += @{{
            path = $f.FullName
            name = $f.Name
            size_bytes = $f.Length
            mtime_utc = $f.LastWriteTimeUtc.ToString('o')
        }}
    }}
}}

$appMin = {int(baseline_record_ids.get('Application') or 0)}
$sysMin = {int(baseline_record_ids.get('System') or 0)}
$ciMin = {int(baseline_record_ids.get('CodeIntegrity') or 0)}

function Get-DeltaEvents([string]$LogName, [int64]$MinId) {{
    try {{
        return @(Get-WinEvent -LogName $LogName -MaxEvents 60 -ErrorAction SilentlyContinue | Where-Object {{ $_.RecordId -gt $MinId }} | ForEach-Object {{
            @{{
                record_id = $_.RecordId
                time_utc = $_.TimeCreated.ToUniversalTime().ToString('o')
                id = $_.Id
                level = $_.LevelDisplayName
                provider = $_.ProviderName
                message = if($_.Message){{$_.Message.Substring(0, [Math]::Min(320, $_.Message.Length))}}else{{''}}
            }}
        }})
    }} catch {{ return @() }}
}}

@{{
    captured_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    processes = $procs
    ace_drivers = $aceSvcs
    ue4_log_files = $logFiles
    eventlog_delta = @{{
        Application = Get-DeltaEvents 'Application' $appMin
        System = Get-DeltaEvents 'System' $sysMin
        CodeIntegrity = Get-DeltaEvents 'Microsoft-Windows-CodeIntegrity/Operational' $ciMin
    }}
}} | ConvertTo-Json -Depth 6 -Compress
"""
    raw = qga_ps(vm_uuid, ps_script, timeout=120)
    snap = json.loads(raw)

    # Pull and analyze top UE4 logs (read-only) without storing unredacted raw logs in repo
    parsed_logs = []
    for lf in snap.get("ue4_log_files", [])[:5]:
        guest_log_path = lf["path"]
        if lf.get("size_bytes", 0) > 20 * 1024 * 1024 or not guest_log_path.lower().endswith((".log", ".txt", ".xml")):
            continue
        try:
            raw_bytes = qga_pull(vm_uuid, guest_log_path, timeout=90)
            text = decode_guest_text(raw_bytes)
            parsed = analyzer.parse_ue4_log(text)
            parsed["file_name"] = lf["name"]
            parsed["size_bytes"] = lf["size_bytes"]
            parsed_logs.append(parsed)
        except Exception as exc:
            parsed_logs.append({"file_name": lf["name"], "pull_error": analyzer.redact_p7_text(str(exc))})

    snap["parsed_ue4_logs"] = parsed_logs
    snap["host_qemu_metrics"] = sample_host_qemu_metrics(samples=3, interval=1.0)
    redacted_snap = analyzer.redact_p7_value(snap)
    out_file = out_dir / f"snapshot-{label}.json"
    out_file.write_text(json.dumps(redacted_snap, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return redacted_snap


def destroy_session() -> dict[str, Any]:
    state_path = _session_state_path()
    state = load_session_state()
    eph_path = Path(state["ephemeral_path"])
    golden = Path(state["golden_path"])
    primary = Path(state["primary_path"])

    res = ggm.destroy_ephemeral(
        ephemeral_path=eph_path,
        golden=golden,
        primary=primary,
        baseline_manifest_path=GOLDEN_MANIFEST,
        fast_disk_hash=True,
    )
    if GOLDEN_MANIFEST.is_file():
        base_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
        g_full = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
        p_full = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
        res["golden_zero_drift"] = (
            g_full["readonly"]
            and g_full["config_sha256"] == base_fp.get("golden_config_sha256")
            and g_full["bundle_sha256"] == base_fp.get("golden_bundle_sha256")
        )
        res["primary_zero_drift"] = (
            p_full["config_sha256"] == base_fp.get("primary_vm_a_config_sha256")
            and p_full["bundle_sha256"] == base_fp.get("primary_vm_a_bundle_sha256")
        )

    cache_unchanged = None
    if state.get("cache_disk_path") and state.get("cache_before_stat"):
        cd = Path(state["cache_disk_path"])
        st = cd.stat()
        before = state["cache_before_stat"]
        cache_unchanged = (st.st_size == before["size_bytes"] and st.st_mtime_ns == before["mtime_ns"])
    res["cache_disk_untouched"] = cache_unchanged
    state_path.unlink(missing_ok=True)
    return res


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 7A isolated Golden Guest session tool (@DNPMBHC)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_spawn = sub.add_parser("spawn")
    p_spawn.add_argument("--name", default="ephemeral-p7a-valorant")
    p_spawn.add_argument("--no-data-disk", action="store_true")

    sub.add_parser("preflight")

    p_collect = sub.add_parser("collect")
    p_collect.add_argument("--label", required=True)
    p_collect.add_argument("--baseline-file", type=Path, default=EVIDENCE_P7A / "preflight.json")

    sub.add_parser("destroy")

    args = parser.parse_args(argv)
    if args.cmd == "spawn":
        out = spawn_session(name=args.name, attach_data_disk=not args.no_data_disk)
    elif args.cmd == "preflight":
        state = load_session_state()
        out = run_preflight(state["clone_uuid"])
        EVIDENCE_P7A.mkdir(parents=True, exist_ok=True)
        (EVIDENCE_P7A / "preflight.json").write_text(
            json.dumps(analyzer.redact_p7_value(out), indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    elif args.cmd == "collect":
        state = load_session_state()
        baseline_ids = {}
        if args.baseline_file.is_file():
            baseline_ids = json.loads(args.baseline_file.read_text(encoding="utf-8")).get(
                "eventlog_baseline_record_ids", {}
            )
        out = collect_readonly_snapshot(state["clone_uuid"], args.label, baseline_ids, EVIDENCE_P7A)
    elif args.cmd == "destroy":
        out = destroy_session()
    else:
        raise RuntimeError(f"Unknown command: {args.cmd}")
    print(json.dumps(analyzer.redact_p7_value(out), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
