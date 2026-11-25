#!/usr/bin/env python3
"""Phase 8A isolated Golden Guest session manager: static 1280x720, pointer visibility, and 3-5m monitor.

Owner: @DNPMBHC
Compliance:
- Uses golden_guest_manager.py spawn-ephemeral / destroy-ephemeral strictly.
- Locks UTM DynamicResolution=False + Guest 1280x720 + GameUserSettings 1280x720 windowed.
- Configures standard Windows software cursor fallback (MouseTrails) without hooking any game.
- Never automates login, character creation input, or CAPTCHA.
"""
from __future__ import annotations

import argparse
import base64
import functools
import hashlib
import http.server
import json
from pathlib import Path
import re
import socketserver
import subprocess
import tempfile
import threading
import time
from typing import Any
import uuid

import golden_guest_manager as ggm
import p8_valorant_analyzer as analyzer

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
EVIDENCE_P8A = WORKSPACE_ROOT / "handoff/phase-8/evidence/p8-a"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
STATE_FILE_NAME = "p8a-session-state.json"


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
        raise RuntimeError(f"QGA PowerShell failed: {analyzer.redact_p8_text(res.stderr)}")
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


def load_session_state() -> dict[str, Any]:
    path = _session_state_path()
    if not path.is_file():
        raise RuntimeError("No active P8A session state found; run spawn first")
    return json.loads(path.read_text(encoding="utf-8"))


def sample_host_qemu_once(elapsed_sec: float) -> dict[str, Any]:
    res = run_cmd(["ps", "-axo", "%cpu=,rss=,comm="], timeout=10)
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
    return {
        "captured_at_utc": analyzer.utc_now_iso(),
        "elapsed_seconds": round(elapsed_sec, 2),
        "qemu_render_server_cpu": round(r_cpu, 2),
        "qemu_worker_cpu": round(q_cpu, 2),
        "total_hypervisor_rss_mib": round(rss_kb / 1024.0, 2),
    }


