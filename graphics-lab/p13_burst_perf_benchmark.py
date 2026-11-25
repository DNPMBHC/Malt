#!/usr/bin/env python3
"""Phase 13A burst-effect frame pacing benchmark, warm-standby fast-launch A/B,
Kiosk desktop-less shell verification, and full-disk SHA-256 zero-drift proof.

Owner: @DNPMBHC
Compliance:
- Uses golden_guest_manager.py spawn-ephemeral / destroy-ephemeral strictly.
- Preserves sealed golden-win11-arm64-v1, primary cold-backup vm-a, and /Applications/UTM.app.
- Runs a single VM at a time; zero CPUID/SMBIOS/ACPI/TPM/Hypervisor spoofing.
- Zero DWM hooking, zero process injection, zero modification of game/ACE/Windows drivers.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from typing import Any

import golden_guest_manager as ggm
import p9_valorant_session as p9s
import p11_vm_perf_benchmark as p11b
import p12_cpu_net_benchmark as p12b

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent
EVIDENCE_P13A = WORKSPACE_ROOT / "handoff/phase-13/evidence/p13-a"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
OPT_APPLY = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"
OPT_PROFILE = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
KIOSK_SCRIPT = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/kiosk-app-shell.ps1"
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")

UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact_p13_text(text: str) -> str:
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


def redact_p13_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p13_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p13_value(v) for v in value]
    if isinstance(value, str):
        return redact_p13_text(value)
    return value


def pct_delta(before: float | None, after: float | None) -> float | None:
    if before is None or after is None or before == 0:
        return None
    return round(((after - before) / abs(before)) * 100.0, 2)


def compare_burst_arms(baseline_arm: dict[str, Any], optimized_arm: dict[str, Any]) -> dict[str, Any]:
    """Compare baseline vs burst-optimized metrics across steady, burst, and recovery phases."""
    b_burst = baseline_arm.get("phases", {}).get("burst", {})
    o_burst = optimized_arm.get("phases", {}).get("burst", {})
    b_fps = b_burst.get("fps", {})
    o_fps = o_burst.get("fps", {})
    b_ms = b_burst.get("cpu_frame_ms", {})
    o_ms = o_burst.get("cpu_frame_ms", {})

    return {
        "burst_fps_mean_delta_pct": pct_delta(b_fps.get("mean"), o_fps.get("mean")),
        "burst_fps_p50_delta_pct": pct_delta(b_fps.get("p50"), o_fps.get("p50")),
        "burst_fps_p1_low_delta_pct": pct_delta(b_fps.get("p1_low"), o_fps.get("p1_low")),
        "burst_fps_p0_1_low_delta_pct": pct_delta(b_fps.get("p0_1_low"), o_fps.get("p0_1_low")),
        "burst_max_frame_ms_delta_pct": pct_delta(b_ms.get("max"), o_ms.get("max")),
        "burst_p99_frame_ms_delta_pct": pct_delta(b_ms.get("p99"), o_ms.get("p99")),
        "burst_p1_low_improved": (
            (o_fps.get("p1_low") or 0.0) >= (b_fps.get("p1_low") or 0.0)
        ),
        "burst_max_frame_ms_reduced": (
            (o_ms.get("max") or 9999.0) <= (b_ms.get("max") or 9999.0)
        ),
    }


def compare_cold_vs_warm_launch(cold_sec: float, warm_sec: float) -> dict[str, Any]:
    """Compute speedup and latency reduction for warm-standby resume vs cold boot."""
    safe_warm = max(0.001, float(warm_sec))
    safe_cold = max(0.001, float(cold_sec))
    return {
        "cold_boot_ready_seconds": round(safe_cold, 3),
        "warm_resume_ready_seconds": round(safe_warm, 3),
        "saved_seconds": round(safe_cold - safe_warm, 3),
        "reduction_pct": round(((safe_cold - safe_warm) / safe_cold) * 100.0, 2),
        "speedup_factor": round(safe_cold / safe_warm, 2),
    }


def build_phase_runner_ps1(
    *,
    phase_label: str,
    frames: int,
    warmup: int,
    commands: int,
    resource_bytes: int,
    bg_compute_threads: int,
    elevate_high_priority: bool,
    shader_cache_dir: str | None,
    csv_guest: str,
    done_guest: str,
    err_guest: str,
) -> str:
    """Build guest PowerShell runner for a single steady/burst/recovery D3D11 phase."""
    env_block = ""
    if shader_cache_dir:
        env_block = (
            f"New-Item -ItemType Directory -Path '{shader_cache_dir}' -Force | Out-Null\n"
            f"$env:DXMT_SHADER_CACHE = '{shader_cache_dir}'\n"
        )

    bg_start = ""
    bg_stop = ""
    if bg_compute_threads > 0:
        bg_start = f"""
