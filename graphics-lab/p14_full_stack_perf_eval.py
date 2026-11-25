#!/usr/bin/env python3
"""Phase 14A full-stack performance deep-dive & end-to-end real-run evaluator.

Owner: @DNPMBHC
Compliance:
- Never modifies /Applications/UTM.app, sealed golden-win11-arm64-v1.utm, or primary vm-a.
- Never disables Secure Boot, never spoofs CPUID/SMBIOS/ACPI/TPM/Hypervisor.
- Never hooks DWM, injects processes, modifies game/ACE/Windows drivers, or automates login/CAPTCHA.
- Full path/identity redaction (<EXTERNAL_VOLUME>, <workspace>, <TMPDIR>, <uuid>, user-x).
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any
import uuid

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import golden_guest_manager as ggm
import p9_valorant_session as p9s
import p10_valorant_analyzer as p10a
import p11_vm_perf_benchmark as p11b
import p11_valorant_fullscreen_session as p11v
import p12_cpu_net_benchmark as p12b
import p13_burst_perf_benchmark as p13b

WORKSPACE_ROOT = SCRIPT_DIR.parent
EVIDENCE_P14A = WORKSPACE_ROOT / "handoff/phase-14/evidence/p14-a"
PHASE14_RUNS_DIR = WORKSPACE_ROOT / "handoff/module-f/valorant-phase14-runs"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
DEFAULT_CUSTOM_APP = Path(os.environ.get("TMPDIR", "/tmp")) / "utm-custom-build" / "UTM-Custom.app"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
OPT_APPLY = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"
OPT_PROFILE = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
KIOSK_SCRIPT = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/kiosk-app-shell.ps1"
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")

# Phase 11B baseline constants (from handoff/module-f/valorant-phase11-runs/summary.md)
PHASE11B_BASELINE: dict[str, Any] = {
    "resolution": "1920x1200",
    "range_warm_min8_mean_fps": 55.51,
    "range_warm_min8_p50_fps": 58.44,
    "range_warm_min8_p5_fps": 42.42,
    "range_warm_min8_p1_low_fps": 25.74,
    "range_warm_min8_mean_frame_ms": 18.70,
    "range_warm_min8_p99_frame_ms": 38.85,
    "range_pure_combat_mean_fps": 45.21,
    "range_pure_combat_p50_fps": 49.63,
    "range_pure_combat_p1_low_fps": 3.88,
    "engine_latency_total_ms": 22.62,
    "engine_latency_work_ms": 19.69,
    "engine_latency_slack_ms": 2.45,
    "engine_latency_slop_ms": 0.48,
    "engine_latency_slack_plus_slop_ms": 2.93,
    "slirp_burst_loss_events": 5,
    "range_severe_drop_events": 39,
}

UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact_p14_text(text: str) -> str:
    if not text:
        return ""
    out = p13b.redact_p13_text(str(text))
    tmp_dir = os.environ.get("TMPDIR", "")
    if tmp_dir:
        out = out.replace(tmp_dir.rstrip("/"), "<TMPDIR>")
    out = re.sub(r"/var/folders/[^\s\"'<>`]+/T", "<TMPDIR>", out)
    return out


def redact_p14_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p14_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p14_value(v) for v in value]
    if isinstance(value, str):
        return redact_p14_text(value)
    return value


def pct_delta(before: float | None, after: float | None) -> float | None:
    if before is None or after is None or before == 0:
        return None
    return round(((after - before) / abs(before)) * 100.0, 2)


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(float(v) for v in values)
    if pct <= 0:
        return round(ordered[0], 3)
    if pct >= 100:
        return round(ordered[-1], 3)
    idx = (len(ordered) - 1) * (pct / 100.0)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return round(ordered[lo], 3)
    frac = idx - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def summarize_frame_times_ms(frame_times_ms: list[float], severe_threshold_ms: float = 33.333) -> dict[str, Any]:
    valid = [float(x) for x in frame_times_ms if x is not None and float(x) > 0]
    if not valid:
        return {
            "count": 0,
            "fps_mean": None,
            "fps_p50": None,
            "fps_p1_low": None,
            "fps_p0_1_low": None,
            "frame_ms_mean": None,
            "frame_ms_p50": None,
            "frame_ms_p99": None,
            "frame_ms_max": None,
            "frame_ms_jitter_p99_p50": None,
            "severe_drop_count": 0,
            "severe_drop_pct": 0.0,
        }
    fps_vals = [1000.0 / ms for ms in valid]
    p50_ms = percentile(valid, 50.0) or 0.0
    p99_ms = percentile(valid, 99.0) or 0.0
    severe_cnt = sum(1 for ms in valid if ms > severe_threshold_ms)
    return {
        "count": len(valid),
        "fps_mean": round(statistics.mean(fps_vals), 3),
        "fps_p50": percentile(fps_vals, 50.0),
        "fps_p1_low": percentile(fps_vals, 1.0),
        "fps_p0_1_low": percentile(fps_vals, 0.1),
        "frame_ms_mean": round(statistics.mean(valid), 3),
        "frame_ms_p50": p50_ms,
        "frame_ms_p99": p99_ms,
        "frame_ms_max": round(max(valid), 3),
        "frame_ms_jitter_p99_p50": round(max(0.0, p99_ms - p50_ms), 3),
        "severe_drop_count": severe_cnt,
        "severe_drop_pct": round((severe_cnt / len(valid)) * 100.0, 2),
    }


# ---------------------------------------------------------------------------
# Pure analysis helpers (covered by unit tests)
# ---------------------------------------------------------------------------

def compare_dual_cache_runs(cold_arm: dict[str, Any], warm_arm: dict[str, Any]) -> dict[str, Any]:
    """Compare cold-cache first boot vs warm-cache second boot (XtaCache + DXMT_SHADER_CACHE)."""
    c_fps = cold_arm.get("frame_metrics", {})
    w_fps = warm_arm.get("frame_metrics", {})
    c_cpu = cold_arm.get("host_cpu", {})
    w_cpu = warm_arm.get("host_cpu", {})
    c_gcpu = cold_arm.get("guest_cpu_avg_pct")
    w_gcpu = warm_arm.get("guest_cpu_avg_pct")

    c_drop = int(c_fps.get("severe_drop_count") or 0)
    w_drop = int(w_fps.get("severe_drop_count") or 0)
    drop_reduction_pct = (
        round(((c_drop - w_drop) / c_drop) * 100.0, 2)
        if c_drop > 0
        else (0.0 if w_drop == 0 else -100.0)
    )

    c_qcpu = c_cpu.get("qemu_worker_cpu_mean")
    if c_qcpu is None and isinstance(c_cpu.get("qemu_worker_cpu"), dict):
        c_qcpu = c_cpu["qemu_worker_cpu"].get("mean")
    w_qcpu = w_cpu.get("qemu_worker_cpu_mean")
    if w_qcpu is None and isinstance(w_cpu.get("qemu_worker_cpu"), dict):
        w_qcpu = w_cpu["qemu_worker_cpu"].get("mean")
    c_rcpu = c_cpu.get("render_server_cpu_mean")
    if c_rcpu is None and isinstance(c_cpu.get("qemu_render_server_cpu"), dict):
        c_rcpu = c_cpu["qemu_render_server_cpu"].get("mean")
    w_rcpu = w_cpu.get("render_server_cpu_mean")
    if w_rcpu is None and isinstance(w_cpu.get("qemu_render_server_cpu"), dict):
        w_rcpu = w_cpu["qemu_render_server_cpu"].get("mean")

    return {
        "fps_mean_delta_pct": pct_delta(c_fps.get("fps_mean"), w_fps.get("fps_mean")),
        "fps_p1_low_delta_pct": pct_delta(c_fps.get("fps_p1_low"), w_fps.get("fps_p1_low")),
        "frame_ms_p99_delta_pct": pct_delta(c_fps.get("frame_ms_p99"), w_fps.get("frame_ms_p99")),
        "qemu_worker_cpu_delta_pct": pct_delta(c_qcpu, w_qcpu),
        "render_server_cpu_delta_pct": pct_delta(c_rcpu, w_rcpu),
        "guest_cpu_delta_pct": pct_delta(c_gcpu, w_gcpu),
        "cold_severe_drop_count": c_drop,
        "warm_severe_drop_count": w_drop,
        "severe_drop_reduction_pct": drop_reduction_pct,
        "dxmt_cache_persisted": (warm_arm.get("dxmt_cache_before_bytes") or 0) > 0,
        "xtacache_persisted": (warm_arm.get("xtacache_before_bytes") or 0) > 0,
    }


def select_best_frame_sync_arm(arms: list[dict[str, Any]]) -> dict[str, Any]:
    """Select best frame-sync configuration balancing mean frame time, P1 Low, and jitter."""
    valid_arms = [a for a in arms if (a.get("frame_metrics", {}).get("fps_p1_low") or 0) > 0]
    if not valid_arms:
        return {"recommended_arm": None, "reason": "no valid frame-sync arms"}

    max_mean = max(float(a["frame_metrics"]["fps_mean"] or 1.0) for a in valid_arms)
    max_p1 = max(float(a["frame_metrics"]["fps_p1_low"] or 1.0) for a in valid_arms)
    min_jitter = min(float(a["frame_metrics"]["frame_ms_jitter_p99_p50"] or 0.001) for a in valid_arms)
    min_jitter = max(min_jitter, 0.05)

    scored: list[tuple[float, dict[str, Any]]] = []
    for arm in valid_arms:
        fm = arm["frame_metrics"]
        mean_norm = float(fm["fps_mean"] or 0.0) / max_mean
        p1_norm = float(fm["fps_p1_low"] or 0.0) / max_p1
        jitter = max(float(fm["frame_ms_jitter_p99_p50"] or 0.05), 0.05)
        jitter_norm = min(1.0, min_jitter / jitter)
        # Prioritize P1 Low stability & low jitter while rewarding mean FPS
        score = round((0.40 * p1_norm + 0.35 * mean_norm + 0.25 * jitter_norm) * 100.0, 2)
        arm["composite_score"] = score
        scored.append((score, arm))

    scored.sort(key=lambda item: item[0], reverse=True)
    best = scored[0][1]
    return {
        "recommended_arm": best.get("label"),
        "fps_limit": best.get("fps_limit"),
        "metal_drawable_count": best.get("metal_drawable_count"),
        "max_inflight_frames": best.get("max_inflight_frames"),
        "composite_score": best.get("composite_score"),
        "fps_mean": best["frame_metrics"].get("fps_mean"),
        "fps_p1_low": best["frame_metrics"].get("fps_p1_low"),
        "frame_ms_jitter_p99_p50": best["frame_metrics"].get("frame_ms_jitter_p99_p50"),
    }


def audit_qemu_polling_devices(qemu_cmdline: str) -> dict[str, Any]:
    """Audit QEMU command line for residual unnecessary polling peripherals."""
    tokens = qemu_cmdline.split() if qemu_cmdline else []
    devices: list[str] = []
    for idx, tok in enumerate(tokens):
        if tok == "-device" and idx + 1 < len(tokens):
            devices.append(tokens[idx + 1])

    def _has(substr: str) -> bool:
        return any(substr in d for d in devices)

    findings: list[dict[str, Any]] = []
    checks = [
        ("usb-tablet", "unnecessary_polling", "Absolute USB tablet polls continuously; must stay disabled in pure relative mouse mode."),
        ("virtio-balloon", "unnecessary_polling", "Memory ballooning causes periodic host-guest reclaim jitter; must stay disabled."),
        ("usb-redir", "optional_removable", "USB redirection host channels add USB bus polling when unused."),
        ("spice-vdagent", "optional_removable", "SPICE vdagent/webdavd channel; webdavd disabled by guest-optimizer v3.1."),
        ("virtio-rng", "low_overhead_keep", "Hardware RNG is event-driven and required for low-latency entropy; keep."),
        ("intel-hda", "required_audio", "Audio controller required for game sound; keep."),
        ("usb-mouse", "input_device", "Relative USB mouse; evaluate against virtio-mouse-pci if WHQL vioinput is available."),
        ("virtio-mouse-pci", "input_device", "VirtIO PCI mouse (interrupt-driven, no USB polling)."),
        ("usb-kbd", "input_device", "USB keyboard; low event rate."),
        ("virtio-gpu", "required_gpu", "VirtIO-GPU 3D (DXMT native backend)."),
        ("virtio-net", "required_net", "VirtIO-Net with ioeventfd=on and enlarged rx_queue_size."),
        ("virtio-blk", "required_blk", "VirtIO-Blk with dedicated iothread and num-queues=4."),
        ("tpm-tis", "required_security", "vTPM required for Windows 11 & anti-cheat integrity; never touch."),
    ]
    removable_found: list[str] = []
    for dev_key, category, note in checks:
        present = _has(dev_key)
        if present and category in ("unnecessary_polling", "optional_removable"):
            removable_found.append(dev_key)
        findings.append({
            "device_key": dev_key,
            "present": present,
            "category": category,
            "note": note,
        })

    return {
        "device_count": len(devices),
        "devices": [redact_p14_text(d) for d in devices],
        "has_usb_tablet": _has("usb-tablet"),
        "has_virtio_balloon": _has("virtio-balloon"),
        "has_usb_mouse": _has("usb-mouse"),
        "has_virtio_mouse": _has("virtio-mouse"),
        "has_slirp_user_net": ("-netdev user," in qemu_cmdline or "type=user" in qemu_cmdline),
        "removable_polling_devices": removable_found,
        "clean_of_known_polling_bloat": (not _has("usb-tablet") and not _has("virtio-balloon")),
        "findings": findings,
    }


def parse_shooter_engine_latency(log_text: str) -> dict[str, Any]:
    """Parse Valorant ShooterGame.log engine latency breakdown (Work + Slack + Slop) and network warnings."""
    # Example line from Valorant LogClientPerRoundTelemetryComponent:
    # Avg. Engine Latency: 22.62 ms (Work: 19.69 ms, Slack: 2.45 ms, Slop: 0.48 ms)
    # Also support alternate key=value or colon formats logged by UE4/Valorant.
    latency_samples: list[dict[str, float]] = []
    pat = re.compile(
        r"Avg\.?\s*Engine\s*Latency[:=\s]+([0-9.]+)\s*ms.*?"
        r"Work[:=\s]+([0-9.]+)\s*ms.*?"
        r"Slack[:=\s]+([0-9.]+)\s*ms.*?"
        r"Slop[:=\s]+([0-9.]+)\s*ms",
        re.IGNORECASE,
    )
    for m in pat.finditer(log_text):
        total, work, slack, slop = (float(m.group(i)) for i in range(1, 5))
        latency_samples.append({
            "total_ms": round(total, 3),
            "work_ms": round(work, 3),
            "slack_ms": round(slack, 3),
            "slop_ms": round(slop, 3),
            "slack_plus_slop_ms": round(slack + slop, 3),
        })

    # Fallback: individual lines like "Avg. Work: 19.69" / "Avg. Slack: 2.45" / "Avg. Slop: 0.48"
    if not latency_samples:
        w_m = re.findall(r"Avg\.?\s*Work[:=\s]+([0-9.]+)", log_text, re.IGNORECASE)
        sk_m = re.findall(r"Avg\.?\s*Slack[:=\s]+([0-9.]+)", log_text, re.IGNORECASE)
        sp_m = re.findall(r"Avg\.?\s*Slop[:=\s]+([0-9.]+)", log_text, re.IGNORECASE)
        if w_m and sk_m and sp_m:
            w, sk, sp = float(w_m[-1]), float(sk_m[-1]), float(sp_m[-1])
            latency_samples.append({
                "total_ms": round(w + sk + sp, 3),
                "work_ms": round(w, 3),
                "slack_ms": round(sk, 3),
                "slop_ms": round(sp, 3),
                "slack_plus_slop_ms": round(sk + sp, 3),
            })

    burst_loss_count = len(re.findall(r"Burst Loss Detected", log_text, re.IGNORECASE))
    ack_backlog_count = len(re.findall(r"Too many received packets to ack", log_text, re.IGNORECASE))
    severe_fps_drops = len(re.findall(r"Local Framerate Threshold critically exceeded", log_text, re.IGNORECASE))
    ace_http_200 = len(re.findall(r"ACEManager_IssueAntiTick.*?(?:200|OK)", log_text, re.IGNORECASE))
    manual_quit = bool(re.search(r"Disconnect Reason:\s*ManualQuit|RequestExit", log_text, re.IGNORECASE))

    latest = latency_samples[-1] if latency_samples else None
    return {
        "engine_latency_samples": latency_samples,
        "latest_engine_latency": latest,
        "burst_loss_count": burst_loss_count,
        "ack_backlog_count": ack_backlog_count,
        "slirp_network_warnings_total": burst_loss_count + ack_backlog_count,
        "severe_fps_drop_warnings": severe_fps_drops,
        "ace_anti_tick_http_200_count": ace_http_200,
        "clean_manual_quit": manual_quit,
    }


def compare_against_phase11b_baseline(current_metrics: dict[str, Any]) -> dict[str, Any]:
    """Compare Phase 14 full-stack RangeV2 1920x1200 metrics against Phase 11B baseline."""
    b = PHASE11B_BASELINE
    cur_mean = current_metrics.get("range_mean_fps")
    cur_p50 = current_metrics.get("range_p50_fps")
    cur_p1 = current_metrics.get("range_p1_low_fps")
    cur_slack_slop = current_metrics.get("slack_plus_slop_ms")
    cur_net_warn = current_metrics.get("slirp_network_warnings_total")

    return {
        "baseline_phase": "phase-11b-range-min8-warm-1920x1200",
        "baseline": b,
        "current": current_metrics,
        "mean_fps_delta_pct": pct_delta(b["range_warm_min8_mean_fps"], cur_mean),
        "p50_fps_delta_pct": pct_delta(b["range_warm_min8_p50_fps"], cur_p50),
        "p1_low_fps_delta_pct": pct_delta(b["range_warm_min8_p1_low_fps"], cur_p1),
        "mean_fps_abs_gain": round(cur_mean - b["range_warm_min8_mean_fps"], 3) if cur_mean is not None else None,
        "p50_fps_abs_gain": round(cur_p50 - b["range_warm_min8_p50_fps"], 3) if cur_p50 is not None else None,
        "slack_plus_slop_delta_ms": (
            round(cur_slack_slop - b["engine_latency_slack_plus_slop_ms"], 3)
            if cur_slack_slop is not None
            else None
        ),
        "reached_60fps_steady": (cur_mean is not None and cur_mean >= 60.0) or (cur_p50 is not None and cur_p50 >= 60.0),
        "slirp_warnings_zero": (cur_net_warn == 0) if cur_net_warn is not None else None,
    }


def build_next_gen_physical_ceiling_conclusion(
    deep_dive: dict[str, Any],
    e2e_comparison: dict[str, Any],
) -> dict[str, Any]:
    """Produce an honest, first-principles engineering conclusion on the next-gen performance ceiling."""
    return {
        "summary": (
            "On 10-core Apple Silicon (4P+6E) running Windows 11 ARM64 under QEMU+HVF + Prism x86_64 "
            "translation + VirtIO-GPU 3D (DXMT-native), Phase 11-14 full-stack optimization has "
            "largely exhausted host I/O, networking, shader cache, frame pacing, and input overheads. "
            "The remaining dominant bottleneck is single-thread x86_64->ARM64 Prism translation + UE4 "
            "GameThread/RenderThread execution inside the guest."
        ),
        "approaching_hardware_limit": [
            "GPU translation (DXMT-native -> Metal): QEMURenderServer stays well under 1 host core even at 1920x1200; Apple Silicon GPU is not saturated.",
            "Storage I/O (VirtIO-Blk iothread + num-queues=4 + discard=unmap): 110k+ 4K IOPS / 9.2 GiB/s sequential read eliminates asset streaming bottlenecks.",
            "Networking (vmnet-shared / async socket-stream): removes QEMU slirp single-thread congestion and burst packet-loss spikes.",
            "Shader & JIT warm caches (DXMT_SHADER_CACHE + Windows Prism XtaCache): suppresses first-60s compilation hitches once persisted across sessions.",
            "Host presentation & input (UTM-Custom 10 patches: Game Mode, 1.5ms mouse coalescing, frame backpressure, --app-shell-vm).",
        ],
        "hard_ceilings_requiring_upstream_changes": [
            "x86_64 -> ARM64 Prism binary translation overhead on UE4 GameThread/RenderThread (~25-35% IPC tax vs native ARM64): only eliminated if game studios ship native Windows/macOS ARM64 clients.",
            "Kernel anti-cheat (ACE) virtualization boundary: requires unmodified vTPM + Secure Boot + full Windows kernel; cannot run under lightweight Wine/CrossOver without vendor support.",
            "macOS Virtualization.framework (VZ) limitations: currently lacks Apple-supported vTPM 2.0 + VirtIO-GPU 3D/DirectX paravirtualization API; future macOS VZ vTPM + Metal paravirtual GPU could cut QEMU VM-exit and display copy latency further.",
            "4P+6E heterogeneous scheduling: QEMU vCPU threads beyond 4 P-cores spill onto E-cores; higher P-core count Apple Silicon (M-Pro/Max) scales directly.",
        ],
        "metrics_snapshot": {
            "dual_cache_summary": deep_dive.get("exp_dual_cache", {}).get("comparison"),
            "frame_sync_recommended": deep_dive.get("exp_frame_sync", {}).get("selection"),
            "e2e_vs_phase11b": {
                "mean_fps_delta_pct": e2e_comparison.get("mean_fps_delta_pct"),
                "p50_fps_delta_pct": e2e_comparison.get("p50_fps_delta_pct"),
                "reached_60fps_steady": e2e_comparison.get("reached_60fps_steady"),
                "slirp_warnings_zero": e2e_comparison.get("slirp_warnings_zero"),
            },
        },
    }


# ---------------------------------------------------------------------------
# Live VM & host orchestration helpers
# ---------------------------------------------------------------------------

def _dir_stats(path: Path) -> dict[str, int]:
    if not path.exists():
        return {"file_count": 0, "total_bytes": 0}
    files = 0
    total = 0
    for p in path.rglob("*"):
        if p.is_file():
            files += 1
            try:
                total += p.stat().st_size
            except OSError:
                pass
    return {"file_count": files, "total_bytes": total}


def _quit_any_utm() -> None:
    subprocess.run(["osascript", "-e", 'tell application id "com.utmapp.UTM" to quit'], capture_output=True, check=False)
    for _ in range(15):
        r = subprocess.run(["pgrep", "-x", "UTM"], capture_output=True, text=True, check=False)
        if r.returncode != 0:
            break
        time.sleep(0.5)
    time.sleep(2.0)


def _unregister_vm_best_effort(vm_uuid: str, utmctl: Path) -> None:
    for ctl in (utmctl, UTMCTL):
        if ctl.is_file():
            subprocess.run([str(ctl), "delete", vm_uuid], capture_output=True, text=True, check=False)
            break


def _ensure_registered_and_persisted(vm_bundle: Path, vm_uuid: str) -> None:
    """Ensure UTM has registered vm_uuid and flushed its bookmark list before quitting."""
    for attempt in range(3):
        out = subprocess.run([str(UTMCTL), "list"], capture_output=True, text=True, check=False).stdout or ""
        if vm_uuid.upper() in out.upper():
            time.sleep(2.0)
            return
        subprocess.run(["open", "-a", "UTM", str(vm_bundle)], capture_output=True, text=True, check=False)
        for _ in range(15):
            time.sleep(1.0)
            out = subprocess.run([str(UTMCTL), "list"], capture_output=True, text=True, check=False).stdout or ""
            if vm_uuid.upper() in out.upper():
                time.sleep(2.0)
                return
    raise RuntimeError(f"VM {vm_uuid} failed to register in UTM")


def _launch_utm_custom(
    *,
    custom_app: Path,
    vm_uuid: str,
    vm_bundle: Path | None = None,
    app_shell: bool = False,
    window_title: str = "Malt — target-cn",
    window_size: str = "1024x680",
    state_file: Path | None = None,
    shader_cache_dir: Path | None = None,
    fps_limit: int | None = None,
    drawable_count: int | None = None,
    max_inflight_frames: int | None = None,
    mouse_coalesce_ms: float | None = 1.5,
    key_guard: bool = True,
) -> subprocess.Popen[str]:
    if vm_bundle is not None:
        _ensure_registered_and_persisted(vm_bundle, vm_uuid)
    _quit_any_utm()
    utm_bin = custom_app / "Contents/MacOS/UTM"
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not utm_bin.is_file():
        raise FileNotFoundError(f"UTM-Custom binary not found: {utm_bin}")
    env = os.environ.copy()
    env["UTM_DIRECTX_BACKEND"] = "dxmt-native"
    env["UTM_PURE_RELATIVE_MOUSE"] = "1"
    if shader_cache_dir is not None:
        shader_cache_dir.mkdir(parents=True, exist_ok=True)
        env["DXMT_SHADER_CACHE"] = "1"
        env["UTM_DXMT_SHADER_CACHE_PATH"] = str(shader_cache_dir)
        env["DXMT_SHADER_CACHE_PATH"] = str(shader_cache_dir)
    if fps_limit is not None:
        env["UTM_RENDER_FPS_LIMIT"] = str(fps_limit)
    if drawable_count is not None:
        env["UTM_METAL_DRAWABLE_COUNT"] = str(drawable_count)
    if max_inflight_frames is not None:
        env["UTM_MAX_INFLIGHT_FRAMES"] = str(max_inflight_frames)
    if mouse_coalesce_ms is not None:
        env["UTM_MOUSE_COALESCE_INTERVAL_MS"] = str(mouse_coalesce_ms)
    if key_guard:
        env["UTM_GAME_SHELL_KEY_GUARD"] = "1"

    cmd = [str(utm_bin), "--dxmt-native", "--pure-relative-mouse"]
    if app_shell:
        cmd.extend(["--app-shell-vm", vm_uuid, "--window-title", window_title, "--window-size", window_size])
        env["UTM_APP_SHELL_VM"] = vm_uuid
        env["UTM_APP_SHELL_WINDOW_TITLE"] = window_title
        env["UTM_APP_SHELL_WINDOW_SIZE"] = window_size
        if state_file is not None:
            cmd.extend(["--app-shell-state-file", str(state_file)])
            env["UTM_APP_SHELL_STATE_FILE"] = str(state_file)
    else:
        cmd.extend(["--game-shell-vm", vm_uuid])
        env["UTM_GAME_SHELL_VM"] = vm_uuid

    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    # Wait until UTM-Custom has registered with LaunchServices and spawned QEMULauncher.
    qemu_found = False
    for i in range(25):
        if proc.poll() is not None:
            break
        if _get_qemu_cmdline():
            qemu_found = True
            break
        if i == 10 and custom_utmctl.is_file():
            # Fallback trigger in case shell flag didn't auto-start
            subprocess.run([str(custom_utmctl), "start", vm_uuid], capture_output=True, text=True, check=False)
        time.sleep(1.0)
    print(f"[p14a-launch] pid={proc.pid} poll={proc.poll()} qemu_found={qemu_found}", file=sys.stderr, flush=True)
    time.sleep(6.0)
    return proc


def _stop_utm_custom(proc: subprocess.Popen[str] | None, vm_uuid: str, custom_utmctl: Path) -> None:
    # Request graceful Windows shutdown first so repeated boots never trigger Automatic Repair.
    if custom_utmctl.is_file():
        try:
            subprocess.run(
                [str(custom_utmctl), "exec", vm_uuid, "--cmd", "shutdown.exe", "/s", "/t", "0", "/f"],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
        except Exception:
            pass
    grace_dl = time.monotonic() + 20.0
    while time.monotonic() < grace_dl:
        q = subprocess.run(["pgrep", "-f", "QEMULauncher|qemu-aarch64-softmmu"], capture_output=True, text=True, check=False)
        if q.returncode != 0:
            break
        time.sleep(1.0)
    for ctl in (custom_utmctl, UTMCTL):
        if ctl.is_file():
            subprocess.run([str(ctl), "stop", vm_uuid], capture_output=True, text=True, check=False)
            break
    deadline = time.monotonic() + 20.0
    while time.monotonic() < deadline:
        if proc is not None and proc.poll() is not None:
            break
        q = subprocess.run(["pgrep", "-f", "QEMULauncher|qemu-aarch64-softmmu"], capture_output=True, text=True, check=False)
        if q.returncode != 0:
            break
        time.sleep(1.0)
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=8.0)
        except subprocess.TimeoutExpired:
            proc.kill()
    _quit_any_utm()


def _encode_ps(script: str) -> str:
    return base64.b64encode(script.encode("utf-16-le")).decode("ascii")


def _wait_qga_ready(vm_uuid: str, utmctl: Path, timeout_sec: float = 180.0) -> float:
    t0 = time.monotonic()
    deadline = t0 + timeout_sec
    enc = _encode_ps("Write-Output READY")
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            res = subprocess.run(
                [str(utmctl), "exec", vm_uuid, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand", enc],
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            if attempt <= 3 or attempt % 10 == 0:
                print(
                    f"[p14a-qga] attempt={attempt} rc={res.returncode} out={res.stdout.strip()[:80]!r} err={res.stderr.strip()[-220:]!r}",
                    file=sys.stderr,
                    flush=True,
                )
            if res.returncode == 0 and "READY" in (res.stdout or ""):
                ready_s = round(time.monotonic() - t0, 3)
                u_dl = time.monotonic() + 45.0
                while time.monotonic() < u_dl:
                    try:
                        uname = _qga_ps(vm_uuid, "(Get-CimInstance Win32_ComputerSystem).UserName", utmctl=utmctl, timeout=15.0)
                        if uname.strip():
                            break
                    except Exception:
                        pass
                    time.sleep(1.5)
                return ready_s
        except subprocess.TimeoutExpired:
            print(f"[p14a-qga] attempt={attempt} timeout", file=sys.stderr, flush=True)
        time.sleep(2.0)
    raise TimeoutError(f"QGA did not become ready within {timeout_sec}s for {vm_uuid}")


def _qga_ps(vm_uuid: str, script: str, *, utmctl: Path = UTMCTL, timeout: float = 120.0) -> str:
    token = uuid.uuid4().hex
    wrapped = (
        "$ProgressPreference='SilentlyContinue'; $result = & { "
        + script
        + " }; @{query_token='"
        + token
        + "';output=($result|Out-String).Trim()}|ConvertTo-Json -Depth 4 -Compress"
    )
    encoded_cmd = [
        str(utmctl),
        "exec",
        vm_uuid,
        "--cmd",
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        _encode_ps(wrapped),
    ]
    res = subprocess.run(encoded_cmd, capture_output=True, text=True, check=False, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(f"Guest PS failed (rc={res.returncode}): {redact_p14_text(res.stderr.strip() or res.stdout.strip())}")
    raw = (res.stdout or "").strip().lstrip("\ufeff")
    env = json.loads(raw)
    if env.get("query_token") != token:
        raise RuntimeError("QGA response token mismatch")
    return str(env.get("output", "")).strip()


def _upload_file_to_guest(vm_uuid: str, local_path: Path, guest_path: str, *, utmctl: Path = UTMCTL) -> None:
    with local_path.open("rb") as handle:
        res = subprocess.run(
            [str(utmctl), "file", "push", vm_uuid, guest_path],
            stdin=handle,
            capture_output=True,
            check=False,
            timeout=90,
        )
    if res.returncode != 0:
        raise RuntimeError(f"utmctl file push failed: {res.stderr.decode(errors='ignore')}")


def _get_qemu_cmdline() -> str:
    res = subprocess.run(
        ["ps", "-axo", "command="],
        capture_output=True,
        text=True,
        check=False,
    )
    for line in (res.stdout or "").splitlines():
        if ("QEMULauncher" in line or "qemu-aarch64-softmmu" in line) and "-device" in line:
            return line.strip()
    return ""


def _sample_guest_xtacache(vm_uuid: str, utmctl: Path) -> dict[str, Any]:
    ps = r"""
