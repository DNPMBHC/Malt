#!/usr/bin/env python3
"""Phase 11A v2 vs v3 large-scene CPU/memory VM performance benchmark & analyzer.

Owner: @DNPMBHC
Compliance:
- Uses golden_guest_manager.py spawn-ephemeral / destroy-ephemeral strictly.
- Preserves golden-win11-arm64-v1 and primary vm-a with full-disk SHA-256 zero-drift verification.
- Runs single VM at a time to prevent host resource contention.
- Never weakens Secure Boot, TPM, BCD, Code Integrity, Prism, or anti-cheat drivers.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import time
from typing import Any

import golden_guest_manager as ggm
import p8_valorant_session as p8s
import p9_valorant_session as p9s
import p10_valorant_session as p10s

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent
EVIDENCE_P11A = WORKSPACE_ROOT / "handoff/phase-11/evidence/p11-a"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
OPT_APPLY = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"
OPT_ROLLBACK = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/rollback-optimizer.ps1"
OPT_PROFILE_V3 = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")

UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact_p11_text(text: str) -> str:
    if not text:
        return ""
    user_name = os.environ.get("USER") or Path.home().name
    out = str(text)
    out = out.replace(str(WORKSPACE_ROOT), "<workspace>")
    out = out.replace(str(WORKSPACE_ROOT).replace("/", "\\"), "<workspace>")
    out = out.replace(str(Path.home()), "<home>")
    if WORKSPACE_ROOT.name:
        out = out.replace(WORKSPACE_ROOT.name, "my-project")
    out = re.sub(r"/Volumes/[^/\s\"'<>`]+", "/Volumes/<EXTERNAL_VOLUME>", out)
    out = re.sub(r"(?:[A-Z]:)?[/\\]Users[/\\][^/\\\s\"'<>]+", "<local-user-dir>", out, flags=re.IGNORECASE)
    out = UUID_RE.sub("<uuid>", out)
    if user_name:
        out = re.sub(r"(?<![\w@])" + re.escape(user_name) + r"(?!\w)", "user-x", out, flags=re.IGNORECASE)
    return out


def redact_p11_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p11_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p11_value(v) for v in value]
    if isinstance(value, str):
        return redact_p11_text(value)
    return value


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if pct <= 0.0:
        return round(ordered[0], 3)
    if pct >= 100.0:
        return round(ordered[-1], 3)
    idx = (len(ordered) - 1) * (pct / 100.0)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return round(ordered[lo], 3)
    frac = idx - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def summarize_series(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"mean": None, "p50": None, "p95": None, "p99": None, "p99_9": None, "min": None, "max": None}
    return {
        "mean": round(statistics.mean(values), 3),
        "p50": percentile(values, 50.0),
        "p95": percentile(values, 95.0),
        "p99": percentile(values, 99.0),
        "p99_9": percentile(values, 99.9),
        "min": round(min(values), 3),
        "max": round(max(values), 3),
    }


def parse_d3d11_probe_csv(csv_text: str) -> dict[str, Any]:
    """Parse d3d11_probe CSV into FPS (mean/P50/P1 Low/P0.1 Low) and CPU/GPU frame timings."""
    reader = csv.DictReader(io.StringIO(csv_text.strip()))
    frame_ms: list[float] = []
    submit_ms: list[float] = []
    gpu_ms: list[float] = []
    for row in reader:
        try:
            f_val = float(row["cpu_frame_ms"])
            s_val = float(row["cpu_submit_ms"])
            if f_val > 0 and math.isfinite(f_val):
                frame_ms.append(f_val)
            if s_val >= 0 and math.isfinite(s_val):
                submit_ms.append(s_val)
            g_raw = row.get("gpu_ms", "")
            if g_raw not in ("", "nan", "NaN", "None", None):
                g_val = float(g_raw)
                if math.isfinite(g_val) and g_val >= 0:
                    gpu_ms.append(g_val)
        except (KeyError, TypeError, ValueError):
            continue

    if not frame_ms:
        raise ValueError("No valid measured frames found in d3d11_probe CSV")

    frame_stats = summarize_series(frame_ms)
    submit_stats = summarize_series(submit_ms)
    gpu_stats = summarize_series(gpu_ms)

    fps_vals = [1000.0 / f for f in frame_ms if f > 0]
    p99_f = frame_stats["p99"]
    p99_9_f = frame_stats["p99_9"]
    mean_f = frame_stats["mean"]
    p50_f = frame_stats["p50"]

    return {
        "frame_count": len(frame_ms),
        "fps": {
            "mean": round(1000.0 / mean_f, 3) if mean_f and mean_f > 0 else None,
            "p50": round(1000.0 / p50_f, 3) if p50_f and p50_f > 0 else None,
            "p1_low": round(1000.0 / p99_f, 3) if p99_f and p99_f > 0 else None,
            "p0_1_low": round(1000.0 / p99_9_f, 3) if p99_9_f and p99_9_f > 0 else None,
            "min": round(min(fps_vals), 3),
            "max": round(max(fps_vals), 3),
        },
        "cpu_frame_ms": frame_stats,
        "cpu_submit_ms": submit_stats,
        "gpu_ms": gpu_stats,
    }


def summarize_host_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    render_cpu = [float(s["qemu_render_server_cpu"]) for s in samples if "qemu_render_server_cpu" in s]
    worker_cpu = [float(s["qemu_worker_cpu"]) for s in samples if "qemu_worker_cpu" in s]
    rss_mib = [float(s["total_hypervisor_rss_mib"]) for s in samples if "total_hypervisor_rss_mib" in s]
    return {
        "sample_count": len(samples),
        "qemu_render_server_cpu": summarize_series(render_cpu),
        "qemu_worker_cpu": summarize_series(worker_cpu),
        "total_hypervisor_rss_mib": summarize_series(rss_mib),
    }


def _pct_delta(before: float | None, after: float | None) -> float | None:
    if before is None or after is None or before == 0:
        return None
    return round(((after - before) / abs(before)) * 100.0, 2)


def select_best_memory_compression(
    preserve_arm: dict[str, Any],
    disable_arm: dict[str, Any],
) -> dict[str, Any]:
    """Select optimal MemoryCompression mode based on P1 Low FPS, CPU submit ms, and peak host RSS."""
    p_p1 = preserve_arm.get("probe", {}).get("fps", {}).get("p1_low") or 0.0
    d_p1 = disable_arm.get("probe", {}).get("fps", {}).get("p1_low") or 0.0
    p_sub = preserve_arm.get("probe", {}).get("cpu_submit_ms", {}).get("mean") or 999.0
    d_sub = disable_arm.get("probe", {}).get("cpu_submit_ms", {}).get("mean") or 999.0
    p_rss = preserve_arm.get("host", {}).get("total_hypervisor_rss_mib", {}).get("max") or 0.0
    d_rss = disable_arm.get("host", {}).get("total_hypervisor_rss_mib", {}).get("max") or 0.0

    # Prefer disable if it improves P1 Low by >= 2% without blowing peak host RSS by > 8%,
    # or improves CPU submit latency by >= 3% with neutral/better P1 Low.
    p1_gain_pct = _pct_delta(p_p1, d_p1) or 0.0
    rss_delta_pct = _pct_delta(p_rss, d_rss) or 0.0
    sub_delta_pct = _pct_delta(p_sub, d_sub) or 0.0

    if (p1_gain_pct >= 2.0 and rss_delta_pct <= 8.0) or (sub_delta_pct <= -3.0 and p1_gain_pct >= -1.0 and rss_delta_pct <= 8.0):
        selected = "disable"
        reason = (
            f"disable improved P1 Low by {p1_gain_pct:+.2f}% and CPU submit by {sub_delta_pct:+.2f}% "
            f"with peak host RSS delta {rss_delta_pct:+.2f}%"
        )
    else:
        selected = "preserve"
        reason = (
            f"preserve retained equal/better stability or lower peak RSS "
            f"(disable P1 Low delta {p1_gain_pct:+.2f}%, CPU submit delta {sub_delta_pct:+.2f}%, peak RSS delta {rss_delta_pct:+.2f}%)"
        )

    return {
        "selected_mode": selected,
        "reason": reason,
        "preserve_p1_low_fps": p_p1,
        "disable_p1_low_fps": d_p1,
        "p1_low_delta_pct_disable_vs_preserve": p1_gain_pct,
        "preserve_peak_host_rss_mib": p_rss,
        "disable_peak_host_rss_mib": d_rss,
        "peak_host_rss_delta_pct_disable_vs_preserve": rss_delta_pct,
        "preserve_cpu_submit_mean_ms": p_sub,
        "disable_cpu_submit_mean_ms": d_sub,
    }


def compare_v2_vs_v3(v2_arm: dict[str, Any], v3_arm: dict[str, Any]) -> dict[str, Any]:
    v2_fps = v2_arm.get("probe", {}).get("fps", {})
    v3_fps = v3_arm.get("probe", {}).get("fps", {})
    v2_sub = v2_arm.get("probe", {}).get("cpu_submit_ms", {})
    v3_sub = v3_arm.get("probe", {}).get("cpu_submit_ms", {})
    v2_host = v2_arm.get("host", {})
    v3_host = v3_arm.get("host", {})
    v2_guest = v2_arm.get("guest", {})
    v3_guest = v3_arm.get("guest", {})

    return {
        "fps_mean_delta_pct": _pct_delta(v2_fps.get("mean"), v3_fps.get("mean")),
        "fps_p50_delta_pct": _pct_delta(v2_fps.get("p50"), v3_fps.get("p50")),
        "fps_p1_low_delta_pct": _pct_delta(v2_fps.get("p1_low"), v3_fps.get("p1_low")),
        "fps_p0_1_low_delta_pct": _pct_delta(v2_fps.get("p0_1_low"), v3_fps.get("p0_1_low")),
        "cpu_submit_mean_ms_delta_pct": _pct_delta(v2_sub.get("mean"), v3_sub.get("mean")),
        "qemu_worker_cpu_mean_delta_pct": _pct_delta(
            v2_host.get("qemu_worker_cpu", {}).get("mean"),
            v3_host.get("qemu_worker_cpu", {}).get("mean"),
        ),
        "qemu_render_server_cpu_mean_delta_pct": _pct_delta(
            v2_host.get("qemu_render_server_cpu", {}).get("mean"),
            v3_host.get("qemu_render_server_cpu", {}).get("mean"),
        ),
        "host_rss_peak_mib_delta_pct": _pct_delta(
            v2_host.get("total_hypervisor_rss_mib", {}).get("max"),
            v3_host.get("total_hypervisor_rss_mib", {}).get("max"),
        ),
        "v2_event26_count": v2_guest.get("event26_count"),
        "v3_event26_count": v3_guest.get("event26_count"),
        "v3_sound_ready": v3_guest.get("sound_ready"),
        "v3_zh_cn_ime_ready": v3_guest.get("zh_cn_ime_ready"),
        "v3_update_services_paused": v3_guest.get("update_services_paused"),
    }


def _external_guest_root() -> Path:
    volumes = Path("/Volumes")
    if volumes.is_dir():
        for vol in sorted(volumes.iterdir()):
            candidate = vol / "whisky-phase2-guest"
            if candidate.is_dir():
                return candidate
    raise RuntimeError("External whisky-phase2-guest volume is not mounted")


def _wait_for_qga_and_user(vm_uuid: str, timeout_s: float = 180.0) -> float:
    t0 = time.monotonic()
    deadline = t0 + timeout_s
    while time.monotonic() < deadline:
        try:
            if p9s.qga_ps(vm_uuid, "'p11a-ready'", timeout=15).strip() == "p11a-ready":
                ready_s = round(time.monotonic() - t0, 3)
                # Wait briefly for interactive desktop session
                u_dl = time.monotonic() + 45.0
                while time.monotonic() < u_dl:
                    if p9s.qga_ps(vm_uuid, "(Get-CimInstance Win32_ComputerSystem).UserName", timeout=15).strip():
                        break
                    time.sleep(1.5)
                return ready_s
        except Exception:
            pass
        time.sleep(1.5)
    raise TimeoutError("Timed out waiting for QGA readiness")


def _collect_guest_health_and_memory(vm_uuid: str) -> dict[str, Any]:
    ps = r"""