$bgCode = @'
using System;
using System.Security.Cryptography;
using System.Threading;
public static class P13BurstCompute {{
    public static volatile bool Stop = false;
    public static void Start(int threads) {{
        Stop = false;
        for (int i = 0; i < threads; i++) {{
            var th = new Thread(() => {{
                byte[] b = new byte[8192];
                for (int k = 0; k < b.Length; k++) b[k] = (byte)(k & 0xff);
                using (var sha = SHA256.Create()) {{
                    while (!Stop) {{
                        b = sha.ComputeHash(b);
                    }}
                }}
            }});
            th.IsBackground = true;
            th.Priority = ThreadPriority.BelowNormal;
            th.Start();
        }}
    }}
}}
'@
if (-not ('P13BurstCompute' -as [type])) {{
    Add-Type -TypeDefinition $bgCode -Language CSharp
}}
[P13BurstCompute]::Start({bg_compute_threads})
"""
        bg_stop = "[P13BurstCompute]::Stop = $true"

    prio_block = ""
    if elevate_high_priority:
        prio_block = """
$proc = Start-Process -FilePath 'C:\\graphics-lab\\p13a\\d3d11_probe.exe' -ArgumentList $probeArgs -PassThru -NoNewWindow -RedirectStandardError $errFile
$null = $proc.Handle
try { $proc.PriorityClass = 'High' } catch {}
$proc.WaitForExit()
$ec = $proc.ExitCode
"""
    else:
        prio_block = """
$proc = Start-Process -FilePath 'C:\\graphics-lab\\p13a\\d3d11_probe.exe' -ArgumentList $probeArgs -PassThru -NoNewWindow -RedirectStandardError $errFile
$null = $proc.Handle
$proc.WaitForExit()
$ec = $proc.ExitCode
"""

    return f"""
$ErrorActionPreference = 'Continue'
{env_block}
{bg_start}
$errFile = '{err_guest}'
$probeArgs = @(
    '--frames', '{frames}',
    '--warmup', '{warmup}',
    '--width', '1280',
    '--height', '720',
    '--commands', '{commands}',
    '--command-every', '1',
    '--resource-bytes', '{resource_bytes}',
    '--resource-every', '1',
    '--driver-type', 'hardware',
    '--csv', '{csv_guest}'
)
{prio_block}
{bg_stop}
'phase={phase_label};exit=' + $ec | Set-Content -Encoding ASCII -LiteralPath '{done_guest}'
"""


def _run_guest_phase(
    vm_uuid: str,
    *,
    arm_label: str,
    phase_label: str,
    frames: int,
    warmup: int,
    commands: int,
    resource_bytes: int,
    bg_compute_threads: int,
    elevate_high_priority: bool,
    shader_cache_dir: str | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    tag = f"{arm_label}_{phase_label}"
    csv_guest = f"C:\\graphics-lab\\p13a\\probe-{tag}.csv"
    done_guest = f"C:\\graphics-lab\\p13a\\probe-{tag}.done"
    err_guest = f"C:\\graphics-lab\\p13a\\probe-{tag}.err"
    runner_guest = f"C:\\graphics-lab\\p13a\\run-{tag}.ps1"

    body = build_phase_runner_ps1(
        phase_label=phase_label,
        frames=frames,
        warmup=warmup,
        commands=commands,
        resource_bytes=resource_bytes,
        bg_compute_threads=bg_compute_threads,
        elevate_high_priority=elevate_high_priority,
        shader_cache_dir=shader_cache_dir,
        csv_guest=csv_guest,
        done_guest=done_guest,
        err_guest=err_guest,
    )
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as tf:
        tf.write(body)
        tmp_ps = Path(tf.name)
    try:
        p9s.qga_push(vm_uuid, tmp_ps, runner_guest)
    finally:
        tmp_ps.unlink(missing_ok=True)

    p9s.qga_ps(
        vm_uuid,
        f"""