def configure_guest_display_and_pointer(vm_uuid: str, width: int = 1280, height: int = 720, mouse_trails: int = 2, fullscreen_mode: int = 2) -> dict[str, Any]:
    """Lock Guest desktop to static 1280x720, enable software cursor fallback, and align GameUserSettings.ini."""
    ps1_content = rf"""
$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32DispPtr {{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODEW {{
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
    }}
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettingsW(string dev, int modeNum, ref DEVMODEW dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODEW dm, IntPtr hwnd, uint flags, IntPtr lparam);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    public static int SetResolution(uint w, uint h) {{
        DEVMODEW dm = new DEVMODEW();
        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
        if (!EnumDisplaySettingsW(null, -1, ref dm)) return -99;
        dm.dmPelsWidth = w;
        dm.dmPelsHeight = h;
        dm.dmFields = 0x00080000 | 0x00100000; // DM_PELSWIDTH | DM_PELSHEIGHT
        return ChangeDisplaySettingsExW(null, ref dm, IntPtr.Zero, 0x00000001, IntPtr.Zero); // CDS_UPDATEREGISTRY
    }}
    public static bool SetMouseTrails(uint trails) {{
        // SPI_SETMOUSETRAILS = 0x005D; SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 3
        return SystemParametersInfoW(0x005D, trails, IntPtr.Zero, 3);
    }}
}}
"@

$dispCode = [Win32DispPtr]::SetResolution({width}, {height})
$trailsOk = [Win32DispPtr]::SetMouseTrails({mouse_trails})
# Also persist MouseTrails in HKCU\Control Panel\Mouse for interactive user
Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseTrails' -Value '{mouse_trails}' -ErrorAction SilentlyContinue

$dmCur = New-Object Win32DispPtr+DEVMODEW
$dmCur.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dmCur)
[void][Win32DispPtr]::EnumDisplaySettingsW($null, -1, [ref]$dmCur)

$inis = @(Get-ChildItem 'F:\VALORANT_CN\Tencent Games\VALORANT\live\ShooterGame\Saved\Config' -Recurse -Filter 'GameUserSettings.ini' -ErrorAction SilentlyContinue)
foreach ($ini in $inis) {{
    $txt = Get-Content -LiteralPath $ini.FullName -Raw
    $txt = $txt -replace 'ResolutionSizeX=\d+', 'ResolutionSizeX={width}'
    $txt = $txt -replace 'ResolutionSizeY=\d+', 'ResolutionSizeY={height}'
    $txt = $txt -replace 'LastUserConfirmedResolutionSizeX=\d+', 'LastUserConfirmedResolutionSizeX={width}'
    $txt = $txt -replace 'LastUserConfirmedResolutionSizeY=\d+', 'LastUserConfirmedResolutionSizeY={height}'
    $txt = $txt -replace 'LastConfirmedFullscreenMode=\d+', 'LastConfirmedFullscreenMode={fullscreen_mode}'
    $txt = $txt -replace 'PreferredFullscreenMode=\d+', 'PreferredFullscreenMode={fullscreen_mode}'
    $txt = $txt -replace 'bUseVSync=\w+', 'bUseVSync=False'
    if ($txt -notmatch '(?m)^FullscreenMode=') {{
        $txt = $txt -replace '(PreferredFullscreenMode={fullscreen_mode})', "`$1`r`nFullscreenMode={fullscreen_mode}"
    }} else {{
        $txt = $txt -replace '(?m)^FullscreenMode=\d+', 'FullscreenMode={fullscreen_mode}'
    }}
    Set-Content -LiteralPath $ini.FullName -Value $txt -NoNewline
}}

@{{
    change_display_code = $dispCode
    observed_width = $dmCur.dmPelsWidth
    observed_height = $dmCur.dmPelsHeight
    observed_refresh_hz = $dmCur.dmDisplayFrequency
    mouse_trails_requested = {mouse_trails}
    mouse_trails_api_ok = $trailsOk
    fullscreen_mode_set = {fullscreen_mode}
    ini_updated_count = $inis.Count
}} | ConvertTo-Json -Compress | Set-Content -LiteralPath 'F:\p8a-tools\disp-result.json' -Encoding UTF8
"""
    qga_ps(vm_uuid, "New-Item -ItemType Directory -Force -Path 'F:\\p8a-tools' | Out-Null", timeout=20)
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as tmp:
        tmp.write(ps1_content)
        tmp_path = Path(tmp.name)
    try:
        qga_push(vm_uuid, tmp_path, r"F:\p8a-tools\configure_disp_ptr.ps1")
    finally:
        tmp_path.unlink(missing_ok=True)

    # Execute in interactive desktop session so ChangeDisplaySettingsExW & SPI_SETMOUSETRAILS apply to Session 1!
    launch = r"""
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (!$user) { throw 'No interactive desktop user' }
Remove-Item -LiteralPath 'F:\p8a-tools\disp-result.json' -ErrorAction SilentlyContinue
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File F:\p8a-tools\configure_disp_ptr.ps1'
$p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'p8a-disp-ptr' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'p8a-disp-ptr'
'launched'
"""
    qga_ps(vm_uuid, launch, timeout=25)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        exists = qga_ps(vm_uuid, "Test-Path 'F:\\p8a-tools\\disp-result.json'", timeout=15).strip().lower()
        if exists == "true":
            raw = decode_guest_text(qga_pull(vm_uuid, r"F:\p8a-tools\disp-result.json"))
            qga_ps(vm_uuid, "Unregister-ScheduledTask -TaskName 'p8a-disp-ptr' -Confirm:$false -ErrorAction SilentlyContinue", timeout=15)
            return json.loads(raw)
        time.sleep(1.0)
    raise TimeoutError("Timed out waiting for interactive display/pointer configuration")