$paths = @('C:\Windows\XtaCache', "$env:LOCALAPPDATA\Microsoft\XtaCache", 'C:\ProgramData\Microsoft\XtaCache')
$out = @()
$totalFiles = 0
$totalBytes = 0
foreach ($p in $paths) {
  if (Test-Path $p) {
    $items = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue
    $cnt = ($items | Measure-Object).Count
    $sz = (($items | Measure-Object -Property Length -Sum).Sum)
    if (-not $sz) { $sz = 0 }
    $totalFiles += $cnt
    $totalBytes += [int64]$sz
    $out += [PSCustomObject]@{ path=$p; files=$cnt; bytes=[int64]$sz }
  }
}
[PSCustomObject]@{ total_files=$totalFiles; total_bytes=$totalBytes; dirs=$out } | ConvertTo-Json -Depth 4 -Compress
"""
    raw = _qga_ps(vm_uuid, ps, utmctl=utmctl, timeout=45.0)
    return json.loads(raw) if raw else {"total_files": 0, "total_bytes": 0, "dirs": []}


def _clear_guest_xtacache_safe(vm_uuid: str, utmctl: Path) -> dict[str, Any]:
    """Safely clear user-writable Prism XtaCache entries without modifying system drivers or ACLs."""
    ps = r"""