Remove-Item -LiteralPath '{csv_guest}','{done_guest}','{err_guest}' -Force -EA SilentlyContinue
$u = (Get-CimInstance Win32_ComputerSystem).UserName
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {runner_guest}'
$princ = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
Register-ScheduledTask -TaskName 'P13A_BurstPhase' -Action $act -Principal $princ -Force | Out-Null
Start-ScheduledTask -TaskName 'P13A_BurstPhase'
'launched'
""",
        timeout=25,
    )

    host_samples: list[dict[str, Any]] = []
    t0 = time.monotonic()
    deadline = t0 + 180.0
    done_marker = ""
    while time.monotonic() < deadline:
        elapsed = time.monotonic() - t0
        host_samples.append(p12b.sample_host_qemu_with_main_thread(elapsed))
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

    p9s.qga_ps(vm_uuid, "Unregister-ScheduledTask -TaskName 'P13A_BurstPhase' -Confirm:$false -EA SilentlyContinue", timeout=15)
    if not done_marker:
        raise TimeoutError(f"Burst benchmark phase '{tag}' timed out")

    pull_res = subprocess.run([str(UTMCTL), "file", "pull", vm_uuid, csv_guest], capture_output=True, timeout=30)
    if pull_res.returncode != 0 or not pull_res.stdout:
        raise RuntimeError(f"Failed to pull CSV for '{tag}': {done_marker}")
    summary = p11b.parse_d3d11_probe_csv(pull_res.stdout.decode("utf-8", errors="replace"))
    summary["done_marker"] = done_marker
    summary["workload"] = {
        "frames": frames,
        "warmup": warmup,
        "commands": commands,
        "resource_bytes": resource_bytes,
        "bg_compute_threads": bg_compute_threads,
        "elevate_high_priority": elevate_high_priority,
        "shader_cache_enabled": bool(shader_cache_dir),
    }
    return summary, p12b.summarize_host_samples_p12(host_samples)


def _run_three_phase_burst_arm(
    vm_uuid: str,
    *,
    arm_label: str,
    elevate_high_priority: bool,
    shader_cache_dir: str | None,
    steady_commands: int = 1024,
    burst_commands: int = 4096,
    steady_resource_bytes: int = 262144,
    burst_resource_bytes: int = 4194304,
    burst_bg_threads: int = 4,
    steady_frames: int = 100,
    burst_frames: int = 100,
    recovery_frames: int = 80,
) -> dict[str, Any]:
    if shader_cache_dir:
        # Short shader cache pre-warm before measured phases
        _run_guest_phase(
            vm_uuid,
            arm_label=f"{arm_label}_prewarm",
            phase_label="prewarm",
            frames=24,
            warmup=8,
            commands=steady_commands,
            resource_bytes=steady_resource_bytes,
            bg_compute_threads=0,
            elevate_high_priority=elevate_high_priority,
            shader_cache_dir=shader_cache_dir,
        )

    steady, steady_host = _run_guest_phase(
        vm_uuid,
        arm_label=arm_label,
        phase_label="steady",
        frames=steady_frames,
        warmup=20,
        commands=steady_commands,
        resource_bytes=steady_resource_bytes,
        bg_compute_threads=0,
        elevate_high_priority=elevate_high_priority,
        shader_cache_dir=shader_cache_dir,
    )
    burst, burst_host = _run_guest_phase(
        vm_uuid,
        arm_label=arm_label,
        phase_label="burst",
        frames=burst_frames,
        warmup=10,
        commands=burst_commands,
        resource_bytes=burst_resource_bytes,
        bg_compute_threads=burst_bg_threads,
        elevate_high_priority=elevate_high_priority,
        shader_cache_dir=shader_cache_dir,
    )
    recovery, recovery_host = _run_guest_phase(
        vm_uuid,
        arm_label=arm_label,
        phase_label="recovery",
        frames=recovery_frames,
        warmup=10,
        commands=steady_commands,
        resource_bytes=steady_resource_bytes,
        bg_compute_threads=0,
        elevate_high_priority=elevate_high_priority,
        shader_cache_dir=shader_cache_dir,
    )

    return {
        "arm_label": arm_label,
        "elevate_high_priority": elevate_high_priority,
        "shader_cache_enabled": bool(shader_cache_dir),
        "phases": {
            "steady": steady,
            "burst": burst,
            "recovery": recovery,
        },
        "host": {
            "steady": steady_host,
            "burst": burst_host,
            "recovery": recovery_host,
        },
    }


def _verify_guest_post_resume_health(vm_uuid: str) -> dict[str, Any]:
    """Verify viogpu3d adapter, ACE-CORE driver/service health, and core security invariants."""
    ps_check = r"""
