#!/usr/bin/env python3
"""Offline log analyzer, privacy redactor, and 5-dimension report builder for Phase 7A.

Owner: @DNPMBHC
Compliance: Strictly read-only diagnostic analysis. Never fabricates outcomes or leaks PII.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
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

UE4_INTERESTING_RE = re.compile(
    r"(?:LogD3D11RHI|LogD3D12RHI|LogVulkanRHI|LogRHI|LogWindows|LogShader|"
    r"LogInit|SwapChain|Present|Adapter|DedicatedVideoMemory|DeviceRemoved|"
    r"DXGI_ERROR|HRESULT|neptune|virtio|vulkan|dxvk|Fatal|Error:|Warning:|"
    r"ACE|AntiCheat|Vanguard|Timeout|Hung|Crash|Exit)",
    re.IGNORECASE,
)

VRAM_DEDICATED_RE = re.compile(
    r"Dedicated\s*Video\s*Memory\s*[:=]\s*(\d+)\s*(MB|MiB|bytes|B)?",
    re.IGNORECASE,
)
ADAPTER_NAME_RE = re.compile(
    r"(?:Adapter\s*Name|Found\s*D3D11\s*adapter\s*\d+|Using\s*Adapter)\s*[:=]\s*([^\r\n]+)",
    re.IGNORECASE,
)
FEATURE_LEVEL_RE = re.compile(r"(?:Feature\s*Level|FL)\s*[:=]?\s*(1[012]_[01]|SM[456])", re.IGNORECASE)
HRESULT_RE = re.compile(r"0x[0-9a-fA-F]{8}")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()


def redact_p7_text(text: str) -> str:
    """Redact workspace, home, usernames, external volume names, emails, and auth lines."""
    if not text:
        return ""
    lines_out: list[str] = []
    user_name = os.environ.get("USER") or Path.home().name
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
        if user_name:
            line = re.sub(
                r"(?<![\w@])" + re.escape(user_name) + r"(?!\w)",
                "user-x",
                line,
                flags=re.IGNORECASE,
            )
        lines_out.append(line)
    return "\n".join(lines_out)


def redact_p7_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p7_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p7_value(v) for v in value]
    if isinstance(value, str):
        return redact_p7_text(value)
    return value


def parse_ue4_log(raw_text: str, max_highlights: int = 120) -> dict[str, Any]:
    """Parse UE4 ShooterGame / RHI log text into structured blackscreen diagnostic signals."""
    lines = raw_text.splitlines()
    adapters: list[str] = []
    dedicated_vram_mb: int | None = None
    feature_levels: list[str] = []
    hresults: list[str] = []
    highlights: list[str] = []
    shader_lines = 0
    error_lines = 0
    fatal_lines = 0
    indicators: set[str] = set()

    for line in lines:
        m_adapter = ADAPTER_NAME_RE.search(line)
        if m_adapter:
            name = redact_p7_text(m_adapter.group(1).strip())
            if name and name not in adapters:
                adapters.append(name)

        m_vram = VRAM_DEDICATED_RE.search(line)
        if m_vram:
            val = int(m_vram.group(1))
            unit = (m_vram.group(2) or "MB").lower()
            if unit in ("b", "bytes"):
                val = val // (1024 * 1024)
            dedicated_vram_mb = val
            if val == 0:
                indicators.add("zero_dedicated_vram")

        m_fl = FEATURE_LEVEL_RE.search(line)
        if m_fl:
            fl = m_fl.group(1).upper()
            if fl not in feature_levels:
                feature_levels.append(fl)

        low = line.lower()
        if "shader" in low and ("compile" in low or "failed" in low or "error" in low):
            shader_lines += 1
            if "failed" in low or "error" in low:
                indicators.add("shader_compile_failure")

        if "dxgi_error_device_removed" in low or "dxgi_error_device_hung" in low or "device lost" in low:
            indicators.add("device_removed_or_hung")
        if ("swapchain" in low or "present" in low) and ("fail" in low or "error" in low or "0x887a" in low):
            indicators.add("swapchain_or_present_error")
        if "neptune" in low and ("fail" in low or "error" in low or "0xc000" in low):
            indicators.add("neptune_error")
        if "vulkan" in low and ("fail" in low or "error" in low or "not found" in low):
            indicators.add("vulkan_init_error")
        if "fatal" in low or "assertion failed" in low or "unhandled exception" in low:
            fatal_lines += 1
            indicators.add("fatal_crash")
        if "error:" in low or "err:" in low:
            error_lines += 1
        if ("ace" in low or "anticheat" in low) and ("block" in low or "deny" in low or "reject" in low or "error" in low or "fail" in low):
            indicators.add("ace_or_anticheat_notice")

        for hr in HRESULT_RE.findall(line):
            hr_low = hr.lower()
            if hr_low.startswith(("0x887a", "0x8007", "0x8000", "0xc000")) and hr_low not in hresults:
                hresults.append(hr_low)

        if UE4_INTERESTING_RE.search(line) and len(highlights) < max_highlights:
            highlights.append(redact_p7_text(line))

    return {
        "total_lines": len(lines),
        "raw_sha256": sha256_text(raw_text),
        "adapters": adapters,
        "dedicated_vram_mb": dedicated_vram_mb,
        "feature_levels": feature_levels,
        "hresults": hresults[:32],
        "shader_event_count": shader_lines,
        "error_line_count": error_lines,
        "fatal_line_count": fatal_lines,
        "blackscreen_indicators": sorted(indicators),
        "highlights": highlights,
    }


def parse_dxgi_and_vulkan_probe(probe_data: dict[str, Any]) -> dict[str, Any]:
    """Summarize DXGI adapter memory reporting and Vulkan Venus ICD availability."""
    adapters = probe_data.get("dxgi_adapters", [])
    primary_adapter = adapters[0] if adapters else {}
    dedicated_bytes = primary_adapter.get("dedicated_video_memory_bytes")
    shared_bytes = primary_adapter.get("shared_system_memory_bytes")
    wmi_ram = probe_data.get("wmi_adapter_ram_bytes")

    vulkan_devices = probe_data.get("vulkan_devices", [])
    venus_found = any(
        "virtio" in str(d.get("device_name", "")).lower()
        or "venus" in str(d.get("device_name", "")).lower()
        or "kosmickrisp" in str(d.get("device_name", "")).lower()
        or "apple" in str(d.get("device_name", "")).lower()
        for d in vulkan_devices
    )

    return {
        "dxgi_adapter_count": len(adapters),
        "primary_adapter_description": redact_p7_text(str(primary_adapter.get("description", ""))),
        "dxgi_dedicated_video_memory_bytes": dedicated_bytes,
        "dxgi_shared_system_memory_bytes": shared_bytes,
        "wmi_adapter_ram_bytes": wmi_ram,
        "dedicated_vram_is_zero": (dedicated_bytes == 0) if dedicated_bytes is not None else None,
        "wmi_adapter_ram_is_zero": (wmi_ram == 0) if wmi_ram is not None else None,
        "vulkan_icd_files": redact_p7_value(probe_data.get("vulkan_icd_files", [])),
        "vulkan_device_count": len(vulkan_devices),
        "vulkan_devices": redact_p7_value(vulkan_devices),
        "venus_vulkan_ready": venus_found,
    }


def classify_ace_dxvk_reaction(
    *,
    dxvk_tested: bool,
    dxvk_dlls_loaded: bool,
    ace_drivers_running: bool,
    game_visual_lit: bool,
    explicit_anticheat_rejection: bool,
    main_exit_code: int | None,
) -> dict[str, Any]:
    """Conservatively classify ACE reaction to user-mode DXVK without overclaiming."""
    if not dxvk_tested:
        status = "not_tested"
        summary = "DXVK user-mode path was not executed in this run."
    elif explicit_anticheat_rejection:
        status = "rejected_by_anticheat"
        summary = "Explicit anti-cheat rejection/error observed when DXVK user-mode DLLs were present."
    elif game_visual_lit and dxvk_dlls_loaded and ace_drivers_running:
        status = "allowed_and_rendered"
        summary = "Native ARM64 ACE remained running while user-mode DXVK loaded and rendered visible frames."
    elif dxvk_dlls_loaded and ace_drivers_running and main_exit_code is None:
        status = "loaded_no_explicit_rejection_still_unlit"
        summary = "DXVK loaded alongside running ACE without an explicit rejection popup, but visuals remained unlit."
    elif main_exit_code is not None and main_exit_code != 0:
        status = "exited_nonzero_unattributed"
        summary = f"Process exited with code {main_exit_code}; root cause must be read from logs/EventLog without guessing ACE policy."
    else:
        status = "unknown"
        summary = "Insufficient direct evidence to establish ACE policy toward user-mode DXVK."
    return {
        "status": status,
        "dxvk_tested": dxvk_tested,
        "dxvk_dlls_loaded": dxvk_dlls_loaded,
        "ace_drivers_running": ace_drivers_running,
        "game_visual_lit": game_visual_lit,
        "explicit_anticheat_rejection": explicit_anticheat_rejection,
        "main_exit_code": main_exit_code,
        "summary": summary,
    }


def build_real_run_report(
    *,
    golden_manifest_sha256: str,
    ephemeral_clone_name: str,
    dxgi_vulkan_summary: dict[str, Any],
    neptune_run: dict[str, Any],
    venus_dxvk_run: dict[str, Any],
    drift_verification: dict[str, Any],
    five_dimensions: dict[str, str],
) -> dict[str, Any]:
    """Assemble strictly redacted, 5-dimension-separated real-run-report.json."""
    required_dims = (
        "implementation",
        "local_gates",
        "real_guest_run",
        "vendor_vm_support",
        "protected_lobby_and_match",
    )
    for key in required_dims:
        if key not in five_dimensions:
            raise ValueError(f"Missing required 5-dimension status key: {key}")

    payload = {
        "schema_version": 1,
        "phase": "phase-7a",
        "owner": "@DNPMBHC",
        "target_alias": "target-cn",
        "golden_id": "golden-win11-arm64-v1",
        "golden_manifest_sha256": golden_manifest_sha256,
        "ephemeral_clone_alias": ephemeral_clone_name,
        "captured_at_utc": utc_now_iso(),
        "five_dimension_status": five_dimensions,
        "dxgi_and_vulkan_preflight": dxgi_vulkan_summary,
        "neptune_baseline_run": neptune_run,
        "venus_dxvk_run": venus_dxvk_run,
        "zero_drift_verification": drift_verification,
        "compliance": {
            "modified_game_or_ace_binaries": False,
            "hidden_virtualization_or_spoofed_hardware": False,
            "automated_auth_or_captcha": False,
            "primary_vm_a_untouched": bool(drift_verification.get("primary_zero_drift")),
            "golden_image_untouched": bool(drift_verification.get("golden_zero_drift")),
        },
    }
    return redact_p7_value(payload)