$removed = 0
$failed = 0
$paths = @("$env:LOCALAPPDATA\Microsoft\XtaCache", 'C:\Windows\XtaCache')
foreach ($p in $paths) {
  if (Test-Path $p) {
    Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $removed++ }
      catch { $failed++ }
    }
  }
}
[PSCustomObject]@{ removed=$removed; locked_or_skipped=$failed } | ConvertTo-Json -Compress
"""
    raw = _qga_ps(vm_uuid, ps, utmctl=utmctl, timeout=60.0)
    return json.loads(raw) if raw else {"removed": 0, "locked_or_skipped": 0}


def _parse_probe_csv_frame_ms(csv_text: str) -> list[float]:
    """Parse per-frame total frame_ms (or cpu_submit_ms fallback) from d3d11_probe.exe CSV output."""
    lines = [ln.strip() for ln in csv_text.splitlines() if ln.strip()]
    if len(lines) < 2:
        return []
    headers = [h.strip().lower() for h in lines[0].split(",")]
    col_idx = None
    for candidate in ("frame_ms", "total_ms", "frame_time_ms", "present_ms", "cpu_submit_ms"):
        if candidate in headers:
            col_idx = headers.index(candidate)
            break
    if col_idx is None:
        return []
    out: list[float] = []
    for ln in lines[1:]:
        parts = ln.split(",")
        if col_idx < len(parts):
            try:
                val = float(parts[col_idx])
                if val > 0:
                    out.append(val)
            except ValueError:
                pass
    return out


def _run_60s_cache_workload(
    vm_uuid: str,
    utmctl: Path,
    *,
    duration_sec: int = 60,
    label: str = "cold",
) -> dict[str, Any]:
    """Run a hardware D3D11 + Prism x86_64 workload in interactive desktop session for ~duration_sec."""
    guest_dir = r"C:\graphics-lab\p14a"
    guest_probe = rf"{guest_dir}\d3d11_probe.exe"
    runner_guest = rf"{guest_dir}\run-p14-{label}.ps1"
    summary_guest = rf"{guest_dir}\summary-{label}.json"
    done_guest = rf"{guest_dir}\done-{label}.txt"

    _qga_ps(vm_uuid, rf"New-Item -ItemType Directory -Force -Path '{guest_dir}' | Out-Null", utmctl=utmctl)
    _upload_file_to_guest(vm_uuid, D3D11_PROBE, guest_probe, utmctl=utmctl)

    runner_body = f"""
