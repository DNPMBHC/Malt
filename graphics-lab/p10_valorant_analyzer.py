#!/usr/bin/env python3
"""Phase 10A offline analyzer for cursor trials, training-range 3-5m benchmark, and ACE verdict.

Owner: @DNPMBHC
Compliance: Strictly read-only diagnostic analysis, 5-dimension honesty, and full redaction.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import statistics
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent

SENSITIVE_LINE_RE = re.compile(
    r"(?:password|passwd|token|cookie|openid|access_?key|secret|phone|mobile|email|"
    r"username|user_?id|login|ticket|authorization|credential|session_?id|"
    r"\baccount\b|\buin\b|\buid\b|\bqq\b|实名|身份证|验证码|captcha)",
    re.IGNORECASE,
)
UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact_p10_text(text: str) -> str:
    if not text:
        return ""
    user_name = os.environ.get("USER") or Path.home().name
    lines_out: list[str] = []
    for raw_line in str(text).splitlines():
        if SENSITIVE_LINE_RE.search(raw_line):
            lines_out.append("<redacted-sensitive-line>")
            continue
        line = raw_line
        line = line.replace(str(WORKSPACE_ROOT), "<workspace>")
        line = line.replace(str(WORKSPACE_ROOT).replace("/", "\\"), "<workspace>")
        line = line.replace(str(Path.home()), "<home>")
        if WORKSPACE_ROOT.name:
            line = line.replace(WORKSPACE_ROOT.name, "my-project")
        line = re.sub(r"/Volumes/[^/\s\"'<>`]+", "/Volumes/<EXTERNAL_VOLUME>", line)
        line = re.sub(r"(?:[A-Z]:)?[/\\]Users[/\\][^/\\\s\"'<>]+", "<local-user-dir>", line, flags=re.IGNORECASE)
        line = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<email>", line)
        line = UUID_RE.sub("<uuid>", line)
        if user_name:
            line = re.sub(
                r"(?<![\w@])" + re.escape(user_name) + r"(?!\w)",
                "user-x",
                line,
                flags=re.IGNORECASE,
            )
        lines_out.append(line)
    return "\n".join(lines_out)


def redact_p10_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p10_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p10_value(v) for v in value]
    if isinstance(value, str):
        return redact_p10_text(value)
    return value


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    if pct <= 0:
        return round(min(values), 3)
    if pct >= 100:
        return round(max(values), 3)
    ordered = sorted(values)
    idx = (len(ordered) - 1) * (pct / 100.0)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return round(ordered[lo], 3)
    frac = idx - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def summarize_numeric(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"mean": None, "p50": None, "p95": None, "p99": None, "min": None, "max": None}
    return {
        "mean": round(statistics.mean(values), 3),
        "p50": percentile(values, 50.0),
        "p95": percentile(values, 95.0),
        "p99": percentile(values, 99.0),
        "min": round(min(values), 3),
        "max": round(max(values), 3),
    }


def parse_qemu_input_devices(qemu_cmdline: str) -> dict[str, Any]:
    """Extract QEMU virtual input device flags from host command line."""
    devices = re.findall(r"-device\s+([^\s]+)", qemu_cmdline)
    input_devs = [
        d for d in devices
        if any(tok in d.lower() for tok in ("tablet", "mouse", "kbd", "keyboard", "hid", "spice", "vdagent"))
    ]
    has_usb_tablet = any("usb-tablet" in d.lower() or "virtio-tablet" in d.lower() for d in input_devs)
    has_usb_mouse = any("usb-mouse" in d.lower() or "virtio-mouse" in d.lower() for d in input_devs)
    has_ps2 = any("ps2" in d.lower() for d in input_devs)
    return {
        "input_devices": input_devs,
        "has_usb_tablet": has_usb_tablet,
        "has_usb_mouse": has_usb_mouse,
        "has_ps2": has_ps2,
        "pure_relative_mouse_only": (has_usb_mouse and not has_usb_tablet),
    }


def summarize_cursor_trials(trials: list[dict[str, Any]]) -> dict[str, Any]:
    """Summarize ordered cursor visibility trials for cursor-diagnosis-for-10b.md."""
    resolved_by = [t["trial_id"] for t in trials if t.get("in_game_cursor_visible") is True]
    relative_ok = [t["trial_id"] for t in trials if t.get("relative_aim_working") is True]
    return {
        "trial_count": len(trials),
        "in_game_cursor_resolved": bool(resolved_by),
        "resolved_by_trials": resolved_by,
        "relative_aim_working_trials": relative_ok,
        "requires_cocoaspice_host_patch": not bool(resolved_by),
        "trials": redact_p10_value(trials),
    }


def summarize_range_benchmark(
    host_samples: list[dict[str, Any]],
    guest_samples: list[dict[str, Any]],
    in_game_fps_readings: list[float] | None = None,
) -> dict[str, Any]:
    render_cpus = [float(s["qemu_render_server_cpu"]) for s in host_samples if "qemu_render_server_cpu" in s]
    worker_cpus = [float(s["qemu_worker_cpu"]) for s in host_samples if "qemu_worker_cpu" in s]
    rss_mibs = [float(s["total_hypervisor_rss_mib"]) for s in host_samples if "total_hypervisor_rss_mib" in s]

    log_fps = [float(s["estimated_fps"]) for s in guest_samples if s.get("estimated_fps") is not None and float(s["estimated_fps"]) > 0]
    fps_source = in_game_fps_readings if in_game_fps_readings else log_fps
    frame_ms = [round(1000.0 / f, 3) for f in fps_source if f > 0]

    duration_s = 0.0
    if len(host_samples) >= 2:
        duration_s = round(
            max(0.0, float(host_samples[-1].get("elapsed_seconds", 0.0)) - float(host_samples[0].get("elapsed_seconds", 0.0))),
            2,
        )
    alive_flags = [bool(s.get("shipping_alive")) for s in guest_samples]

    return {
        "observed_duration_seconds": duration_s,
        "host_sample_count": len(host_samples),
        "guest_sample_count": len(guest_samples),
        "shipping_alive_all_samples": all(alive_flags) if alive_flags else False,
        "fps_source": "in_game_hud" if in_game_fps_readings else "ue4_log_frame_delta",
        "fps": summarize_numeric(fps_source),
        "frame_time_ms": summarize_numeric(frame_ms),
        "qemu_render_server_cpu": summarize_numeric(render_cpus),
        "qemu_worker_cpu": summarize_numeric(worker_cpus),
        "total_hypervisor_rss_mib": summarize_numeric(rss_mibs),
    }


def classify_final_ace_verdict(
    *,
    entered_lobby: bool,
    entered_training_range: bool,
    observed_duration_seconds: float,
    kicked_or_error_popup: bool,
    queue_precheck_attempted: bool,
    queue_precheck_rejected: bool,
    ace_game_1275_present: bool,
    main_exit_code: int | None,
) -> dict[str, Any]:
    if kicked_or_error_popup or queue_precheck_rejected:
        status = "ace_kick_or_restriction_observed"
        summary = "Explicit anti-cheat kick, error popup, or queue restriction observed during live session."
    elif entered_training_range and observed_duration_seconds >= 180.0 and main_exit_code is None:
        status = "training_range_stable_no_kick_in_window"
        summary = (
            f"Training range remained alive for {observed_duration_seconds:.1f}s without kick "
            f"(ACE-GAME.sys 1275 present={ace_game_1275_present}); does not guarantee ranked/official VM admission."
        )
    elif entered_lobby and not entered_training_range:
        status = "lobby_reached_range_unverified"
        summary = "Reached main lobby without kick, but training range 3-5m run was not completed."
    else:
        status = "lobby_and_range_not_reached"
        summary = "Session did not reach lobby/training range; ACE-GAME.sys mid-game impact remains unverified."

    return {
        "status": status,
        "entered_lobby": entered_lobby,
        "entered_training_range": entered_training_range,
        "observed_duration_seconds": round(observed_duration_seconds, 2),
        "kicked_or_error_popup": kicked_or_error_popup,
        "queue_precheck_attempted": queue_precheck_attempted,
        "queue_precheck_rejected": queue_precheck_rejected,
        "ace_game_1275_present": ace_game_1275_present,
        "main_exit_code": main_exit_code,
        "summary": summary,
    }


def build_p10_real_run_report(
    *,
    golden_manifest_sha256: str,
    ephemeral_clone_name: str,
    cursor_trials_summary: dict[str, Any],
    range_benchmark: dict[str, Any],
    ace_verdict: dict[str, Any],
    drift_verification: dict[str, Any],
    five_dimensions: dict[str, str],
    notes: list[str] | None = None,
) -> dict[str, Any]:
    required_dims = (
        "implementation",
        "local_gates",
        "real_guest_run",
        "vendor_vm_support",
        "protected_lobby_and_match",
    )
    for key in required_dims:
        if key not in five_dimensions:
            raise ValueError(f"Missing required 5-dimension key: {key}")

    payload = {
        "schema_version": 1,
        "phase": "phase-10a",
        "owner": "@DNPMBHC",
        "target_alias": "target-cn",
        "golden_id": "golden-win11-arm64-v1",
        "golden_manifest_sha256": golden_manifest_sha256,
        "ephemeral_clone_alias": ephemeral_clone_name,
        "captured_at_utc": utc_now_iso(),
        "five_dimension_status": five_dimensions,
        "cursor_trials_summary": cursor_trials_summary,
        "training_range_benchmark": range_benchmark,
        "ace_final_verdict": ace_verdict,
        "zero_drift_verification": drift_verification,
        "notes": notes or [],
        "compliance": {
            "modified_game_or_ace_binaries": False,
            "replaced_signed_system_dlls": False,
            "hidden_virtualization_or_spoofed_hardware": False,
            "automated_auth_or_captcha": False,
            "utm_defaults_restored": bool(drift_verification.get("utm_defaults_restored")),
            "golden_zero_drift": bool(drift_verification.get("golden_zero_drift")),
            "primary_zero_drift": bool(drift_verification.get("primary_zero_drift")),
        },
    }
    return redact_p10_value(payload)
