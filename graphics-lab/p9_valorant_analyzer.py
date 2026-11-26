#!/usr/bin/env python3
"""Phase 9A offline analyzer for UTM DXMT vs D3DMetal probe, QEMURenderServer lsof/sample, and report.

Owner: @DNPMBHC
Compliance: Strictly read-only diagnostic analysis and privacy redaction.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
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


def redact_p9_text(text: str) -> str:
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


def redact_p9_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p9_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p9_value(v) for v in value]
    if isinstance(value, str):
        return redact_p9_text(value)
    return value


def parse_lsof_backend_frameworks(lsof_output: str) -> dict[str, Any]:
    """Identify whether QEMURenderServer mapped dxmt-native or d3dmetal-native."""
    dxmt_hits: list[str] = []
    d3dmetal_hits: list[str] = []
    virgl_hits: list[str] = []
    kosmic_hits: list[str] = []
    for line in lsof_output.splitlines():
        low = line.lower()
        if "dxmt-native" in low or "libdxmt-native" in low:
            dxmt_hits.append(redact_p9_text(line.strip()))
        if "d3dmetal-native" in low or "libd3dmetal-native" in low or "d3dmetal.framework" in low:
            d3dmetal_hits.append(redact_p9_text(line.strip()))
        if "virglrenderer" in low:
            virgl_hits.append(redact_p9_text(line.strip()))
        if "kosmickrisp" in low:
            kosmic_hits.append(redact_p9_text(line.strip()))

    if dxmt_hits and not d3dmetal_hits:
        active = "dxmt-native"
    elif d3dmetal_hits and not dxmt_hits:
        active = "d3dmetal-native"
    elif dxmt_hits and d3dmetal_hits:
        active = "both_mapped"
    else:
        active = "none_detected"

    return {
        "active_backend": active,
        "dxmt_native_loaded": bool(dxmt_hits),
        "d3dmetal_native_loaded": bool(d3dmetal_hits),
        "virglrenderer_loaded": bool(virgl_hits),
        "kosmickrisp_loaded": bool(kosmic_hits),
        "dxmt_evidence_count": len(dxmt_hits),
        "d3dmetal_evidence_count": len(d3dmetal_hits),
    }


def parse_sample_stack(sample_output: str, max_frames: int = 80) -> dict[str, Any]:
    """Extract redacted blocking/deadlock frames from macOS `sample <PID> 3` output."""
    lines = sample_output.splitlines()
    interesting_frames: list[str] = []
    thread_count = 0
    wait_symbols: set[str] = set()
    renderer_symbols: list[str] = []

    frame_re = re.compile(
        r"(?:dxmt|d3dmetal|neptune|virgl|npt_|vrend|MTL|Metal|semaphore_wait|__psynch_cvwait|"
        r"__psynch_mutexwait|kevent|poll|select|mach_msg|CommandBuffer|waitUntilCompleted|"
        r"Present|SwapChain|Flush|WaitForSingleObject)",
        re.IGNORECASE,
    )
    for ln in lines:
        if "Thread_" in ln and "DispatchQueue" in ln or re.match(r"^\s*\d+\s+Thread_", ln):
            thread_count += 1
        if frame_re.search(ln):
            cleaned = redact_p9_text(ln.strip())
            if len(interesting_frames) < max_frames:
                interesting_frames.append(cleaned)
            low = cleaned.lower()
            for sym in ("__psynch_cvwait", "__psynch_mutexwait", "semaphore_wait", "waituntilcompleted", "mach_msg", "kevent"):
                if sym in low:
                    wait_symbols.add(sym)
            if any(k in low for k in ("dxmt", "d3dmetal", "neptune", "npt_", "virgl")):
                if len(renderer_symbols) < 40 and cleaned not in renderer_symbols:
                    renderer_symbols.append(cleaned)

    return {
        "total_lines": len(lines),
        "thread_count_detected": thread_count,
        "wait_primitives_observed": sorted(wait_symbols),
        "renderer_stack_frames": renderer_symbols,
        "interesting_frames_sample": interesting_frames,
    }


def compare_probe_backends(d3dmetal_probe: dict[str, Any], dxmt_probe: dict[str, Any]) -> dict[str, Any]:
    """Compare D3DMetal vs DXMT host Neptune backends on d3d11_probe.exe."""
    d3d_fps = d3dmetal_probe.get("fps")
    dxmt_fps = dxmt_probe.get("fps")
    ratio = round(dxmt_fps / d3d_fps, 3) if (d3d_fps and dxmt_fps and d3d_fps > 0) else None
    d3d_gpu_ms = d3dmetal_probe.get("gpu_ms_mean")
    dxmt_gpu_ms = dxmt_probe.get("gpu_ms_mean")
    return {
        "d3dmetal_fps": d3d_fps,
        "dxmt_fps": dxmt_fps,
        "dxmt_vs_d3dmetal_fps_ratio": ratio,
        "d3dmetal_gpu_ms_mean": d3d_gpu_ms,
        "dxmt_gpu_ms_mean": dxmt_gpu_ms,
        "timestamp_query_recovered_in_dxmt": bool(dxmt_gpu_ms is not None and dxmt_gpu_ms > 0.0),
        "d3dmetal_max_lsb": d3dmetal_probe.get("pixel_compare", {}).get("max_channel_error_lsb"),
        "dxmt_max_lsb": dxmt_probe.get("pixel_compare", {}).get("max_channel_error_lsb"),
        "both_zero_lsb": (
            d3dmetal_probe.get("pixel_compare", {}).get("max_channel_error_lsb") == 0
            and dxmt_probe.get("pixel_compare", {}).get("max_channel_error_lsb") == 0
        ),
    }


def build_p9_real_run_report(
    *,
    golden_manifest_sha256: str,
    utm_backend_config: dict[str, Any],
    probe_comparison: dict[str, Any],
    valorant_dxmt_run: dict[str, Any],
    host_stack_capture: dict[str, Any] | None,
    drift_verification: dict[str, Any],
    five_dimensions: dict[str, str],
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
        "phase": "phase-9a",
        "owner": "@DNPMBHC",
        "target_alias": "target-cn",
        "golden_id": "golden-win11-arm64-v1",
        "golden_manifest_sha256": golden_manifest_sha256,
        "captured_at_utc": utc_now_iso(),
        "five_dimension_status": five_dimensions,
        "utm_native_backend_config": utm_backend_config,
        "d3d11_probe_comparison": probe_comparison,
        "valorant_dxmt_run": valorant_dxmt_run,
        "host_render_server_stack_capture": host_stack_capture,
        "zero_drift_verification": drift_verification,
        "compliance": {
            "modified_game_or_ace_binaries": False,
            "replaced_signed_system_dlls": False,
            "hidden_virtualization_or_spoofed_hardware": False,
            "automated_auth_or_captcha": False,
            "utm_defaults_restored": bool(utm_backend_config.get("defaults_restored")),
            "golden_zero_drift": bool(drift_verification.get("golden_zero_drift")),
            "primary_zero_drift": bool(drift_verification.get("primary_zero_drift")),
        },
    }
    return redact_p9_value(payload)