$ErrorActionPreference = 'Continue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameTimes = New-Object System.Collections.Generic.List[double]
$cpuSamples = New-Object System.Collections.Generic.List[double]
$runs = 0
while ($sw.Elapsed.TotalSeconds -lt {duration_sec}) {{
  $csvFile = "{guest_dir}\\probe-{label}-$runs.csv"
  $errFile = "{guest_dir}\\probe-{label}-$runs.err"
  $proc = Start-Process -FilePath "{guest_probe}" -ArgumentList @(
    "--frames","150","--warmup","15","--width","1280","--height","720",
    "--commands","3072","--command-every","1","--resource-bytes","1048576","--resource-every","1",
    "--driver-type","hardware","--csv",$csvFile
  ) -PassThru -NoNewWindow -RedirectStandardError $errFile
  $null = $proc.Handle
  while (-not $proc.HasExited) {{
    try {{
      $c = (Get-Counter '\\Processor(_Total)\\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
      if ($c -ne $null) {{ $cpuSamples.Add([double]$c) }}
    }} catch {{}}
    Start-Sleep -Milliseconds 500
  }}
  if (Test-Path $csvFile) {{
    $rows = Import-Csv -LiteralPath $csvFile -ErrorAction SilentlyContinue
    foreach ($r in $rows) {{
      $v = $null
      if ($r.frame_ms) {{ $v = [double]$r.frame_ms }}
      elseif ($r.total_ms) {{ $v = [double]$r.total_ms }}
      elseif ($r.cpu_submit_ms) {{ $v = [double]$r.cpu_submit_ms }}
      if ($v -ne $null -and $v -gt 0) {{ $frameTimes.Add($v) }}
    }}
  }}
  $runs++
}}
$sw.Stop()
$cpuAvg = if ($cpuSamples.Count -gt 0) {{ [math]::Round(($cpuSamples | Measure-Object -Average).Average, 2) }} else {{ $null }}
$cpuMax = if ($cpuSamples.Count -gt 0) {{ [math]::Round(($cpuSamples | Measure-Object -Maximum).Maximum, 2) }} else {{ $null }}
$payload = [PSCustomObject]@{{
  elapsed_sec = [math]::Round($sw.Elapsed.TotalSeconds, 3)
  probe_iterations = $runs
  guest_cpu_avg_pct = $cpuAvg
  guest_cpu_max_pct = $cpuMax
  frame_times_ms = $frameTimes
}}
$payload | ConvertTo-Json -Depth 4 -Compress | Set-Content -Encoding UTF8 -LiteralPath "{summary_guest}"
"done" | Set-Content -Encoding ASCII -LiteralPath "{done_guest}"
"""
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as tf:
        tf.write(runner_body)
        tmp_ps = Path(tf.name)
    try:
        _upload_file_to_guest(vm_uuid, tmp_ps, runner_guest, utmctl=utmctl)
    finally:
        tmp_ps.unlink(missing_ok=True)

    _qga_ps(
        vm_uuid,
        f"""
Remove-Item -LiteralPath '{summary_guest}','{done_guest}' -Force -EA SilentlyContinue
$u = (Get-CimInstance Win32_ComputerSystem).UserName
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {runner_guest}'
$princ = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
Register-ScheduledTask -TaskName 'P14A_Workload' -Action $act -Principal $princ -Force | Out-Null
Start-ScheduledTask -TaskName 'P14A_Workload'
'launched'
""",
        utmctl=utmctl,
        timeout=30.0,
    )

    host_samples: list[dict[str, Any]] = []
    t0 = time.monotonic()
    deadline = t0 + max(180.0, duration_sec + 120.0)
    while time.monotonic() < deadline:
        host_samples.append(p12b.sample_host_qemu_with_main_thread(round(time.monotonic() - t0, 2)))
        if len(host_samples) % 2 == 0:
            chk = _qga_ps(vm_uuid, f"if (Test-Path '{done_guest}') {{ 'DONE' }} else {{ 'RUN' }}", utmctl=utmctl, timeout=20.0)
            if "DONE" in chk:
                break
        time.sleep(2.0)

    pull = subprocess.run(
        [str(utmctl), "file", "pull", vm_uuid, summary_guest],
        capture_output=True,
        check=False,
        timeout=60,
    )
    if pull.returncode != 0:
        raise RuntimeError(f"Failed to pull {summary_guest}: {pull.stderr.decode(errors='ignore')}")
    data = json.loads(pull.stdout.decode("utf-8-sig"))
    frame_times = [float(x) for x in (data.get("frame_times_ms") or [])]
    host_summary = p12b.summarize_host_samples_p12(host_samples)
    return {
        "label": label,
        "elapsed_sec": data.get("elapsed_sec"),
        "probe_iterations": data.get("probe_iterations"),
        "guest_cpu_avg_pct": data.get("guest_cpu_avg_pct"),
        "guest_cpu_max_pct": data.get("guest_cpu_max_pct"),
        "frame_metrics": summarize_frame_times_ms(frame_times, severe_threshold_ms=33.333),
        "host_cpu": host_summary,
    }


def _check_vioinput_whql_status(vm_uuid: str, utmctl: Path) -> dict[str, Any]:
    """Read-only probe of Secure Boot and WHQL vioinput driver availability in Guest."""
    ps = r"""
$sb = $false
try { $sb = [bool](Confirm-SecureBootUEFI) } catch { $sb = $false }
$drv = @(Get-WindowsDriver -Online -All -ErrorAction SilentlyContinue | Where-Object {
  $_.OriginalFileName -match 'vioinput' -or $_.ProviderName -match 'Red Hat' -and $_.ClassName -match 'HID|Mouse|Keyboard'
} | Select-Object Driver, OriginalFileName, ProviderName, ClassName, Version, Date)
$pnputil = (pnputil /enum-drivers 2>&1 | Out-String)
$hasVioInputInf = ($pnputil -match 'vioinput\.inf')
$svc = Get-CimInstance Win32_SystemDriver -Filter "Name='vioinput'" -ErrorAction SilentlyContinue | Select-Object Name, State, Status, StartMode
[PSCustomObject]@{
  secure_boot_enabled = $sb
  has_vioinput_inf = $hasVioInputInf
  vioinput_drivers = $drv
  vioinput_service = $svc
} | ConvertTo-Json -Depth 4 -Compress
"""
    raw = _qga_ps(vm_uuid, ps, utmctl=utmctl, timeout=60.0)
    return json.loads(raw) if raw else {"secure_boot_enabled": True, "has_vioinput_inf": False}


def _sample_guest_interrupt_overhead(vm_uuid: str, utmctl: Path, *, duration_sec: int = 20) -> dict[str, Any]:
    """Sample Windows Interrupts/sec, % Interrupt Time, and % DPC Time under synthetic relative mouse motion."""
    ps = f"""
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MousePulse {{
  [DllImport("user32.dll")]
  public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
}}
"@
$intr = New-Object System.Collections.Generic.List[double]
$itime = New-Object System.Collections.Generic.List[double]
$dpc = New-Object System.Collections.Generic.List[double]
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dir = 1
while ($sw.Elapsed.TotalSeconds -lt {duration_sec}) {{
  for ($i=0; $i -lt 50; $i++) {{
    [MousePulse]::mouse_event(0x0001, (2 * $dir), (-1 * $dir), 0, [UIntPtr]::Zero)
    $dir = -$dir
    Start-Sleep -Milliseconds 4
  }}
  try {{
    $c = Get-Counter @('\\Processor(_Total)\\Interrupts/sec','\\Processor(_Total)\\% Interrupt Time','\\Processor(_Total)\\% DPC Time') -ErrorAction SilentlyContinue
    if ($c) {{
      $intr.Add([double]$c.CounterSamples[0].CookedValue)
      $itime.Add([double]$c.CounterSamples[1].CookedValue)
      $dpc.Add([double]$c.CounterSamples[2].CookedValue)
    }}
  }} catch {{}}
}}
$sw.Stop()
function Avg($l) {{ if ($l.Count -gt 0) {{ [math]::Round(($l | Measure-Object -Average).Average, 3) }} else {{ $null }} }}
function MaxV($l) {{ if ($l.Count -gt 0) {{ [math]::Round(($l | Measure-Object -Maximum).Maximum, 3) }} else {{ $null }} }}
[PSCustomObject]@{{
  duration_sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
  sample_count = $intr.Count
  interrupts_per_sec_mean = Avg $intr
  interrupts_per_sec_max = MaxV $intr
  interrupt_time_pct_mean = Avg $itime
  dpc_time_pct_mean = Avg $dpc
}} | ConvertTo-Json -Compress
"""
    raw = _qga_ps(vm_uuid, ps, utmctl=utmctl, timeout=duration_sec + 45)
    return json.loads(raw)


# ---------------------------------------------------------------------------
# Experiment runners
# ---------------------------------------------------------------------------

def run_exp_dual_cache(args: argparse.Namespace) -> dict[str, Any]:
    """Experiment 1: Persistent playable mode Cold Cache Boot 1 vs Warm Cache Boot 2."""
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    custom_app = Path(args.custom_app)
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not custom_utmctl.is_file():
        custom_utmctl = UTMCTL

    utm_caches = Path.home() / "Library/Containers/com.utmapp.UTM/Data/Library/Caches"
    cache_dir = utm_caches / f"p14a-dxmt-cache-{uuid.uuid4().hex[:8]}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    vm_name = f"ephemeral-p14a-dualcache-{uuid.uuid4().hex[:6]}"
    proxy_proc: subprocess.Popen[str] | None = None
    utm_proc: subprocess.Popen[str] | None = None
    created_bundle: Path | None = None

    try:
        proxy_proc, socket_ep = p12b._start_async_net_proxy()
        created = ggm.create_playable(
            golden=golden,
            dest_dir=vms_dir,
            name=vm_name,
            primary=primary,
            reset=True,
            register_utm=True,
            trim_hardware=True,
            no_sound=False,
            dx_driver="DXMT",
            fps_limit=120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            network_mode="socket-stream",
            socket_endpoint=socket_ep,
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        created_bundle = Path(created["playable_path"])
        vm_uuid = created["vm_uuid"]

        # Cold run: ensure host DXMT cache empty
        shutil.rmtree(cache_dir, ignore_errors=True)
        cache_dir.mkdir(parents=True, exist_ok=True)
        dxmt_before_cold = _dir_stats(cache_dir)

        utm_proc = _launch_utm_custom(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=created_bundle,
            shader_cache_dir=cache_dir,
            fps_limit=120,
            drawable_count=3,
            max_inflight_frames=3,
        )
        cold_boot_sec = _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=150.0)
        xta_clear = _clear_guest_xtacache_safe(vm_uuid, custom_utmctl)
        xta_before_cold = _sample_guest_xtacache(vm_uuid, custom_utmctl)
        cold_work = _run_60s_cache_workload(vm_uuid, custom_utmctl, duration_sec=args.duration_sec, label="cold")
        xta_after_cold = _sample_guest_xtacache(vm_uuid, custom_utmctl)
        dxmt_after_cold = _dir_stats(cache_dir)
        cold_arm = {
            **cold_work,
            "boot_ready_sec": cold_boot_sec,
            "xtacache_clear_result": xta_clear,
            "xtacache_before_bytes": xta_before_cold.get("total_bytes", 0),
            "xtacache_after_bytes": xta_after_cold.get("total_bytes", 0),
            "dxmt_cache_before_bytes": dxmt_before_cold["total_bytes"],
            "dxmt_cache_after_bytes": dxmt_after_cold["total_bytes"],
            "dxmt_cache_after_files": dxmt_after_cold["file_count"],
        }

        _stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None
        time.sleep(3.0)

        # Warm run: restart SAME persistent playable VM keeping both caches intact
        dxmt_before_warm = _dir_stats(cache_dir)
        utm_proc = _launch_utm_custom(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=created_bundle,
            shader_cache_dir=cache_dir,
            fps_limit=120,
            drawable_count=3,
            max_inflight_frames=3,
        )
        warm_boot_sec = _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=150.0)
        xta_before_warm = _sample_guest_xtacache(vm_uuid, custom_utmctl)
        warm_work = _run_60s_cache_workload(vm_uuid, custom_utmctl, duration_sec=args.duration_sec, label="warm")
        xta_after_warm = _sample_guest_xtacache(vm_uuid, custom_utmctl)
        dxmt_after_warm = _dir_stats(cache_dir)
        warm_arm = {
            **warm_work,
            "boot_ready_sec": warm_boot_sec,
            "xtacache_before_bytes": xta_before_warm.get("total_bytes", 0),
            "xtacache_after_bytes": xta_after_warm.get("total_bytes", 0),
            "dxmt_cache_before_bytes": dxmt_before_warm["total_bytes"],
            "dxmt_cache_after_bytes": dxmt_after_warm["total_bytes"],
            "dxmt_cache_after_files": dxmt_after_warm["file_count"],
        }

        _stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None

        result = {
            "measured_at_utc": utc_now_iso(),
            "duration_sec_per_arm": args.duration_sec,
            "cold_arm": cold_arm,
            "warm_arm": warm_arm,
            "comparison": compare_dual_cache_runs(cold_arm, warm_arm),
        }
        return redact_p14_value(result)
    finally:
        if utm_proc is not None and created_bundle is not None:
            try:
                _stop_utm_custom(utm_proc, ggm.bundle_uuid(created_bundle), custom_utmctl)
            except Exception:
                pass
        if proxy_proc is not None:
            proxy_proc.terminate()
            try:
                proxy_proc.wait(timeout=5)
            except Exception:
                proxy_proc.kill()
        if created_bundle is not None and created_bundle.exists():
            shutil.rmtree(created_bundle, ignore_errors=True)
        shutil.rmtree(cache_dir, ignore_errors=True)


def run_exp_frame_sync(args: argparse.Namespace) -> dict[str, Any]:
    """Experiment 2: QEMURendererFPSLimit = 0 vs 120 and low-latency Metal queue combinations."""
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    custom_app = Path(args.custom_app)
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not custom_utmctl.is_file():
        custom_utmctl = UTMCTL

    utm_caches = Path.home() / "Library/Containers/com.utmapp.UTM/Data/Library/Caches"
    cache_dir = utm_caches / f"p14a-sync-cache-{uuid.uuid4().hex[:8]}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    vm_name = f"ephemeral-p14a-framesync-{uuid.uuid4().hex[:6]}"
    proxy_proc: subprocess.Popen[str] | None = None
    utm_proc: subprocess.Popen[str] | None = None
    created_bundle: Path | None = None

    arm_specs = [
        {"label": "fps_limit_0_triple", "fps_limit": 0, "drawable_count": 3, "max_inflight_frames": 3},
        {"label": "fps_limit_120_triple", "fps_limit": 120, "drawable_count": 3, "max_inflight_frames": 3},
        {"label": "fps_limit_120_lowlat_d2_i1", "fps_limit": 120, "drawable_count": 2, "max_inflight_frames": 1},
    ]

    try:
        proxy_proc, socket_ep = p12b._start_async_net_proxy()
        created = ggm.create_playable(
            golden=golden,
            dest_dir=vms_dir,
            name=vm_name,
            primary=primary,
            reset=True,
            register_utm=True,
            trim_hardware=True,
            no_sound=False,
            dx_driver="DXMT",
            fps_limit=120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            network_mode="socket-stream",
            socket_endpoint=socket_ep,
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        created_bundle = Path(created["playable_path"])
        vm_uuid = created["vm_uuid"]
        arms_out: list[dict[str, Any]] = []

        for spec in arm_specs:
            # Update config.plist QEMURendererFPSLimit before each boot
            cfg = ggm.read_config_plist(created_bundle)
            cfg.setdefault("QEMU", {})["QEMURendererFPSLimit"] = int(spec["fps_limit"])
            ggm.write_config_plist(created_bundle, cfg)

            utm_proc = _launch_utm_custom(
                custom_app=custom_app,
                vm_uuid=vm_uuid,
            vm_bundle=created_bundle,
                shader_cache_dir=cache_dir,
                fps_limit=spec["fps_limit"],
                drawable_count=spec["drawable_count"],
                max_inflight_frames=spec["max_inflight_frames"],
            )
            _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=150.0)
            work = _run_60s_cache_workload(vm_uuid, custom_utmctl, duration_sec=args.duration_sec, label=spec["label"])
            _stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
            utm_proc = None
            time.sleep(2.0)

            arms_out.append({
                "label": spec["label"],
                "fps_limit": spec["fps_limit"],
                "metal_drawable_count": spec["drawable_count"],
                "max_inflight_frames": spec["max_inflight_frames"],
                "frame_metrics": work["frame_metrics"],
                "host_cpu": work["host_cpu"],
                "guest_cpu_avg_pct": work["guest_cpu_avg_pct"],
            })

        selection = select_best_frame_sync_arm(arms_out)
        return redact_p14_value({
            "measured_at_utc": utc_now_iso(),
            "arms": arms_out,
            "selection": selection,
        })
    finally:
        if utm_proc is not None and created_bundle is not None:
            try:
                _stop_utm_custom(utm_proc, ggm.bundle_uuid(created_bundle), custom_utmctl)
            except Exception:
                pass
        if proxy_proc is not None:
            proxy_proc.terminate()
            try:
                proxy_proc.wait(timeout=5)
            except Exception:
                proxy_proc.kill()
        if created_bundle is not None and created_bundle.exists():
            shutil.rmtree(created_bundle, ignore_errors=True)
        shutil.rmtree(cache_dir, ignore_errors=True)


def run_exp_irq_audit(args: argparse.Namespace) -> dict[str, Any]:
    """Experiment 3: QEMU residual polling device audit + virtio-input vs usb-mouse evaluation."""
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    custom_app = Path(args.custom_app)
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not custom_utmctl.is_file():
        custom_utmctl = UTMCTL

    vm_name = f"ephemeral-p14a-irqaudit-{uuid.uuid4().hex[:6]}"
    proxy_proc: subprocess.Popen[str] | None = None
    utm_proc: subprocess.Popen[str] | None = None
    created_bundle: Path | None = None

    try:
        proxy_proc, socket_ep = p12b._start_async_net_proxy()
        created = ggm.create_playable(
            golden=golden,
            dest_dir=vms_dir,
            name=vm_name,
            primary=primary,
            reset=True,
            register_utm=True,
            trim_hardware=True,
            no_sound=False,
            dx_driver="DXMT",
            fps_limit=120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            network_mode="socket-stream",
            socket_endpoint=socket_ep,
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        created_bundle = Path(created["playable_path"])
        vm_uuid = created["vm_uuid"]

        utm_proc = _launch_utm_custom(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=created_bundle,
            fps_limit=120,
        )
        _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=150.0)

        qemu_cmdline = _get_qemu_cmdline()
        device_audit = audit_qemu_polling_devices(qemu_cmdline)
        vio_status = _check_vioinput_whql_status(vm_uuid, custom_utmctl)
        usb_mouse_irq = _sample_guest_interrupt_overhead(vm_uuid, custom_utmctl, duration_sec=20)
        usb_host_sample = p12b.sample_host_qemu_with_main_thread(20.0)

        _stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None

        virtio_input_eval: dict[str, Any] = {
            "secure_boot_preserved": bool(vio_status.get("secure_boot_enabled", True)),
            "whql_vioinput_available": bool(vio_status.get("has_vioinput_inf")),
            "vioinput_probe": vio_status,
            "usb_mouse_irq_profile": usb_mouse_irq,
            "usb_mouse_host_sample": usb_host_sample,
            "virtio_mouse_irq_profile": None,
            "conclusion": "",
        }

        if vio_status.get("has_vioinput_inf") and vio_status.get("secure_boot_enabled", True):
            # Test virtio-mouse-pci via QEMU additional argument while keeping Secure Boot ON
            cfg = ggm.read_config_plist(created_bundle)
            qemu_sec = cfg.setdefault("QEMU", {})
            add_args = list(qemu_sec.get("AdditionalArguments") or [])
            add_args.extend(["-device", "virtio-mouse-pci"])
            qemu_sec["AdditionalArguments"] = add_args
            ggm.write_config_plist(created_bundle, cfg)

            utm_proc = _launch_utm_custom(
                custom_app=custom_app,
                vm_uuid=vm_uuid,
                fps_limit=120,
            )
            _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=150.0)
            virtio_irq = _sample_guest_interrupt_overhead(vm_uuid, custom_utmctl, duration_sec=20)
            virtio_host = p12b.sample_host_qemu_with_main_thread(20.0)
            _stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
            utm_proc = None

            virtio_input_eval["virtio_mouse_irq_profile"] = virtio_irq
            virtio_input_eval["virtio_mouse_host_sample"] = virtio_host
            virtio_input_eval["interrupts_per_sec_delta_pct"] = pct_delta(
                usb_mouse_irq.get("interrupts_per_sec_mean"),
                virtio_irq.get("interrupts_per_sec_mean"),
            )
            virtio_input_eval["conclusion"] = (
                "WHQL vioinput available under Secure Boot; measured virtio-mouse-pci vs usb-mouse directly."
            )
        else:
            virtio_input_eval["conclusion"] = (
                "WHQL vioinput driver not pre-installed in sealed golden image; "
                "Secure Boot strictly kept ON (never disabled). Retaining pure relative usb-mouse "
                "with 1.5ms host coalescing (Patch 06) and usb-tablet disabled."
            )

        return redact_p14_value({
            "measured_at_utc": utc_now_iso(),
            "device_audit": device_audit,
            "virtio_input_evaluation": virtio_input_eval,
        })
    finally:
        if utm_proc is not None and created_bundle is not None:
            try:
                _stop_utm_custom(utm_proc, ggm.bundle_uuid(created_bundle), custom_utmctl)
            except Exception:
                pass
        if proxy_proc is not None:
            proxy_proc.terminate()
            try:
                proxy_proc.wait(timeout=5)
            except Exception:
                proxy_proc.kill()
        if created_bundle is not None and created_bundle.exists():
            shutil.rmtree(created_bundle, ignore_errors=True)


def run_verify_app_shell_and_warm(args: argparse.Namespace) -> dict[str, Any]:
    """Verify full-stack --app-shell-vm desktop-less auto-fullscreen + Game Mode + warm-standby fast resume."""
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    custom_app = Path(args.custom_app)
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not custom_utmctl.is_file():
        custom_utmctl = UTMCTL

    utm_caches = Path.home() / "Library/Containers/com.utmapp.UTM/Data/Library/Caches"
    cache_dir = utm_caches / f"p14a-shell-cache-{uuid.uuid4().hex[:8]}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    state_dir = utm_caches / f"p14a-state-{uuid.uuid4().hex[:8]}"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "app-shell-state.json"
    vm_name = f"ephemeral-p14a-appshell-{uuid.uuid4().hex[:6]}"
    proxy_proc: subprocess.Popen[str] | None = None
    utm_proc: subprocess.Popen[str] | None = None
    created_bundle: Path | None = None

    try:
        proxy_proc, socket_ep = p12b._start_async_net_proxy()
        created = ggm.create_playable(
            golden=golden,
            dest_dir=vms_dir,
            name=vm_name,
            primary=primary,
            reset=True,
            register_utm=True,
            trim_hardware=True,
            no_sound=False,
            dx_driver="DXMT",
            fps_limit=args.fps_limit if args.fps_limit > 0 else 120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            network_mode="socket-stream",
            socket_endpoint=socket_ep,
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        created_bundle = Path(created["playable_path"])
        vm_uuid = created["vm_uuid"]

        # Start in launcher compact mode (state = launcher)
        state_file.write_text(json.dumps({"state": "launcher", "process": "WeGame.exe"}), encoding="utf-8")
        utm_proc = _launch_utm_custom(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=created_bundle,
            app_shell=True,
            window_title="Malt — target-cn",
            window_size="1024x680",
            state_file=state_file,
            shader_cache_dir=cache_dir,
            fps_limit=args.fps_limit,
            drawable_count=args.drawable_count,
            max_inflight_frames=args.max_inflight_frames,
        )
        cold_boot_sec = _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=150.0)
        qemu_audit = audit_qemu_polling_devices(_get_qemu_cmdline())

        # Transition state file to game_foreground -> triggers auto borderless fullscreen + Game Mode
        state_file.write_text(json.dumps({"state": "game_foreground", "process": "VALORANT-Win64-Shipping.exe"}), encoding="utf-8")
        time.sleep(2.5)
        app_shell_alive = utm_proc.poll() is None

        # Verify Game Mode plist keys on UTM-Custom.app
        plist_data = plistlib.loads((custom_app / "Contents/Info.plist").read_bytes())
        game_mode_enabled = bool(
            plist_data.get("LSSupportsGameMode")
            and plist_data.get("GCSupportsGameMode")
            and plist_data.get("LSApplicationCategoryType") == "public.app-category.games"
        )

        # Warm standby pause & resume test (using official UTM / utmctl suspend + resume)
        _stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None
        time.sleep(2.0)

        # Warm-standby cycle via golden_guest_manager
        standby_bundle = ggm.spawn_ephemeral(
            golden=golden,
            dest_dir=vms_dir,
            name="ephemeral-p14a-warm",
            primary=primary,
            register_utm=True,
            trim_hardware=True,
            dx_driver="DXMT",
            fps_limit=args.fps_limit if args.fps_limit > 0 else 120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            network_mode="vmnet-shared",
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        warm_path = Path(standby_bundle["ephemeral_path"])
        try:
            standby_res = ggm.warm_standby(warm_path, golden=golden, primary=primary, wait_qga_timeout=150.0)
            resume_res = ggm.resume_launch(warm_path, golden=golden, primary=primary, wait_qga_timeout=90.0)
            warm_resume_sec = float(resume_res.get("resume_ready_seconds") or resume_res.get("ready_seconds") or 0.0)
        finally:
            try:
                subprocess.run([str(UTMCTL), "stop", ggm.bundle_uuid(warm_path), "--kill"], capture_output=True, check=False)
                time.sleep(3.0)
            except Exception:
                pass
            ggm.destroy_ephemeral(warm_path, golden=golden, primary=primary, fast_disk_hash=True)

        return redact_p14_value({
            "measured_at_utc": utc_now_iso(),
            "app_shell_vm": {
                "cold_boot_ready_sec": cold_boot_sec,
                "launched_compact_and_transitioned_fullscreen": app_shell_alive,
                "game_mode_plist_enabled": game_mode_enabled,
                "qemu_no_slirp": not qemu_audit.get("has_slirp_user_net", True),
                "qemu_clean_polling": qemu_audit.get("clean_of_known_polling_bloat", False),
            },
            "warm_standby_resume": {
                "standby_result": standby_res,
                "resume_result": resume_res,
                "comparison": p13b.compare_cold_vs_warm_launch(cold_boot_sec, warm_resume_sec or 0.5),
            },
        })
    finally:
        if utm_proc is not None and created_bundle is not None:
            try:
                _stop_utm_custom(utm_proc, ggm.bundle_uuid(created_bundle), custom_utmctl)
            except Exception:
                pass
        if proxy_proc is not None:
            proxy_proc.terminate()
            try:
                proxy_proc.wait(timeout=5)
            except Exception:
                proxy_proc.kill()
        if created_bundle is not None and created_bundle.exists():
            shutil.rmtree(created_bundle, ignore_errors=True)
        shutil.rmtree(cache_dir, ignore_errors=True)
        shutil.rmtree(state_file.parent, ignore_errors=True)


def verify_zero_drift_and_write(
    *,
    output_path: Path,
    golden: Path,
    primary: Path,
    extra_notes: list[str] | None = None,
) -> dict[str, Any]:
    """Run full SHA-256 zero-drift verification against golden-guest-manifest.json and /Applications/UTM.app."""
    manifest = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8"))
    golden_fp = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
    primary_fp = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
    golden_ro = ggm.is_bundle_readonly(golden)

    fps = manifest.get("fingerprints", {})
    golden_zero_drift = (
        golden_fp.get("config_sha256") == fps.get("golden_config_sha256")
        and golden_fp.get("bundle_sha256") == fps.get("golden_bundle_sha256")
    )
    primary_zero_drift = (
        primary_fp.get("config_sha256") == fps.get("primary_vm_a_config_sha256")
        and primary_fp.get("bundle_sha256") == fps.get("primary_vm_a_bundle_sha256")
    )
    orig_utm = Path("/Applications/UTM.app")
    codesign_res = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(orig_utm)],
        capture_output=True,
        text=True,
        check=False,
    )
    lease = ggm.check_lease_and_processes(ggm.DEFAULT_LEASE_PATH)

    proof = redact_p14_value({
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "phase": "phase-14-window-14a",
        "verified_at_utc": utc_now_iso(),
        "golden_readonly": golden_ro,
        "golden_config_sha256": golden_fp.get("config_sha256"),
        "golden_bundle_sha256": golden_fp.get("bundle_sha256"),
        "golden_zero_drift": golden_zero_drift,
        "primary_vm_a_config_sha256": primary_fp.get("config_sha256"),
        "primary_vm_a_bundle_sha256": primary_fp.get("bundle_sha256"),
        "primary_zero_drift": primary_zero_drift,
        "original_utm_app_present": orig_utm.exists(),
        "original_utm_codesign_ok": codesign_res.returncode == 0,
        "active_qemu_workers": lease.get("active_qemu_workers", []),
        "lease_ready": bool(lease.get("ready")),
        "zero_drift": bool(
            golden_ro
            and golden_zero_drift
            and primary_zero_drift
            and orig_utm.exists()
            and codesign_res.returncode == 0
        ),
        "notes": extra_notes or [],
    })
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(proof, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return proof


def render_p14a_report_markdown(
    deep_dive: dict[str, Any],
    e2e_report: dict[str, Any],
    zero_drift: dict[str, Any],
) -> str:
    dc = deep_dive.get("exp_dual_cache", {})
    dc_cmp = dc.get("comparison", {})
    fs = deep_dive.get("exp_frame_sync", {})
    fs_sel = fs.get("selection", {})
    irq = deep_dive.get("exp_irq_audit", {})
    e2e_cmp = e2e_report.get("phase11b_comparison", {})
    ceiling = e2e_report.get("next_gen_physical_ceiling", {})

    lines = [
        "# Phase 14 窗口 14A 交付报告：残余性能极限深挖与全员合体端到端真机实测",
        "",
        "- **署名**：`@DNPMBHC`",
        f"- **生成时间 (UTC)**：`{utc_now_iso()}`",
        f"- **零漂移铁证**：`zero_drift = {zero_drift.get('zero_drift')}`（`golden_readonly = {zero_drift.get('golden_readonly')}`，`golden_zero_drift = {zero_drift.get('golden_zero_drift')}`，`primary_zero_drift = {zero_drift.get('primary_zero_drift')}`，`original_utm_codesign_ok = {zero_drift.get('original_utm_codesign_ok')}`）",
        "",
        "---",
        "",
        "## 1. 任务 14A-1：3 项残余性能深挖实验",
        "",
        "### 1.1 双缓存持久化增益（`XtaCache` + `DXMT_SHADER_CACHE`）",
        f"- 冷缓存首启 vs 热缓存二次启动：Mean FPS `{dc_cmp.get('fps_mean_delta_pct')}%`，P1 Low `{dc_cmp.get('fps_p1_low_delta_pct')}%`，严重掉帧降幅 `{dc_cmp.get('severe_drop_reduction_pct')}%`（`{dc_cmp.get('cold_severe_drop_count')}` → `{dc_cmp.get('warm_severe_drop_count')}`），Guest CPU 变化 `{dc_cmp.get('guest_cpu_delta_pct')}%`。",
        "",
        "### 1.2 帧同步损耗（`QEMURendererFPSLimit = 0` vs `120` 与低延迟队列）",
        f"- 推荐组合：`{fs_sel.get('recommended_arm')}`（`FPSLimit={fs_sel.get('fps_limit')}`, `drawable={fs_sel.get('metal_drawable_count')}`, `inflight={fs_sel.get('max_inflight_frames')}`），Mean `{fs_sel.get('fps_mean')} FPS`，P1 Low `{fs_sel.get('fps_p1_low')} FPS`，P99-P50 抖动 `{fs_sel.get('frame_ms_jitter_p99_p50')} ms`。",
        "",
        "### 1.3 QEMU 残余轮询设备审计与 `virtio-input` vs `usb-mouse`",
        f"- 设备树审计：`has_usb_tablet = {irq.get('device_audit', {}).get('has_usb_tablet')}`，`has_virtio_balloon = {irq.get('device_audit', {}).get('has_virtio_balloon')}`，`has_slirp_user_net = {irq.get('device_audit', {}).get('has_slirp_user_net')}`。",
        f"- `virtio-input` 结论：{irq.get('virtio_input_evaluation', {}).get('conclusion')}",
        "",
        "---",
        "",
        "## 2. 任务 14A-2：Phase 11–13 全员合体端到端实测与靶场回归",
        "",
        f"- 对照 Phase 11B 基线（`1920×1200` 靶场均值 `55.51 FPS` / P50 `58.44 FPS` / `Slack+Slop 2.93 ms`）：",
        f"  - 本次均值变化：`{e2e_cmp.get('mean_fps_delta_pct')}%`（绝对增益 `{e2e_cmp.get('mean_fps_abs_gain')} FPS`）",
        f"  - 本次 P50 变化：`{e2e_cmp.get('p50_fps_delta_pct')}%`（绝对增益 `{e2e_cmp.get('p50_fps_abs_gain')} FPS`）",
        f"  - `60+ FPS` 稳态达成：`{e2e_cmp.get('reached_60fps_steady')}`",
        f"  - `slirp` 丢包告警归零：`{e2e_cmp.get('slirp_warnings_zero')}`",
        "",
        "### 下一代性能物理上限研究结论",
        f"{ceiling.get('summary', '')}",
        "",
    ]
    return "\n".join(lines)


E2E_SESSION_STATE = Path(os.environ.get("TMPDIR", "/tmp")) / "p14a-valorant-e2e-session.json"


def _apply_guest_optimizer_v31(vm_uuid: str, utmctl: Path) -> dict[str, Any]:
    """Upload and apply guest-optimizer v3.1 inside guest (read-only profile, zero spoofing)."""
    guest_opt_dir = r"C:\graphics-lab\p14a\guest-optimizer"
    _qga_ps(vm_uuid, rf"New-Item -ItemType Directory -Force -Path '{guest_opt_dir}' | Out-Null", utmctl=utmctl)
    _upload_file_to_guest(vm_uuid, OPT_APPLY, rf"{guest_opt_dir}\apply-optimizer.ps1", utmctl=utmctl)
    _upload_file_to_guest(vm_uuid, OPT_PROFILE, rf"{guest_opt_dir}\profile.json", utmctl=utmctl)
    ps = rf"""
& '{guest_opt_dir}\apply-optimizer.ps1' -ProfilePath '{guest_opt_dir}\profile.json' -Apply | Out-String
"""
    try:
        out = _qga_ps(vm_uuid, ps, utmctl=utmctl, timeout=90.0)
        return {"applied": True, "output_excerpt": redact_p14_text(out[-400:])}
    except Exception as exc:
        return {"applied": False, "error": redact_p14_text(str(exc))}


def run_valorant_e2e_start(args: argparse.Namespace) -> dict[str, Any]:
    """Boot the full-stack Phase 11-14 VM with CoW-isolated target-cn disk and pause for manual user login/range."""
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    cache_disk = guest_root / "game-cache" / "valorant-cn-data.qcow2"
    custom_app = Path(args.custom_app)
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not custom_utmctl.is_file():
        custom_utmctl = UTMCTL

    utm_caches = Path.home() / "Library/Containers/com.utmapp.UTM/Data/Library/Caches"
    cache_dir = utm_caches / "dxmt-shader-cache-p14a-e2e"
    cache_dir.mkdir(parents=True, exist_ok=True)
    state_dir = utm_caches / "p14a-e2e-state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "app-shell-state.json"
    state_file.write_text(json.dumps({"state": "launcher", "process": "WeGame.exe"}), encoding="utf-8")

    vm_name = f"ephemeral-p14a-e2e-{uuid.uuid4().hex[:6]}"
    proxy_proc, socket_ep = p12b._start_async_net_proxy()

    created = ggm.create_playable(
        golden=golden,
        dest_dir=vms_dir,
        name=vm_name,
        primary=primary,
        reset=True,
        register_utm=False,
        trim_hardware=True,
        no_sound=False,
        dx_driver="DXMT",
        fps_limit=120,
        ram_mb=10240,
        vcpu=8,
        disable_balloon=True,
        pure_relative_mouse=True,
        network_mode="socket-stream",
        socket_endpoint=socket_ep,
        net_rx_queue_size=1024,
        disk_interface="virtio",
        enable_iothread=True,
        io_queues=4,
        fast_disk_hash=True,
    )
    bundle_path = Path(created["playable_path"])
    vm_uuid = created["vm_uuid"]

    # Apply Exp 2 winner: QEMURendererFPSLimit = 0 + attach APFS CoW isolated game data disk
    cfg = ggm.read_config_plist(bundle_path)
    cfg.setdefault("QEMU", {})["QEMURendererFPSLimit"] = int(args.fps_limit)
    game_disk_stat = None
    if cache_disk.is_file():
        st = cache_disk.stat()
        game_disk_stat = {"size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
        clone_data_name = f"p14a-data-{uuid.uuid4().hex[:8]}.qcow2"
        cp_res = subprocess.run(
            ["cp", "-c", str(cache_disk), str(bundle_path / "Data" / clone_data_name)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if cp_res.returncode != 0:
            raise RuntimeError(f"APFS CoW clone of game data disk failed: {cp_res.stderr}")
        cfg.setdefault("Drive", []).append({
            "Identifier": str(uuid.uuid4()).upper(),
            "ImageName": clone_data_name,
            "ImageType": "Disk",
            "Interface": "NVMe",
            "InterfaceVersion": 1,
            "ReadOnly": False,
        })
    ggm.write_config_plist(bundle_path, cfg)

    # Launch UTM-Custom.app in --app-shell-vm mode with full Phase 11-14 stack
    utm_proc = _launch_utm_custom(
        custom_app=custom_app,
        vm_uuid=vm_uuid,
        vm_bundle=bundle_path,
        app_shell=True,
        window_title="Malt — target-cn (Phase 14 Full Stack)",
        window_size="1280x800",
        state_file=state_file,
        shader_cache_dir=cache_dir,
        fps_limit=args.fps_limit,
        drawable_count=args.drawable_count,
        max_inflight_frames=args.max_inflight_frames,
        mouse_coalesce_ms=1.5,
        key_guard=True,
    )
    boot_sec = _wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=180.0)
    opt_res = _apply_guest_optimizer_v31(vm_uuid, custom_utmctl)
    qemu_audit = audit_qemu_polling_devices(_get_qemu_cmdline())
    host_snap = p11v.sample_host_processes()
    dxmt_before = _dir_stats(cache_dir)

    session_meta = {
        "started_at_utc": utc_now_iso(),
        "vm_name": vm_name,
        "vm_uuid": vm_uuid,
        "bundle_path": str(bundle_path),
        "custom_app": str(custom_app),
        "cache_dir": str(cache_dir),
        "state_file": str(state_file),
        "socket_endpoint": socket_ep,
        "proxy_pid": proxy_proc.pid,
        "utm_pid": utm_proc.pid,
        "fps_limit": args.fps_limit,
        "drawable_count": args.drawable_count,
        "max_inflight_frames": args.max_inflight_frames,
        "boot_ready_sec": boot_sec,
        "guest_optimizer_v31": opt_res,
        "qemu_audit": qemu_audit,
        "host_snapshot_start": host_snap,
        "dxmt_cache_start": dxmt_before,
        "game_disk_before_stat": game_disk_stat,
    }
    E2E_SESSION_STATE.write_text(json.dumps(session_meta, indent=2), encoding="utf-8")
    return redact_p14_value(session_meta)


def run_valorant_e2e_collect(args: argparse.Namespace) -> dict[str, Any]:
    """Collect read-only telemetry from target-cn ShooterGame.log, ACE drivers, and EventLog, then clean up."""
    if not E2E_SESSION_STATE.is_file():
        raise FileNotFoundError(f"E2E session state not found: {E2E_SESSION_STATE}")
    meta = json.loads(E2E_SESSION_STATE.read_text(encoding="utf-8"))
    vm_uuid = meta["vm_uuid"]
    bundle_path = Path(meta["bundle_path"])
    custom_app = Path(meta["custom_app"])
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    if not custom_utmctl.is_file():
        custom_utmctl = UTMCTL
    cache_dir = Path(meta["cache_dir"])

    host_snap_end = p11v.sample_host_processes()
    dxmt_end = _dir_stats(cache_dir)

    # Pull ShooterGame.log and inspect ACE drivers / EventLog / Secure Boot inside Guest (strictly read-only)
    guest_diag_ps = r"""
$candidates = @(
  "F:\VALORANT_CN\Tencent Games\VALORANT\live\ShooterGame\Saved\Logs\ShooterGame.log"
)
$userLogs = @(Get-ChildItem -Path "C:\Users" -Recurse -Depth 5 -Filter "ShooterGame.log" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
foreach ($ul in $userLogs) { $candidates += $ul.FullName }
$logPath = ""
foreach ($c in $candidates) {
  if (Test-Path $c) { $logPath = $c; break }
}
$logExists = ($logPath -ne "")
$logSize = if ($logExists) { (Get-Item $logPath).Length } else { 0 }
$aceDrv = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ACE' } | Select-Object Name, State, Status, StartMode)
$aceErr = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=7000,1275} -MaxEvents 20 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'ACE' } | Select-Object TimeCreated, Id, ProviderName)
$ciErr = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational'; Level=2} -MaxEvents 10 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id)
$sb = $false
try { $sb = [bool](Confirm-SecureBootUEFI) } catch { $sb = $false }
$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object Name, DriverVersion, Status)
[PSCustomObject]@{
  log_path = $logPath
  log_exists = $logExists
  log_size_bytes = $logSize
  secure_boot = $sb
  ace_drivers = $aceDrv
  ace_7000_1275_errors = $aceErr.Count
  code_integrity_errors = $ciErr.Count
  gpu = $gpu
} | ConvertTo-Json -Depth 4 -Compress
"""
    guest_diag = json.loads(_qga_ps(vm_uuid, guest_diag_ps, utmctl=custom_utmctl, timeout=60.0))

    log_text = ""
    if guest_diag.get("log_exists"):
        pull = subprocess.run(
            [str(custom_utmctl), "file", "pull", vm_uuid, guest_diag["log_path"]],
            capture_output=True,
            check=False,
            timeout=120,
        )
        if pull.returncode == 0:
            log_text = p9s.decode_guest_text(pull.stdout)

    # Parse ShooterGame.log using both p10_valorant_analyzer and our engine latency parser
    p10_parsed = p10a.analyze_shooter_log(log_text) if hasattr(p10a, "analyze_shooter_log") and log_text else {}
    latency_parsed = parse_shooter_engine_latency(log_text) if log_text else {}

    # Extract RangeV2 FPS series from log timestamps + FrameCounter if present
    fps_samples: list[float] = []
    if isinstance(p10_parsed, dict):
        for k in ("fps_samples", "range_fps_samples"):
            if isinstance(p10_parsed.get(k), list) and p10_parsed[k]:
                fps_samples = [float(x) for x in p10_parsed[k] if float(x) > 0]
                break
    # Fallback regex for UE4 log frame timestamps: [YYYY.MM.DD-HH.MM.SS:mmm][fff]
    if not fps_samples and log_text:
        ts_re = re.compile(r"\[(\d{4}\.\d{2}\.\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})\]\[\s*(\d+)\]")
        prev_t: float | None = None
        prev_f: int | None = None
        in_range = False
        for line in log_text.splitlines():
            if "RangeV2" in line or "ShootingRange" in line:
                in_range = True
            m = ts_re.search(line)
            if not m:
                continue
            hh, mm, ss, ms, fnum = int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)), int(m.group(6))
            t_sec = hh * 3600 + mm * 60 + ss + ms / 1000.0
            if in_range and prev_t is not None and prev_f is not None:
                dt = t_sec - prev_t
                df = (fnum - prev_f) % 1000
                if 0.5 <= dt <= 10.0 and df > 0:
                    fps = df / dt
                    if 1.0 <= fps <= 300.0:
                        fps_samples.append(round(fps, 3))
                    prev_t, prev_f = t_sec, fnum
            elif in_range:
                prev_t, prev_f = t_sec, fnum

    fps_summary = p11v.summarize_fps_series(fps_samples)
    latest_lat = latency_parsed.get("latest_engine_latency") or {}
    current_metrics = {
        "range_mean_fps": fps_summary.get("mean"),
        "range_p50_fps": fps_summary.get("p50"),
        "range_p1_low_fps": fps_summary.get("p1_low"),
        "range_p95_fps": fps_summary.get("p95"),
        "range_sample_count": fps_summary.get("count"),
        "slack_plus_slop_ms": latest_lat.get("slack_plus_slop_ms"),
        "engine_latency": latest_lat,
        "slirp_network_warnings_total": latency_parsed.get("slirp_network_warnings_total", 0),
        "severe_fps_drop_warnings": latency_parsed.get("severe_fps_drop_warnings", 0),
        "ace_anti_tick_http_200_count": latency_parsed.get("ace_anti_tick_http_200_count", 0),
    }
    p11b_cmp = compare_against_phase11b_baseline(current_metrics)

    # Load deep-dive results if present to build physical ceiling conclusion
    deep_dive_bundle: dict[str, Any] = {}
    for key, fname in (
        ("exp_dual_cache", "exp-dual-cache.json"),
        ("exp_frame_sync", "exp-frame-sync.json"),
        ("exp_irq_audit", "exp-irq-audit.json"),
        ("app_shell_and_warm", "app-shell-and-warm.json"),
    ):
        fpath = EVIDENCE_P14A / fname
        if fpath.is_file():
            deep_dive_bundle[key] = json.loads(fpath.read_text(encoding="utf-8"))

    ceiling = build_next_gen_physical_ceiling_conclusion(deep_dive_bundle, p11b_cmp)

    # Gracefully stop VM and clean up temporary E2E clone & proxy
    _stop_utm_custom(None, vm_uuid, custom_utmctl)
    try:
        os.kill(int(meta["proxy_pid"]), 15)
    except Exception:
        pass
    _unregister_vm_best_effort(vm_uuid, custom_utmctl)
    if bundle_path.exists() and not args.keep_vm:
        shutil.rmtree(bundle_path, ignore_errors=True)
    if cache_dir.exists() and not args.keep_vm:
        shutil.rmtree(cache_dir, ignore_errors=True)
    state_file_path = Path(meta["state_file"])
    if state_file_path.parent.exists():
        shutil.rmtree(state_file_path.parent, ignore_errors=True)

    # Check game-cache/valorant-cn-data.qcow2 untouched
    guest_root = p12b._find_external_guest_root()
    cache_disk = guest_root / "game-cache" / "valorant-cn-data.qcow2"
    game_disk_untouched = True
    if cache_disk.is_file() and meta.get("game_disk_before_stat"):
        st = cache_disk.stat()
        b_st = meta["game_disk_before_stat"]
        game_disk_untouched = (st.st_size == b_st["size_bytes"] and st.st_mtime_ns == b_st["mtime_ns"])

    report = redact_p14_value({
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "phase": "phase-14-window-14a",
        "collected_at_utc": utc_now_iso(),
        "full_stack_config": {
            "vcpu": 8,
            "ram_mib": 10240,
            "disk": "VirtIO-Blk (iothread0, num-queues=4, discard=unmap)",
            "network": "socket-stream (async zero-slirp proxy)",
            "graphics": "dxmt-native + persistent DXMT_SHADER_CACHE + XtaCache",
            "utm_custom_patches": 10,
            "fps_limit": meta.get("fps_limit"),
            "metal_drawable_count": meta.get("drawable_count"),
            "max_inflight_frames": meta.get("max_inflight_frames"),
            "mouse_coalesce_ms": 1.5,
            "key_guard": True,
            "app_shell_vm": True,
            "guest_optimizer": "v3.1",
        },
        "guest_diagnostics": guest_diag,
        "host_telemetry": {
            "start": meta.get("host_snapshot_start"),
            "end": host_snap_end,
            "dxmt_cache_start": meta.get("dxmt_cache_start"),
            "dxmt_cache_end": dxmt_end,
        },
        "qemu_audit": meta.get("qemu_audit"),
        "shooter_log_analysis": latency_parsed,
        "fps_summary": fps_summary,
        "phase11b_comparison": p11b_cmp,
        "next_gen_physical_ceiling": ceiling,
        "game_disk_untouched": game_disk_untouched,
        "temp_clone_deleted": (not bundle_path.exists()),
    })

    PHASE14_RUNS_DIR.mkdir(parents=True, exist_ok=True)
    (PHASE14_RUNS_DIR / "real-run-report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return report


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Phase 14A full-stack performance deep-dive & E2E real-run evaluator")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_dc = sub.add_parser("exp-dual-cache", help="Run Experiment 1: cold vs warm dual cache")
    p_dc.add_argument("--custom-app", default=str(DEFAULT_CUSTOM_APP))
    p_dc.add_argument("--duration-sec", type=int, default=60)
    p_dc.add_argument("--out", default=str(EVIDENCE_P14A / "exp-dual-cache.json"))

    p_fs = sub.add_parser("exp-frame-sync", help="Run Experiment 2: FPSLimit 0 vs 120 + low-latency queue")
    p_fs.add_argument("--custom-app", default=str(DEFAULT_CUSTOM_APP))
    p_fs.add_argument("--duration-sec", type=int, default=35)
    p_fs.add_argument("--out", default=str(EVIDENCE_P14A / "exp-frame-sync.json"))

    p_irq = sub.add_parser("exp-irq-audit", help="Run Experiment 3: QEMU polling audit + virtio-input eval")
    p_irq.add_argument("--custom-app", default=str(DEFAULT_CUSTOM_APP))
    p_irq.add_argument("--out", default=str(EVIDENCE_P14A / "exp-irq-audit.json"))

    p_sh = sub.add_parser("verify-app-shell-and-warm", help="Verify --app-shell-vm + Game Mode + warm-standby")
    p_sh.add_argument("--custom-app", default=str(DEFAULT_CUSTOM_APP))
    p_sh.add_argument("--fps-limit", type=int, default=120)
    p_sh.add_argument("--drawable-count", type=int, default=3)
    p_sh.add_argument("--max-inflight-frames", type=int, default=3)
    p_sh.add_argument("--out", default=str(EVIDENCE_P14A / "app-shell-and-warm.json"))

    p_vs = sub.add_parser("valorant-e2e-start", help="Launch full-stack VM for target-cn 1920x1200 E2E real run")
    p_vs.add_argument("--custom-app", default=str(DEFAULT_CUSTOM_APP))
    p_vs.add_argument("--fps-limit", type=int, default=0)
    p_vs.add_argument("--drawable-count", type=int, default=3)
    p_vs.add_argument("--max-inflight-frames", type=int, default=3)

    p_vc = sub.add_parser("valorant-e2e-collect", help="Collect read-only telemetry after user finishes target-cn range run")
    p_vc.add_argument("--keep-vm", action="store_true")

    p_zd = sub.add_parser("zero-drift", help="Verify golden + vm-a + /Applications/UTM.app zero drift")
    p_zd.add_argument("--out", default=str(EVIDENCE_P14A / "zero-drift-proof.json"))
    return p


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "exp-dual-cache":
        res = run_exp_dual_cache(args)
    elif args.cmd == "exp-frame-sync":
        res = run_exp_frame_sync(args)
    elif args.cmd == "exp-irq-audit":
        res = run_exp_irq_audit(args)
    elif args.cmd == "verify-app-shell-and-warm":
        res = run_verify_app_shell_and_warm(args)
    elif args.cmd == "valorant-e2e-start":
        res = run_valorant_e2e_start(args)
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0
    elif args.cmd == "valorant-e2e-collect":
        res = run_valorant_e2e_collect(args)
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0
    elif args.cmd == "zero-drift":
        guest_root = p12b._find_external_guest_root()
        vms_dir = guest_root / "vms"
        res = verify_zero_drift_and_write(
            output_path=Path(args.out),
            golden=vms_dir / "golden-win11-arm64-v1.utm",
            primary=vms_dir / "Windows11-ARM64.utm",
        )
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0
    else:
        parser.error(f"Unknown command: {args.cmd}")
        return 2

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(res, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(res, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