$ErrorActionPreference = 'Continue'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$perfMem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -EA SilentlyContinue
$snd = @(Get-CimInstance Win32_SoundDevice -EA SilentlyContinue | Select-Object Name,Status,Manufacturer)
$e26 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=26} -MaxEvents 20 -EA SilentlyContinue | Where-Object { $_.Message -match 'Virtual Memory' })
$upd = @(Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object { $_.Name -in @('wuauserv','UsoSvc','BITS','TrustedInstaller') } | Select-Object Name,StartMode,State)
$pf = @(Get-CimInstance Win32_PageFileSetting -EA SilentlyContinue | Select-Object Name,InitialSize,MaximumSize)
$prio = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -EA SilentlyContinue).Win32PrioritySeparation
$mc = $null
try { $mc = [bool](Get-MMAgent -EA SilentlyContinue).MemoryCompression } catch { }
$sysLoc = (Get-WinSystemLocale -EA SilentlyContinue).Name

$locOut = 'C:\graphics-lab\p11a\loc-check.json'
New-Item -ItemType Directory -Force -Path 'C:\graphics-lab\p11a' | Out-Null
$locBody = @"
`$ErrorActionPreference = 'Continue'
`$rawList = Get-WinUserLanguageList -EA SilentlyContinue
`$l = @()
foreach (`$item in `$rawList) {
    `$l += @{ tag = [string]`$item.LanguageTag; tips = @(`$item.InputMethodTips) }
}
@{ langs=`$l; ui=(Get-WinUILanguageOverride -EA SilentlyContinue).Name; culture=(Get-Culture -EA SilentlyContinue).Name } | ConvertTo-Json -Depth 5 -Compress | Set-Content -Encoding UTF8 -LiteralPath '$locOut'
"@
Set-Content -LiteralPath 'C:\graphics-lab\p11a\loc-check.ps1' -Value $locBody -Encoding UTF8
if (Test-Path $locOut) { Remove-Item $locOut -Force -EA SilentlyContinue }
$u = $cs.UserName
if ($u) {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\graphics-lab\p11a\loc-check.ps1'
    $princ = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
    Register-ScheduledTask -TaskName 'P11A_CheckLoc' -Action $act -Principal $princ -Force | Out-Null
    Start-ScheduledTask -TaskName 'P11A_CheckLoc'
    for ($i = 0; $i -lt 16; $i++) { if (Test-Path $locOut) { break }; Start-Sleep -Milliseconds 500 }
    Unregister-ScheduledTask -TaskName 'P11A_CheckLoc' -Confirm:$false -EA SilentlyContinue
}
$locData = if (Test-Path $locOut) { Get-Content -Raw $locOut | ConvertFrom-Json } else { $null }

@{
    total_visible_memory_mib = [math]::Round($os.TotalVisibleMemorySize / 1024.0, 2)
    free_physical_memory_mib = [math]::Round($os.FreePhysicalMemory / 1024.0, 2)
    committed_mib = if ($perfMem) { [math]::Round($perfMem.CommittedBytes / 1MB, 2) } else { $null }
    commit_limit_mib = if ($perfMem) { [math]::Round($perfMem.CommitLimit / 1MB, 2) } else { $null }
    page_faults_per_sec = if ($perfMem) { [int]$perfMem.PageFaultsPersec } else { $null }
    automatic_managed_pagefile = [bool]$cs.AutomaticManagedPagefile
    pagefile_settings = $pf
    event26_count = $e26.Count
    sound_devices = $snd
    sound_ready = (@($snd | Where-Object { $_.Status -eq 'OK' }).Count -gt 0)
    update_services = $upd
    update_services_paused = (@($upd | Where-Object { $_.State -eq 'Running' }).Count -eq 0)
    win32_priority_separation = if ($null -ne $prio) { [int]$prio } else { $null }
    memory_compression = $mc
    system_locale = $sysLoc
    interactive_locale = $locData
} | ConvertTo-Json -Depth 6 -Compress
"""
    data = json.loads(p9s.qga_ps(vm_uuid, ps, timeout=30))
    langs = ((data.get("interactive_locale") or {}).get("langs") or [])
    first_tag_raw = langs[0].get("tag", "") if langs else ""
    if isinstance(first_tag_raw, list):
        first_tag = str(first_tag_raw[0]) if first_tag_raw else ""
    else:
        first_tag = str(first_tag_raw)
    data["zh_cn_ime_ready"] = first_tag.lower().startswith("zh-")
    return data


def _run_d3d11_large_scene_probe(
    vm_uuid: str,
    *,
    frames: int = 180,
    warmup: int = 30,
    commands: int = 4096,
    resource_bytes: int = 262144,
    label: str = "arm",
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Run d3d11_probe.exe in interactive desktop session while sampling host QEMU CPU & RSS."""
    csv_guest = f"C:\\graphics-lab\\p11a\\probe-{label}.csv"
    done_guest = f"C:\\graphics-lab\\p11a\\probe-{label}.done"
    err_guest = f"C:\\graphics-lab\\p11a\\probe-{label}.err"
    ps_launch = f"""
New-Item -ItemType Directory -Force -Path 'C:\\graphics-lab\\p11a' | Out-Null
Remove-Item -LiteralPath '{csv_guest}','{done_guest}','{err_guest}' -Force -EA SilentlyContinue
$runner = @"
`$ErrorActionPreference = 'Continue'
& 'C:\\graphics-lab\\p11a\\d3d11_probe.exe' --frames {frames} --warmup {warmup} --width 1280 --height 720 --commands {commands} --command-every 1 --resource-bytes {resource_bytes} --resource-every 1 --driver-type hardware --csv '{csv_guest}' 2> '{err_guest}'
'exit=' + `$LASTEXITCODE | Set-Content -Encoding ASCII -LiteralPath '{done_guest}'
"@
Set-Content -LiteralPath 'C:\\graphics-lab\\p11a\\run-probe.ps1' -Value $runner -Encoding UTF8
$u = (Get-CimInstance Win32_ComputerSystem).UserName
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\graphics-lab\\p11a\\run-probe.ps1'
$princ = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
Register-ScheduledTask -TaskName 'P11A_RunProbe' -Action $act -Principal $princ -Force | Out-Null
Start-ScheduledTask -TaskName 'P11A_RunProbe'
'launched'
"""
    p9s.qga_ps(vm_uuid, ps_launch, timeout=25)

    host_samples: list[dict[str, Any]] = []
    t0 = time.monotonic()
    deadline = t0 + 180.0
    done_marker = ""
    while time.monotonic() < deadline:
        elapsed = time.monotonic() - t0
        host_samples.append(p8s.sample_host_qemu_once(elapsed))
        if len(host_samples) % 2 == 0:
            try:
                chk = p9s.qga_ps(
                    vm_uuid,
                    f"if (Test-Path '{done_guest}') {{ Get-Content -Raw '{done_guest}' }} else {{ 'RUNNING' }}",
                    timeout=15,
                ).strip()
                if chk != "RUNNING":
                    done_marker = chk
                    break
            except Exception:
                pass
        time.sleep(1.0)

    p9s.qga_ps(vm_uuid, "Unregister-ScheduledTask -TaskName 'P11A_RunProbe' -Confirm:$false -EA SilentlyContinue", timeout=15)
    if not done_marker:
        raise TimeoutError(f"d3d11_probe timed out for arm '{label}'")

    # Pull CSV via utmctl file pull
    pull_res = subprocess.run(
        [str(UTMCTL), "file", "pull", vm_uuid, csv_guest],
        capture_output=True,
        timeout=30,
    )
    if pull_res.returncode != 0 or not pull_res.stdout:
        raise RuntimeError(f"Failed to pull probe CSV for arm '{label}': {done_marker}")
    csv_text = pull_res.stdout.decode("utf-8", errors="replace")
    probe_summary = parse_d3d11_probe_csv(csv_text)
    probe_summary["done_marker"] = done_marker
    probe_summary["workload"] = {
        "frames": frames,
        "warmup": warmup,
        "width": 1280,
        "height": 720,
        "commands_per_frame": commands,
        "resource_bytes_per_frame": resource_bytes,
    }
    return probe_summary, summarize_host_samples(host_samples)


def _boot_ephemeral_clone(
    *,
    golden: Path,
    primary: Path,
    vms_dir: Path,
    name: str,
    trim_hardware: bool,
    no_sound: bool,
    ram_mb: int | None,
    vcpu: int | None,
    disable_balloon: bool,
) -> tuple[dict[str, Any], float]:
    spawn_res = ggm.spawn_ephemeral(
        golden=golden,
        dest_dir=vms_dir,
        name=name,
        primary=primary,
        register_utm=True,
        fast_disk_hash=True,
        trim_hardware=trim_hardware,
        no_sound=no_sound,
        dx_driver="DXMT",
        fps_limit=120,
        ram_mb=ram_mb,
        vcpu=vcpu,
        disable_balloon=disable_balloon,
    )
    vm_uuid = spawn_res["clone_uuid"]
    start_res = subprocess.run([str(UTMCTL), "start", vm_uuid], capture_output=True, text=True, timeout=120)
    if start_res.returncode != 0:
        raise RuntimeError(f"Failed to start clone {name}: {redact_p11_text(start_res.stderr)}")
    qga_s = _wait_for_qga_and_user(vm_uuid)
    p9s.qga_ps(vm_uuid, "New-Item -ItemType Directory -Force -Path 'C:\\graphics-lab\\p11a' | Out-Null", timeout=20)
    # Reuse pre-seeded d3d11_probe.exe in golden guest if SHA-256 matches, else fast HTTP transfer
    local_sha = ggm.sha256_file(D3D11_PROBE).lower()
    chk_ps = (
        "$p='C:\\graphics-lab\\d3d11_probe.exe';"
        "if(Test-Path $p){(Get-FileHash -Algorithm SHA256 $p).Hash.ToLowerInvariant()}else{'MISSING'}"
    )
    remote_sha = p9s.qga_ps(vm_uuid, chk_ps, timeout=20).strip().lower()
    if remote_sha == local_sha:
        p9s.qga_ps(
            vm_uuid,
            "Copy-Item -LiteralPath 'C:\\graphics-lab\\d3d11_probe.exe' -Destination 'C:\\graphics-lab\\p11a\\d3d11_probe.exe' -Force",
            timeout=20,
        )
    else:
        # Fast HTTP transfer over virtual NAT gateway (never push 13MB over serial QGA)
        import http.server
        import socketserver
        import threading

        class _SingleHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                data = D3D11_PROBE.read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, fmt: str, *args: Any) -> None:
                return

        srv = socketserver.TCPServer(("0.0.0.0", 0), _SingleHandler)
        port = srv.server_address[1]
        th = threading.Thread(target=srv.serve_forever, daemon=True)
        th.start()
        try:
            gw_ps = "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop"
            gw = p9s.qga_ps(vm_uuid, gw_ps, timeout=15).strip()
            dl_ps = (
                f"& curl.exe -fsSL 'http://{gw}:{port}/d3d11_probe.exe' -o 'C:\\graphics-lab\\p11a\\d3d11_probe.exe';"
                "(Get-FileHash -Algorithm SHA256 'C:\\graphics-lab\\p11a\\d3d11_probe.exe').Hash.ToLowerInvariant()"
            )
            dl_sha = p9s.qga_ps(vm_uuid, dl_ps, timeout=60).strip().lower()
            if dl_sha != local_sha:
                raise RuntimeError(f"d3d11_probe.exe SHA-256 mismatch after HTTP transfer: {dl_sha}")
        finally:
            srv.shutdown()
            srv.server_close()
    return spawn_res, qga_s


def _stop_and_destroy_clone(eph_path: Path, vm_uuid: str, golden: Path, primary: Path) -> None:
    st = ggm.utmctl_status(vm_uuid, UTMCTL)
    if st not in ("stopped", "unregistered"):
        subprocess.run([str(UTMCTL), "stop", vm_uuid, "--request"], capture_output=True, text=True, timeout=20)
        for _ in range(15):
            if ggm.utmctl_status(vm_uuid, UTMCTL) in ("stopped", "unregistered"):
                break
            time.sleep(1.0)
        if ggm.utmctl_status(vm_uuid, UTMCTL) not in ("stopped", "unregistered"):
            subprocess.run([str(UTMCTL), "stop", vm_uuid, "--kill"], capture_output=True, text=True, timeout=20)
            time.sleep(3.0)
    ggm.destroy_ephemeral(
        ephemeral_path=eph_path,
        golden=golden,
        primary=primary,
        baseline_manifest_path=None,
        fast_disk_hash=True,
    )


def run_live_v2_vs_v3_benchmark(
    *,
    frames: int = 180,
    warmup: int = 30,
    commands: int = 4096,
    resource_bytes: int = 262144,
    v3_ram_mb: int = 8192,
    v3_vcpu: int | None = None,
) -> dict[str, Any]:
    guest_root = _external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    if not D3D11_PROBE.is_file():
        raise FileNotFoundError("Missing graphics-lab/build/d3d11_probe.exe")

    p_cores = v3_vcpu if v3_vcpu is not None else ggm.detect_recommended_vcpu()
    utm_prefs = p10s.set_utm_dxmt_and_fps(dx_driver_int=2, fps_limit=120)

    arm_v2: dict[str, Any] = {}
    arm_v3_preserve: dict[str, Any] = {}
    arm_v3_disable: dict[str, Any] = {}
    rollback_report: dict[str, Any] = {}

    try:
        # --- Arm A: v2 baseline (golden default 6 vCPU / 6144 MiB, Balloon=True, no-sound like Phase 10A) ---
        sp_v2, qga_v2 = _boot_ephemeral_clone(
            golden=golden,
            primary=primary,
            vms_dir=vms_dir,
            name="ephemeral-p11a-v2-base",
            trim_hardware=True,
            no_sound=True,
            ram_mb=None,
            vcpu=None,
            disable_balloon=False,
        )
        try:
            uid_v2 = sp_v2["clone_uuid"]
            render_v2 = p9s.inspect_render_server_frameworks().get("overall")
            probe_v2, host_v2 = _run_d3d11_large_scene_probe(
                uid_v2, frames=frames, warmup=warmup, commands=commands, resource_bytes=resource_bytes, label="v2"
            )
            guest_v2 = _collect_guest_health_and_memory(uid_v2)
            arm_v2 = {
                "arm_id": "v2_baseline",
                "clone_seconds": sp_v2["clone_seconds"],
                "qga_ready_seconds": qga_v2,
                "trim_summary": sp_v2["trim_summary"],
                "render_server_backend": render_v2,
                "probe": probe_v2,
                "host": host_v2,
                "guest": guest_v2,
            }
        finally:
            _stop_and_destroy_clone(Path(sp_v2["ephemeral_path"]), sp_v2["clone_uuid"], golden, primary)

        # --- Arm B: v3 optimized (8192 MiB RAM, P-Core matched vCPU, Balloon=False, intel-hda sound retained, optimizer v3) ---
        sp_v3, qga_v3 = _boot_ephemeral_clone(
            golden=golden,
            primary=primary,
            vms_dir=vms_dir,
            name="ephemeral-p11a-v3-opt",
            trim_hardware=True,
            no_sound=False,
            ram_mb=v3_ram_mb,
            vcpu=p_cores,
            disable_balloon=True,
        )
        try:
            uid_v3 = sp_v3["clone_uuid"]
            p9s.qga_push(uid_v3, OPT_APPLY, r"C:\graphics-lab\p11a\apply-optimizer.ps1")
            p9s.qga_push(uid_v3, OPT_ROLLBACK, r"C:\graphics-lab\p11a\rollback-optimizer.ps1")
            p9s.qga_push(uid_v3, OPT_PROFILE_V3, r"C:\graphics-lab\p11a\anticheat-minimal-win11-arm64.json")

            # B1: v3 with MemoryCompression=preserve
            apply_p_raw = p9s.qga_ps(
                uid_v3,
                "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\graphics-lab\\p11a\\apply-optimizer.ps1' "
                "-ProfilePath 'C:\\graphics-lab\\p11a\\anticheat-minimal-win11-arm64.json' "
                "-MemoryCompressionOverride preserve",
                timeout=90,
            )
            apply_p_report = json.loads(apply_p_raw)
            render_v3 = p9s.inspect_render_server_frameworks().get("overall")
            probe_v3_p, host_v3_p = _run_d3d11_large_scene_probe(
                uid_v3, frames=frames, warmup=warmup, commands=commands, resource_bytes=resource_bytes, label="v3-mc-preserve"
            )
            guest_v3_p = _collect_guest_health_and_memory(uid_v3)
            arm_v3_preserve = {
                "arm_id": "v3_memory_compression_preserve",
                "clone_seconds": sp_v3["clone_seconds"],
                "qga_ready_seconds": qga_v3,
                "trim_summary": sp_v3["trim_summary"],
                "render_server_backend": render_v3,
                "optimizer_apply_summary": {
                    "profile_revision": apply_p_report.get("profile_revision"),
                    "security_invariants_passed": apply_p_report.get("security_invariants_passed"),
                    "gaming_session": (apply_p_report.get("changes") or {}).get("gaming_session"),
                },
                "probe": probe_v3_p,
                "host": host_v3_p,
                "guest": guest_v3_p,
            }

            # B2: v3 with MemoryCompression=disable (A/B comparison on same v3 clone)
            apply_d_raw = p9s.qga_ps(
                uid_v3,
                "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\graphics-lab\\p11a\\apply-optimizer.ps1' "
                "-ProfilePath 'C:\\graphics-lab\\p11a\\anticheat-minimal-win11-arm64.json' "
                "-MemoryCompressionOverride disable",
                timeout=90,
            )
            apply_d_report = json.loads(apply_d_raw)
            probe_v3_d, host_v3_d = _run_d3d11_large_scene_probe(
                uid_v3, frames=frames, warmup=warmup, commands=commands, resource_bytes=resource_bytes, label="v3-mc-disable"
            )
            guest_v3_d = _collect_guest_health_and_memory(uid_v3)
            arm_v3_disable = {
                "arm_id": "v3_memory_compression_disable",
                "trim_summary": sp_v3["trim_summary"],
                "render_server_backend": render_v3,
                "optimizer_apply_summary": {
                    "profile_revision": apply_d_report.get("profile_revision"),
                    "security_invariants_passed": apply_d_report.get("security_invariants_passed"),
                    "gaming_session": (apply_d_report.get("changes") or {}).get("gaming_session"),
                },
                "probe": probe_v3_d,
                "host": host_v3_d,
                "guest": guest_v3_d,
            }

            # Verify one-click lossless rollback consistency
            rb_raw = p9s.qga_ps(
                uid_v3,
                "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\graphics-lab\\p11a\\rollback-optimizer.ps1' "
                "-ProfilePath 'C:\\graphics-lab\\p11a\\anticheat-minimal-win11-arm64.json'",
                timeout=90,
            )
            rb_full = json.loads(rb_raw)
            rollback_report = {
                "rollback_consistent": rb_full.get("rollback_consistent"),
                "mismatch_count": rb_full.get("mismatch_count"),
                "mismatches": rb_full.get("mismatches"),
                "security_invariants_passed": rb_full.get("security_invariants_passed"),
                "restored_gaming_session": (rb_full.get("restored") or {}).get("gaming_session"),
            }
        finally:
            _stop_and_destroy_clone(Path(sp_v3["ephemeral_path"]), sp_v3["clone_uuid"], golden, primary)
    finally:
        restore_res = p10s.restore_utm_prefs()

    # Full-disk SHA-256 zero-drift verification on golden and primary vm-a
    base_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
    g_full = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
    p_full = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
    drift = {
        "utm_defaults_restored": bool(restore_res.get("restored", False)),
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
    }

    mc_decision = select_best_memory_compression(arm_v3_preserve, arm_v3_disable)
    winning_v3 = arm_v3_disable if mc_decision["selected_mode"] == "disable" else arm_v3_preserve
    comparison = compare_v2_vs_v3(arm_v2, winning_v3)

    manifest_sha = hashlib.sha256(GOLDEN_MANIFEST.read_bytes()).hexdigest()
    benchmark_doc = redact_p11_value(
        {
            "schema_version": 1,
            "phase": "phase-11a",
            "owner": "@DNPMBHC",
            "captured_at_utc": utc_now_iso(),
            "golden_id": "golden-win11-arm64-v1",
            "golden_manifest_sha256": manifest_sha,
            "host_p_core_count": ggm.detect_apple_silicon_p_cores(),
            "utm_prefs_during_run": utm_prefs,
            "workload": {
                "probe": "d3d11_probe.exe",
                "resolution": "1280x720",
                "frames": frames,
                "warmup": warmup,
                "commands_per_frame": commands,
                "resource_bytes_per_frame": resource_bytes,
            },
            "arms": {
                "v2_baseline": arm_v2,
                "v3_memory_compression_preserve": arm_v3_preserve,
                "v3_memory_compression_disable": arm_v3_disable,
            },
            "memory_compression_decision": mc_decision,
            "v2_vs_v3_comparison": comparison,
            "rollback_verification": rollback_report,
            "zero_drift_verification": drift,
        }
    )

    EVIDENCE_P11A.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_P11A / "vm-v3-cpu-memory-benchmark.json").write_text(
        json.dumps(benchmark_doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (EVIDENCE_P11A / "zero-drift-proof.json").write_text(
        json.dumps(redact_p11_value(drift), indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return benchmark_doc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 11A v2 vs v3 VM CPU/Memory benchmark (@DNPMBHC)")
    parser.add_argument("--frames", type=int, default=180)
    parser.add_argument("--warmup", type=int, default=30)
    parser.add_argument("--commands", type=int, default=4096)
    parser.add_argument("--resource-bytes", type=int, default=262144)
    parser.add_argument("--v3-ram-mb", type=int, choices=ggm.ALLOWED_RAM_MB, default=8192)
    parser.add_argument("--v3-vcpu", type=int, default=None)
    args = parser.parse_args(argv)

    out = run_live_v2_vs_v3_benchmark(
        frames=args.frames,
        warmup=args.warmup,
        commands=args.commands,
        resource_bytes=args.resource_bytes,
        v3_ram_mb=args.v3_ram_mb,
        v3_vcpu=args.v3_vcpu,
    )
    print(json.dumps(out["v2_vs_v3_comparison"], indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