def transfer_and_launch_installer(vm_uuid: str) -> str:
    installer = WORKSPACE_ROOT / "VALORANT_CN_installer_v2.17.4.510.exe"
    if not installer.is_file():
        raise FileNotFoundError("Official installer not found in workspace root")
    expected_sha = hashlib.sha256(installer.read_bytes()).hexdigest()

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

    handler = functools.partial(QuietHandler, directory=str(installer.parent))
    httpd = socketserver.TCPServer(("0.0.0.0", 0), handler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        gw = qga_ps(
            vm_uuid,
            "(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1 -ExpandProperty NextHop)",
            timeout=20,
        ).strip()
        dl_ps = (
            "New-Item -ItemType Directory -Force -Path 'F:\\p8a-tools' | Out-Null; "
            f"& curl.exe -sSL -o 'F:\\p8a-tools\\official_installer.exe' 'http://{gw}:{port}/{installer.name}'; "
            "(Get-FileHash -Algorithm SHA256 'F:\\p8a-tools\\official_installer.exe').Hash.ToLowerInvariant()"
        )
        actual_sha = qga_ps(vm_uuid, dl_ps, timeout=60).strip()
        if actual_sha != expected_sha:
            raise RuntimeError("Installer SHA-256 mismatch after transfer")
        launch = r"""
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (!$user) { throw 'No interactive desktop user' }
$a = New-ScheduledTaskAction -Execute 'F:\p8a-tools\official_installer.exe'
$p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'p8a-launch-installer' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'p8a-launch-installer'
'installer-launched'
"""
        qga_ps(vm_uuid, launch, timeout=25)
    finally:
        httpd.shutdown()
        httpd.server_close()
    return actual_sha


def spawn_session(name: str = "ephemeral-p8a-valorant", fullscreen_mode: int = 2, mouse_trails: int = 2) -> dict[str, Any]:
    guest_root = _external_guest_root()
    vms_dir = guest_root / "vms"
    primary = vms_dir / "Windows11-ARM64.utm"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    state_path = _session_state_path()
    if state_path.exists():
        raise RuntimeError("An active P8A session state already exists; destroy first")

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

    # Disable UTM DynamicResolution strictly to prevent Monitor info changed -> ResizeBuffers deadlock
    cfg = ggm.read_config_plist(eph_path)
    cfg.setdefault("Display", [{}])
    cfg["Display"][0]["DynamicResolution"] = False

    cache_disk = guest_root / "game-cache" / "valorant-cn-data.qcow2"
    cache_before_stat = None
    data_disk_attached = False
    if cache_disk.is_file():
        st = cache_disk.stat()
        cache_before_stat = {"size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
        clone_data_name = f"p8a-data-{uuid.uuid4().hex[:8]}.qcow2"
        clone_data_path = eph_path / "Data" / clone_data_name
        cp_res = run_cmd(["cp", "-c", str(cache_disk), str(clone_data_path)], timeout=60)
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
        data_disk_attached = True
    ggm.write_config_plist(eph_path, cfg)

    reg = run_cmd(["open", "-a", "UTM", str(eph_path)], timeout=30)
    if reg.returncode != 0:
        raise RuntimeError("Failed to register P8A clone in UTM")
    for _ in range(30):
        if ggm.utmctl_status(eph_uuid, UTMCTL) != "unregistered":
            break
        time.sleep(0.5)

    t0 = time.monotonic()
    start = run_cmd([str(UTMCTL), "start", eph_uuid], timeout=120)
    if start.returncode != 0:
        raise RuntimeError(f"Failed to start P8A clone: {analyzer.redact_p8_text(start.stderr)}")

    qga_ready_sec = None
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            if qga_ps(eph_uuid, "'p8a-ready'", timeout=15).strip() == "p8a-ready":
                qga_ready_sec = round(time.monotonic() - t0, 3)
                break
        except Exception:
            pass
        time.sleep(1.5)
    if qga_ready_sec is None:
        raise TimeoutError("Timed out waiting for QGA readiness")

    # Wait briefly for interactive desktop user logon
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        user = qga_ps(eph_uuid, "(Get-CimInstance Win32_ComputerSystem).UserName", timeout=15).strip()
        if user:
            break
        time.sleep(2.0)

    disp_res = configure_guest_display_and_pointer(
        eph_uuid, width=1280, height=720, mouse_trails=mouse_trails, fullscreen_mode=fullscreen_mode
    )
    ev_raw = qga_ps(
        eph_uuid,
        "@{Application=(Get-WinEvent -LogName Application -MaxEvents 1 -EA SilentlyContinue).RecordId;"
        "System=(Get-WinEvent -LogName System -MaxEvents 1 -EA SilentlyContinue).RecordId;"
        "CodeIntegrity=(Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 1 -EA SilentlyContinue).RecordId}|ConvertTo-Json -Compress",
        timeout=25,
    )
    ev_baseline = json.loads(ev_raw)
    installer_sha = transfer_and_launch_installer(eph_uuid)

    state = {
        "owner": "@DNPMBHC",
        "created_at_utc": analyzer.utc_now_iso(),
        "clone_name": name,
        "clone_uuid": eph_uuid,
        "ephemeral_path": str(eph_path),
        "primary_path": str(primary),
        "golden_path": str(golden),
        "dynamic_resolution_disabled": True,
        "clone_seconds": spawn_res["clone_seconds"],
        "qga_ready_seconds": qga_ready_sec,
        "display_and_pointer": disp_res,
        "eventlog_baseline_record_ids": ev_baseline,
        "installer_sha256": installer_sha,
        "data_disk_attached": data_disk_attached,
        "cache_disk_path": str(cache_disk) if data_disk_attached else None,
        "cache_before_stat": cache_before_stat,
    }
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    EVIDENCE_P8A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P8A / "spawn-preflight.json").write_text(
        json.dumps(analyzer.redact_p8_value(state), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return state


def sample_guest_lightweight(vm_uuid: str, elapsed_sec: float) -> dict[str, Any]:
    """Fast (<3s) read-only poll of VALORANT process, ACE drivers, and ShooterGame.log tail frame."""
    ps = r"""
$ErrorActionPreference = 'Continue'
$p = Get-Process -Name 'VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
$ace = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ACE' } | Select-Object Name,State,ExitCode)
$lastLine = ''
$logPath = 'F:\VALORANT_CN\Tencent Games\VALORANT\live\ShooterGame\Saved\Logs\ShooterGame.log'
if (Test-Path -LiteralPath $logPath) {
    try {
        $fs = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $seekPos = [Math]::Max(0, $len - 4096)
            $fs.Seek($seekPos, [IO.SeekOrigin]::Begin) | Out-Null
            $sr = New-Object IO.StreamReader($fs)
            $tail = $sr.ReadToEnd()
            $lines = @($tail -split "`r?`n" | Where-Object { $_ -match '^\[\d{4}\.' })
            if ($lines.Count -gt 0) { $lastLine = $lines[-1] }
        } finally { $fs.Close() }
    } catch {}
}
@{
    shipping_alive = ($null -ne $p)
    shipping_pid = if($p){$p.Id}else{$null}
    shipping_ws_mb = if($p){[math]::Round($p.WorkingSet64/1MB,2)}else{$null}
    shipping_threads = if($p){$p.Threads.Count}else{$null}
    shipping_cpu_s = if($p -and $p.CPU){[math]::Round($p.CPU,2)}else{$null}
    ace_drivers = $ace
    log_last_timestamped_line = $lastLine
} | ConvertTo-Json -Depth 4 -Compress
"""
    raw = qga_ps(vm_uuid, ps, timeout=20)
    data = json.loads(raw)
    last_frame = None
    last_ts = None
    m = re.match(r"^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})\]\[\s*(\d+)\]", str(data.get("log_last_timestamped_line", "")))
    if m:
        last_ts = m.group(1)
        last_frame = int(m.group(2))
    return {
        "captured_at_utc": analyzer.utc_now_iso(),
        "elapsed_seconds": round(elapsed_sec, 2),
        "shipping_alive": bool(data.get("shipping_alive")),
        "shipping_pid": data.get("shipping_pid"),
        "shipping_ws_mb": data.get("shipping_ws_mb"),
        "shipping_threads": data.get("shipping_threads"),
        "shipping_cpu_s": data.get("shipping_cpu_s"),
        "ace_drivers": data.get("ace_drivers", []),
        "last_frame_timestamp": last_ts,
        "last_frame_number": last_frame,
    }


def monitor_session(duration_seconds: int = 180, host_interval: float = 2.0, guest_interval: float = 15.0, label: str = "stability") -> dict[str, Any]:
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
        host_samples.append(sample_host_qemu_once(elapsed))
        if elapsed >= next_guest:
            try:
                gs = sample_guest_lightweight(vm_uuid, elapsed)
                cur_frame = gs.get("last_frame_number")
                est_fps = None
                if cur_frame is not None and prev_frame is not None and prev_t is not None:
                    dt = elapsed - prev_t
                    if dt > 0:
                        # UE4 frame counter wraps every 1000
                        df = (cur_frame - prev_frame) % 1000
                        if df > 0:
                            est_fps = round(df / dt, 2)
                gs["estimated_fps"] = est_fps
                guest_samples.append(gs)
                if cur_frame is not None:
                    prev_frame = cur_frame
                    prev_t = elapsed
            except Exception as exc:
                guest_samples.append({"elapsed_seconds": round(elapsed, 2), "poll_error": analyzer.redact_p8_text(str(exc))})
            next_guest = elapsed + guest_interval
        time.sleep(host_interval)

    # Capture delta EventLog (excluding noisy qemu-ga & TPM)
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
    ev_delta = {}
    try:
        ev_delta = json.loads(qga_ps(vm_uuid, ev_ps, timeout=25))
    except Exception as exc:
        ev_delta = {"error": analyzer.redact_p8_text(str(exc))}

    summary = analyzer.summarize_stability_series(host_samples, guest_samples)
    out = analyzer.redact_p8_value(
        {
            "owner": "@DNPMBHC",
            "label": label,
            "captured_at_utc": analyzer.utc_now_iso(),
            "summary": summary,
            "eventlog_delta": ev_delta,
            "guest_samples": guest_samples,
            "host_samples_count": len(host_samples),
        }
    )
    EVIDENCE_P8A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P8A / f"monitor-{label}.json").write_text(
        json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return out


def destroy_session() -> dict[str, Any]:
    state_path = _session_state_path()
    state = load_session_state()
    eph_path = Path(state["ephemeral_path"])
    golden = Path(state["golden_path"])
    primary = Path(state["primary_path"])
    vm_uuid = state["clone_uuid"]

    # Ensure stopped cleanly (force kill if ACE-protected game prevents ACPI shutdown)
    st = ggm.utmctl_status(vm_uuid, UTMCTL)
    if st not in ("stopped", "unregistered"):
        run_cmd([str(UTMCTL), "stop", vm_uuid, "--request"], timeout=30)
        for _ in range(12):
            if ggm.utmctl_status(vm_uuid, UTMCTL) in ("stopped", "unregistered"):
                break
            time.sleep(1.0)
        if ggm.utmctl_status(vm_uuid, UTMCTL) not in ("stopped", "unregistered"):
            run_cmd([str(UTMCTL), "stop", vm_uuid, "--kill"], timeout=30)
            time.sleep(3.0)

    res = ggm.destroy_ephemeral(
        ephemeral_path=eph_path,
        golden=golden,
        primary=primary,
        baseline_manifest_path=None,
        fast_disk_hash=True,
    )
    if GOLDEN_MANIFEST.is_file():
        base_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
        g_full = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
        p_full = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
        res["golden_readonly"] = g_full["readonly"]
        res["golden_config_sha256"] = g_full["config_sha256"]
        res["golden_bundle_sha256"] = g_full["bundle_sha256"]
        res["golden_zero_drift"] = (
            g_full["readonly"]
            and g_full["config_sha256"] == base_fp.get("golden_config_sha256")
            and g_full["bundle_sha256"] == base_fp.get("golden_bundle_sha256")
        )
        res["primary_vm_a_config_sha256"] = p_full["config_sha256"]
        res["primary_vm_a_bundle_sha256"] = p_full["bundle_sha256"]
        res["primary_zero_drift"] = (
            p_full["config_sha256"] == base_fp.get("primary_vm_a_config_sha256")
            and p_full["bundle_sha256"] == base_fp.get("primary_vm_a_bundle_sha256")
        )

    cache_unchanged = None
    if state.get("cache_disk_path") and state.get("cache_before_stat"):
        cd = Path(state["cache_disk_path"])
        c_st = cd.stat()
        before = state["cache_before_stat"]
        cache_unchanged = (c_st.st_size == before["size_bytes"] and c_st.st_mtime_ns == before["mtime_ns"])
    res["cache_disk_untouched"] = cache_unchanged
    state_path.unlink(missing_ok=True)
    EVIDENCE_P8A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P8A / "zero-drift-proof.json").write_text(
        json.dumps(analyzer.redact_p8_value(res), indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return res


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 8A Golden Guest session tool (@DNPMBHC)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_spawn = sub.add_parser("spawn")
    p_spawn.add_argument("--name", default="ephemeral-p8a-valorant")
    p_spawn.add_argument("--fullscreen-mode", type=int, default=2)
    p_spawn.add_argument("--mouse-trails", type=int, default=2)

    p_ptr = sub.add_parser("pointer-mode")
    p_ptr.add_argument("--mouse-trails", type=int, default=2)
    p_ptr.add_argument("--fullscreen-mode", type=int, default=2)

    p_mon = sub.add_parser("monitor")
    p_mon.add_argument("--duration-seconds", type=int, default=180)
    p_mon.add_argument("--label", default="stability")

    sub.add_parser("destroy")

    args = parser.parse_args(argv)
    if args.cmd == "spawn":
        out = spawn_session(name=args.name, fullscreen_mode=args.fullscreen_mode, mouse_trails=args.mouse_trails)
    elif args.cmd == "pointer-mode":
        st = load_session_state()
        out = configure_guest_display_and_pointer(
            st["clone_uuid"], width=1280, height=720, mouse_trails=args.mouse_trails, fullscreen_mode=args.fullscreen_mode
        )
    elif args.cmd == "monitor":
        out = monitor_session(duration_seconds=args.duration_seconds, label=args.label)
    elif args.cmd == "destroy":
        out = destroy_session()
    else:
        raise RuntimeError(f"Unknown command: {args.cmd}")
    print(json.dumps(analyzer.redact_p8_value(out), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