$gpu = Get-CimInstance Win32_VideoController -EA SilentlyContinue | Select-Object Name,Status,DriverVersion
$ace = @(Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.Name -like 'ACE*' } | Select-Object Name,State,Status)
$aceSvc = @(Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object { $_.Name -like 'ACE*' -or $_.Name -like 'AntiCheat*' } | Select-Object Name,State,StartMode)
$sb = $false
try { $sb = Confirm-SecureBootUEFI } catch {}
$tpm = Get-Tpm -EA SilentlyContinue
$bcd = (& bcdedit /enum '{current}' 2>&1 | Out-String)
$testSigningOn = ($bcd -match 'testsigning\s+Yes')
$noIntegrityOn = ($bcd -match 'nointegritychecks\s+Yes')
$prismOk = $true
foreach ($f in @('System32\xtajit.dll','System32\xtajit64.dll','System32\wow64.dll','System32\wow64win.dll')) {
    $full = Join-Path $env:SystemRoot $f
    if (-not (Test-Path $full)) { $prismOk = $false }
}
[ordered]@{
    gpu = $gpu
    ace_drivers = $ace
    ace_services = $aceSvc
    secure_boot_enabled = [bool]$sb
    tpm_present = [bool]($tpm.TpmPresent)
    tpm_ready = [bool]($tpm.TpmReady)
    test_signing_disabled = (-not $testSigningOn)
    nointegritychecks_disabled = (-not $noIntegrityOn)
    prism_files_present = $prismOk
} | ConvertTo-Json -Depth 5 -Compress
"""
    raw = p9s.qga_ps(vm_uuid, ps_check, timeout=30).strip()
    health = json.loads(raw)

    # Also run a short 45-frame D3D11 hardware probe to confirm viogpu3d rendering post-resume
    probe, _ = _run_guest_phase(
        vm_uuid,
        arm_label="post_resume",
        phase_label="viogpu3d_verify",
        frames=45,
        warmup=10,
        commands=512,
        resource_bytes=131072,
        bg_compute_threads=0,
        elevate_high_priority=True,
        shader_cache_dir=r"C:\graphics-lab\p13a\dxmt-cache",
    )
    health["viogpu3d_post_resume_probe"] = {
        "frame_count": probe["frame_count"],
        "fps_mean": probe["fps"]["mean"],
        "fps_p1_low": probe["fps"]["p1_low"],
        "done_marker": probe["done_marker"],
        "passed": probe["done_marker"].endswith("exit=0") and probe["frame_count"] >= 40,
    }
    return health


def _verify_kiosk_shell_live(vm_uuid: str) -> dict[str, Any]:
    """Run kiosk-app-shell.ps1 in interactive guest session and verify hide -> signal -> restore."""
    p9s.qga_push(vm_uuid, KIOSK_SCRIPT, r"C:\graphics-lab\p13a\kiosk-app-shell.ps1")
    out_guest = r"C:\graphics-lab\p13a\kiosk-live-result.json"
    done_guest = r"C:\graphics-lab\p13a\kiosk-live.done"
    runner_guest = r"C:\graphics-lab\p13a\run-kiosk-live.ps1"

    runner_ps = f"""
$ErrorActionPreference = 'Continue'
$res = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\graphics-lab\\p13a\\kiosk-app-shell.ps1' `
    -Mode Enter `
    -TargetExecutable 'C:\\Windows\\System32\\notepad.exe' `
    -GameProcessNames @('notepad') `
    -PollIntervalMs 250 `
    -MaxWaitSeconds 4 `
    -StatePath 'C:\\graphics-lab\\p13a\\kiosk-state.json' `
    -SignalOutputPath 'C:\\graphics-lab\\p13a\\kiosk-signal.json'
$res | Out-String | Set-Content -LiteralPath '{out_guest}' -Encoding UTF8
Get-Process -Name 'notepad' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
'done' | Set-Content -LiteralPath '{done_guest}' -Encoding ASCII
"""
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as tf:
        tf.write(runner_ps)
        tmp_ps = Path(tf.name)
    try:
        p9s.qga_push(vm_uuid, tmp_ps, runner_guest)
    finally:
        tmp_ps.unlink(missing_ok=True)

    p9s.qga_ps(
        vm_uuid,
        f"""
