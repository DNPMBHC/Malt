#!/usr/bin/env python3
"""Phase 8A offline telemetry analyzer, redactor, and 5-dimension report builder.

Owner: @DNPMBHC
Compliance: Strictly read-only diagnostic analysis without overclaiming or PII leakage.
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


def redact_p8_text(text: str) -> str:
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


def redact_p8_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p8_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p8_value(v) for v in value]
    if isinstance(value, str):
        return redact_p8_text(value)
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


def summarize_stability_series(
    host_samples: list[dict[str, Any]],
    guest_samples: list[dict[str, Any]],
) -> dict[str, Any]:
    """Summarize 3-5 minute continuous host/guest telemetry series."""
    render_cpus = [float(s["qemu_render_server_cpu"]) for s in host_samples if "qemu_render_server_cpu" in s]
    worker_cpus = [float(s["qemu_worker_cpu"]) for s in host_samples if "qemu_worker_cpu" in s]
    rss_mibs = [float(s["total_hypervisor_rss_mib"]) for s in host_samples if "total_hypervisor_rss_mib" in s]

    fps_vals = [float(s["estimated_fps"]) for s in guest_samples if s.get("estimated_fps") is not None]
    frame_ms_vals = [round(1000.0 / f, 3) for f in fps_vals if f > 0]
    alive_flags = [bool(s.get("shipping_alive")) for s in guest_samples]

    duration_sec = 0.0
    if len(host_samples) >= 2:
        t0 = host_samples[0].get("elapsed_seconds", 0.0)
        t1 = host_samples[-1].get("elapsed_seconds", 0.0)
        duration_sec = round(max(0.0, float(t1) - float(t0)), 2)

    freeze_detected = False
    if len(guest_samples) >= 3:
        last_frames = [s.get("last_frame_number") for s in guest_samples[-3:]]
        if last_frames[0] is not None and len(set(last_frames)) == 1 and all(alive_flags[-3:]):
            # Check if render server also dropped to near zero
            if render_cpus and statistics.mean(render_cpus[-5:]) < 1.0:
                freeze_detected = True

    return {
        "host_sample_count": len(host_samples),
        "guest_sample_count": len(guest_samples),
        "observed_duration_seconds": duration_sec,
        "shipping_alive_all_samples": all(alive_flags) if alive_flags else False,
        "freeze_detected": freeze_detected,
        "qemu_render_server_cpu": summarize_numeric(render_cpus),
        "qemu_worker_cpu": summarize_numeric(worker_cpus),
        "total_hypervisor_rss_mib": summarize_numeric(rss_mibs),
        "estimated_fps": summarize_numeric(fps_vals),
        "estimated_frame_ms": summarize_numeric(frame_ms_vals),
    }


def classify_ace_game_1275_impact(
    *,
    entered_lobby_or_range: bool,
    observed_duration_seconds: float,
    shipping_stayed_alive: bool,
    kicked_or_anticheat_popup: bool,
    main_exit_code: int | None,
    ace_game_1275_seen: bool,
) -> dict[str, Any]:
    if kicked_or_anticheat_popup:
        status = "kicked_or_anticheat_error_observed"
        summary = "An explicit kick or anti-cheat error popup occurred during live session."
    elif entered_lobby_or_range and shipping_stayed_alive and observed_duration_seconds >= 180.0:
        status = "stable_no_kick_observed_in_window"
        summary = (
            f"Client remained alive in lobby/range for {observed_duration_seconds:.1f}s "
            f"without kick or popup (ACE-GAME.sys 1275 seen={ace_game_1275_seen}); "
            "does not establish official vendor VM admission."
        )
    elif entered_lobby_or_range and main_exit_code is not None and main_exit_code != 0:
        status = "exited_nonzero_during_session"
        summary = f"Main game exited with code {main_exit_code} after entering lobby/range."
    elif not entered_lobby_or_range:
        status = "did_not_reach_lobby_or_range"
        summary = "Session did not reach lobby or training range; ACE-GAME.sys mid-session impact remains unproven."
    else:
        status = "short_or_incomplete_observation"
        summary = "Observation window was shorter than 180s or ended inconclusively."
    return {
        "status": status,
        "entered_lobby_or_range": entered_lobby_or_range,
        "observed_duration_seconds": round(observed_duration_seconds, 2),
        "shipping_stayed_alive": shipping_stayed_alive,
        "kicked_or_anticheat_popup": kicked_or_anticheat_popup,
        "main_exit_code": main_exit_code,
        "ace_game_1275_seen": ace_game_1275_seen,
        "summary": summary,
    }


def build_p8_real_run_report(
    *,
    golden_manifest_sha256: str,
    ephemeral_clone_name: str,
    display_and_pointer_config: dict[str, Any],
    stability_summary: dict[str, Any],
    ace_impact: dict[str, Any],
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
        "phase": "phase-8a",
        "owner": "@DNPMBHC",
        "target_alias": "target-cn",
        "golden_id": "golden-win11-arm64-v1",
        "golden_manifest_sha256": golden_manifest_sha256,
        "ephemeral_clone_alias": ephemeral_clone_name,
        "captured_at_utc": utc_now_iso(),
        "five_dimension_status": five_dimensions,
        "display_and_pointer_config": display_and_pointer_config,
        "stability_and_performance": stability_summary,
        "ace_game_1275_impact": ace_impact,
        "zero_drift_verification": drift_verification,
        "notes": notes or [],
        "compliance": {
            "modified_game_or_ace_binaries": False,
            "replaced_signed_system_dlls": False,
            "hidden_virtualization_or_spoofed_hardware": False,
            "automated_auth_or_captcha": False,
            "golden_zero_drift": bool(drift_verification.get("golden_zero_drift")),
            "primary_zero_drift": bool(drift_verification.get("primary_zero_drift")),
        },
    }
    return redact_p8_value(payload)