Remove-Item -LiteralPath '{out_guest}','{done_guest}' -Force -EA SilentlyContinue
$u = (Get-CimInstance Win32_ComputerSystem).UserName
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {runner_guest}'
$princ = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
Register-ScheduledTask -TaskName 'P13A_KioskLive' -Action $act -Principal $princ -Force | Out-Null
Start-ScheduledTask -TaskName 'P13A_KioskLive'
'launched'
""",
        timeout=25,
    )

    deadline = time.monotonic() + 45.0
    while time.monotonic() < deadline:
        chk = p9s.qga_ps(
            vm_uuid,
            f"if (Test-Path '{done_guest}') {{ 'DONE' }} else {{ 'RUNNING' }}",
            timeout=15,
        ).strip()
        if chk == "DONE":
            break
        time.sleep(1.0)
    p9s.qga_ps(vm_uuid, "Unregister-ScheduledTask -TaskName 'P13A_KioskLive' -Confirm:$false -EA SilentlyContinue", timeout=15)

    raw_bytes = p9s.qga_pull(vm_uuid, out_guest, timeout=20)
    text = raw_bytes.decode("utf-8-sig", errors="replace").strip()
    start_idx = text.find("{")
    if start_idx == -1:
        raise RuntimeError(f"kiosk-app-shell.ps1 did not emit JSON: {redact_p13_text(text[:300])}")
    return json.loads(text[start_idx:])


def render_report_md(payload: dict[str, Any], zero_drift: dict[str, Any]) -> str:
    comp = payload["burst_comparison"]
    launch = payload["cold_vs_warm_launch"]
    b_burst = payload["baseline_arm"]["phases"]["burst"]
    o_burst = payload["optimized_arm"]["phases"]["burst"]
    b_steady = payload["baseline_arm"]["phases"]["steady"]
    o_steady = payload["optimized_arm"]["phases"]["steady"]
    o_rec = payload["optimized_arm"]["phases"]["recovery"]
    kiosk = payload.get("kiosk_shell_verification", {})
    post = payload.get("post_resume_health", {})

    lines = [
        "# Phase 13A 实验报告：突发大特效稳帧优化、热待机秒开与无桌面 Kiosk 会话",
        "",
        f"- 署名：`@DNPMBHC`",
        f"- 采样时间（UTC）：`{payload['captured_at_utc']}`",
        f"- 硬件配置：`8 vCPU / 10240 MiB RAM / VirtIO-Blk 多队列 (iothread + num-queues=4) / vmnet-shared 原生网络 / dxmt-native`",
        "",
        "## 1. 突发大特效稳帧对比（平稳段 → 4× Draw-Call + 4 MiB/帧动态缓冲 + 4 线程计算爆发 → 恢复段）",
        "",
        "| 指标 | Baseline 基线（突发段） | Optimized 突发优化态（突发段） | 变化幅度 |",
        "| --- | ---: | ---: | ---: |",
        f"| Mean FPS | {b_burst['fps']['mean']} | {o_burst['fps']['mean']} | {comp['burst_fps_mean_delta_pct']:+.2f}% |",
        f"| P50 FPS | {b_burst['fps']['p50']} | {o_burst['fps']['p50']} | {comp['burst_fps_p50_delta_pct']:+.2f}% |",
        f"| **P1 Low FPS** | {b_burst['fps']['p1_low']} | **{o_burst['fps']['p1_low']}** | **{comp['burst_fps_p1_low_delta_pct']:+.2f}%** |",
        f"| **P0.1 Low FPS** | {b_burst['fps']['p0_1_low']} | **{o_burst['fps']['p0_1_low']}** | **{comp['burst_fps_p0_1_low_delta_pct']:+.2f}%** |",
        f"| P99 Frame Time (ms) | {b_burst['cpu_frame_ms']['p99']} | {o_burst['cpu_frame_ms']['p99']} | {comp['burst_p99_frame_ms_delta_pct']:+.2f}% |",
        f"| **Max Frame Time (ms)** | {b_burst['cpu_frame_ms']['max']} | **{o_burst['cpu_frame_ms']['max']}** | **{comp['burst_max_frame_ms_delta_pct']:+.2f}%** |",
        "",
        f"- 平稳段对照：Baseline Mean `{b_steady['fps']['mean']} FPS` vs Optimized Mean `{o_steady['fps']['mean']} FPS`；优化态恢复段 Mean `{o_rec['fps']['mean']} FPS`（P1 Low `{o_rec['fps']['p1_low']} FPS`）。",
        "",
        "## 2. 冷启动精简 vs 热待机秒开（`warm-standby` / `pause` / `resume-launch`）",
        "",
        "| 模式 | 耗时 (s) | 关键指标 |",
        "| --- | ---: | --- |",
        f"| 精简冷启动（Cold Boot → QGA 就绪） | {launch['cold_boot_ready_seconds']} | 全量启动 Windows 11 ARM64 + VirtIO-GPU 3D |",
        f"| **热待机唤醒（Warm Resume → QGA 就绪）** | **{launch['warm_resume_ready_seconds']}** | 节省 **{launch['saved_seconds']} s**（提速 **{launch['speedup_factor']}×** / 缩短 **{launch['reduction_pct']}%**） |",
        "",
        f"- 暂停驻留态（`utmctl suspend` / QMP `stop`）：QEMU CPU 占用 `{payload['warm_standby']['standby_metrics']['qemu_cpu_pct']}%`，macOS 内存压缩页 `{payload['warm_standby']['standby_metrics']['macos_compressor_mib']} MiB`。",
        f"- 恢复后健康校验：`viogpu3d` 渲染探针 `passed = {post.get('viogpu3d_post_resume_probe', {}).get('passed')}`（`{post.get('viogpu3d_post_resume_probe', {}).get('fps_mean')} FPS`），`Secure Boot = {post.get('secure_boot_enabled')}`，`TPM Ready = {post.get('tpm_ready')}`，`Prism = {post.get('prism_files_present')}`，`test_signing_disabled = {post.get('test_signing_disabled')}`。",
        "",
        "## 3. 无桌面 Kiosk 会话脚本（`kiosk-app-shell.ps1`）真机校验",
        "",
        f"- 合规标记：`zero_dwm_hook = {kiosk.get('compliance', {}).get('zero_dwm_hook')}`，`zero_process_injection = {kiosk.get('compliance', {}).get('zero_process_injection')}`，`read_only_foreground_polling = {kiosk.get('compliance', {}).get('read_only_foreground_polling')}`",
        f"- 进入无桌面态：`taskbar_hidden = {kiosk.get('enter', {}).get('taskbar_hidden')}`，`desktop_icons_hidden = {kiosk.get('enter', {}).get('desktop_icons_hidden')}`，`background_solid_black = {kiosk.get('enter', {}).get('background_solid_black')}`",
        f"- 退出还原：`restored = {kiosk.get('restore', {}).get('restored')}`，`taskbar_visible = {kiosk.get('restore', {}).get('taskbar_visible')}`，`desktop_icons_visible = {kiosk.get('restore', {}).get('desktop_icons_visible')}`",
        "",
        "## 4. 零漂移校验（`zero-drift-proof.json`）",
        "",
        f"- `golden_zero_drift`: `{zero_drift['golden_zero_drift']}`（`readonly = {zero_drift['golden_readonly']}`）",
        f"- `primary_zero_drift`: `{zero_drift['primary_zero_drift']}`",
        f"- `original_utm_app_present`: `{zero_drift['original_utm_app_present']}`",
        f"- `zero_drift`: **`{zero_drift['zero_drift']}`**",
        "",
    ]
    return "\n".join(lines)


def run_live_p13a_benchmark() -> dict[str, Any]:
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    if not D3D11_PROBE.is_file():
        raise FileNotFoundError("Missing graphics-lab/build/d3d11_probe.exe")
    if not GOLDEN_MANIFEST.is_file():
        raise FileNotFoundError("Missing golden-guest-manifest.json")

    ephemeral_name = "ephemeral-p13a-burst"
    ephemeral_path = vms_dir / f"{ephemeral_name}.utm"
    if ephemeral_path.exists():
        ggm.destroy_ephemeral(ephemeral_path, golden=golden, primary=primary, fast_disk_hash=True)

    spawn_res = ggm.spawn_ephemeral(
        golden=golden,
        dest_dir=vms_dir,
        name=ephemeral_name,
        primary=primary,
        register_utm=True,
        fast_disk_hash=True,
        trim_hardware=True,
        dx_driver="DXMT",
        fps_limit=120,
        ram_mb=10240,
        vcpu=8,
        disable_balloon=True,
        network_mode="vmnet-shared",
        net_rx_queue_size=1024,
        disk_interface="virtio",
        enable_iothread=True,
        io_queues=4,
    )
    vm_uuid = spawn_res["clone_uuid"]

    try:
        # 1) Measure streamlined cold boot
        print("[p13a] 1/6 cold boot...", flush=True)
        cold_t0 = time.monotonic()
        start_res = subprocess.run([str(UTMCTL), "start", vm_uuid], capture_output=True, text=True, timeout=120)
        if start_res.returncode != 0:
            raise RuntimeError(f"Failed to cold-start ephemeral VM: {redact_p13_text(start_res.stderr)}")
        cold_qga_sec = ggm._wait_qga_ping(vm_uuid, UTMCTL, timeout_sec=150.0)
        cold_total_sec = round(time.monotonic() - cold_t0, 3)
        print(f"[p13a] cold boot QGA ready in {cold_total_sec}s", flush=True)

        # Wait for interactive desktop logon readiness
        time.sleep(8.0)

        # Reuse pre-seeded d3d11_probe.exe in golden guest (verified by SHA-256)
        p9s.qga_ps(vm_uuid, "New-Item -ItemType Directory -Path 'C:\\graphics-lab\\p13a' -Force | Out-Null", timeout=20)
        local_sha = ggm.sha256_file(D3D11_PROBE).lower()
        copy_ps = rf"""
$target = 'C:\graphics-lab\p13a\d3d11_probe.exe'
$cands = @('C:\graphics-lab\module-c\d3d11_probe.exe', 'C:\graphics-lab\d3d11_probe.exe')
$found = $null
foreach ($c in $cands) {{
    if (Test-Path -LiteralPath $c) {{
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $c).Hash.ToLowerInvariant()
        if ($h -eq '{local_sha}') {{ $found = $c; break }}
    }}
}}
if ($null -ne $found) {{
    Copy-Item -LiteralPath $found -Destination $target -Force
    'COPIED:' + $found
}} else {{
    'MISSING'
}}
"""
        copy_res = p9s.qga_ps(vm_uuid, copy_ps, timeout=25).strip()
        if not copy_res.startswith("COPIED:"):
            raise RuntimeError(f"Pre-seeded d3d11_probe.exe missing or hash mismatch: {copy_res}")

        # 2) Baseline 3-phase burst run (Normal priority, no shader cache pre-warm, pre-optimizer)
        print("[p13a] 2/6 baseline 3-phase burst benchmark...", flush=True)
        baseline_arm = _run_three_phase_burst_arm(
            vm_uuid,
            arm_label="baseline",
            elevate_high_priority=False,
            shader_cache_dir=None,
        )

        # 3) Apply guest-optimizer v3.1 + persistent DXMT_SHADER_CACHE + High foreground priority
        print("[p13a] 3/6 applying guest-optimizer v3.1 and running optimized 3-phase burst...", flush=True)
        p9s.qga_push(vm_uuid, OPT_APPLY, r"C:\graphics-lab\p13a\apply-optimizer.ps1")
        p9s.qga_push(vm_uuid, OPT_PROFILE, r"C:\graphics-lab\p13a\anticheat-minimal-win11-arm64.json")
        opt_raw = p9s.qga_ps(
            vm_uuid,
            "$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\\graphics-lab\\p13a\\apply-optimizer.ps1' "
            "-ProfilePath 'C:\\graphics-lab\\p13a\\anticheat-minimal-win11-arm64.json' "
            "-MemoryCompressionOverride preserve 2>&1; "
            "@{ exit_code=$LASTEXITCODE } | ConvertTo-Json -Compress",
            timeout=180,
        )
        opt_meta = json.loads(opt_raw)
        if int(opt_meta.get("exit_code", 1)) != 0:
            raise RuntimeError("apply-optimizer.ps1 failed during p13a benchmark")

        optimized_arm = _run_three_phase_burst_arm(
            vm_uuid,
            arm_label="optimized",
            elevate_high_priority=True,
            shader_cache_dir=r"C:\graphics-lab\p13a\dxmt-cache",
        )

        # 4) Verify Kiosk desktop-less shell script live
        print("[p13a] 4/6 verifying kiosk-app-shell.ps1 live...", flush=True)
        kiosk_live = _verify_kiosk_shell_live(vm_uuid)

        # 5) Pause into 0% CPU warm-standby and measure fast warm-resume
        print("[p13a] 5/6 warm-standby pause & resume-launch...", flush=True)
        pause_info = ggm.pause_vm(ephemeral_path, golden=golden, primary=primary, utmctl=UTMCTL)
        time.sleep(2.0)
        standby_metrics_settled = ggm.sample_qemu_standby_metrics()
        pause_info["standby_metrics"] = standby_metrics_settled

        resume_info = ggm.resume_launch(ephemeral_path, golden=golden, primary=primary, utmctl=UTMCTL)
        post_resume_health = _verify_guest_post_resume_health(vm_uuid)

        payload = {
            "schema_version": 1,
            "owner": "@DNPMBHC",
            "captured_at_utc": utc_now_iso(),
            "vm_profile": {
                "vcpu": 8,
                "ram_mb": 10240,
                "disk_interface": "virtio",
                "virtio_blk_iothread": True,
                "virtio_blk_num_queues": 4,
                "network_mode": "vmnet-shared",
                "dx_driver": "DXMT",
                "fps_limit": 120,
            },
            "baseline_arm": baseline_arm,
            "optimized_arm": optimized_arm,
            "burst_comparison": compare_burst_arms(baseline_arm, optimized_arm),
            "cold_boot": {
                "cold_boot_to_qga_seconds": cold_total_sec,
                "qga_ping_seconds": cold_qga_sec,
            },
            "warm_standby": pause_info,
            "warm_resume": resume_info,
            "cold_vs_warm_launch": compare_cold_vs_warm_launch(
                cold_total_sec,
                float(resume_info["total_ready_seconds"]),
            ),
            "post_resume_health": post_resume_health,
            "kiosk_shell_verification": kiosk_live,
        }
    finally:
        print("[p13a] 6/6 destroying ephemeral clone...", flush=True)
        state = ggm.utmctl_status(vm_uuid, UTMCTL)
        if state not in ("stopped", "unregistered", "utmctl-unavailable"):
            subprocess.run([str(UTMCTL), "stop", vm_uuid, "--request"], capture_output=True, text=True, timeout=30)
            for _ in range(25):
                state = ggm.utmctl_status(vm_uuid, UTMCTL)
                if state in ("stopped", "unregistered"):
                    break
                time.sleep(1.0)
            if state not in ("stopped", "unregistered"):
                subprocess.run([str(UTMCTL), "stop", vm_uuid, "--kill"], capture_output=True, text=True, timeout=30)
                time.sleep(2.0)
        ggm.destroy_ephemeral(
            ephemeral_path,
            golden=golden,
            primary=primary,
            baseline_manifest_path=None,
            utmctl=UTMCTL,
            fast_disk_hash=True,
        )

    # Full-disk SHA-256 zero-drift verification
    print("[p13a] computing full-disk SHA-256 zero-drift proof...", flush=True)
    manifest_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
    g_fp = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
    p_fp = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
    golden_ok = (
        g_fp["readonly"]
        and g_fp["config_sha256"] == manifest_fp.get("golden_config_sha256")
        and g_fp["bundle_sha256"] == manifest_fp.get("golden_bundle_sha256")
    )
    primary_ok = (
        p_fp["config_sha256"] == manifest_fp.get("primary_vm_a_config_sha256")
        and p_fp["bundle_sha256"] == manifest_fp.get("primary_vm_a_bundle_sha256")
    )
    zero_drift = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "captured_at_utc": utc_now_iso(),
        "original_utm_app_present": Path("/Applications/UTM.app").is_dir(),
        "golden_readonly": g_fp["readonly"],
        "golden_config_sha256": g_fp["config_sha256"],
        "golden_bundle_sha256": g_fp["bundle_sha256"],
        "golden_zero_drift": golden_ok,
        "primary_vm_a_config_sha256": p_fp["config_sha256"],
        "primary_vm_a_bundle_sha256": p_fp["bundle_sha256"],
        "primary_zero_drift": primary_ok,
        "zero_drift": bool(golden_ok and primary_ok and Path("/Applications/UTM.app").is_dir()),
    }

    EVIDENCE_P13A.mkdir(parents=True, exist_ok=True)
    ggm.write_redacted_json(EVIDENCE_P13A / "burst-and-fastlaunch-benchmark.json", redact_p13_value(payload))
    ggm.write_redacted_json(EVIDENCE_P13A / "zero-drift-proof.json", redact_p13_value(zero_drift))
    (EVIDENCE_P13A / "report.md").write_text(
        redact_p13_text(render_report_md(payload, zero_drift)),
        encoding="utf-8",
    )
    return {"benchmark": payload, "zero_drift": zero_drift}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 13A burst & warm-standby benchmark (@DNPMBHC)")
    parser.add_argument("--live", action="store_true", help="Run live VM benchmark and emit Phase 13A evidence")
    args = parser.parse_args(argv)
    if args.live:
        res = run_live_p13a_benchmark()
        print(json.dumps(redact_p13_value({
            "burst_comparison": res["benchmark"]["burst_comparison"],
            "cold_vs_warm_launch": res["benchmark"]["cold_vs_warm_launch"],
            "zero_drift": res["zero_drift"]["zero_drift"],
        }), indent=2, ensure_ascii=False))
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
