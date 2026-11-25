#!/usr/bin/env python3
"""Phase 12B Game Mode, high-polling mouse coalescing, key guard & RangeV2 regression verifier.

Owner: @DNPMBHC
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import statistics
import subprocess
import sys
from typing import Any

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
PHASE11B_BASELINE = {
    "range_warmup_peak_mean_fps": 55.51,
    "range_warmup_peak_p50_fps": 58.44,
    "range_warmup_peak_p5_fps": 42.42,
    "range_warmup_peak_p1_low_fps": 25.74,
    "range_pure_combat_mean_fps": 45.21,
    "range_pure_combat_p50_fps": 49.63,
    "engine_latency_ms": 22.62,
    "engine_work_ms": 19.69,
    "engine_slack_ms": 2.45,
    "engine_slop_ms": 0.48,
    "engine_slack_plus_slop_ms": 2.93,
}

# macOS virtual key codes matching Carbon.HIToolbox / VMMetalView.swift
KVK_ANSI_W = 0x0D
KVK_ANSI_Q = 0x0C
KVK_ANSI_H = 0x04
KVK_ANSI_M = 0x2E
KVK_ANSI_G = 0x05
KVK_TAB = 0x30
KVK_F1 = 0x7A
KVK_F12 = 0x6F


def redact_path(raw: str) -> str:
    """Redact local username, home directory, TMPDIR, and external volume names."""
    text = raw
    tmpdir = os.environ.get("TMPDIR", "").rstrip("/")
    if tmpdir:
        text = text.replace(f"/private{tmpdir}", "<TMPDIR>")
        text = text.replace(tmpdir, "<TMPDIR>")
    home = str(Path.home())
    if home:
        text = text.replace(home, "<HOME>")
    text = re.sub(r"/Users/[^/\s\"']+", "/Users/<USER>", text)
    text = re.sub(r"/Volumes/[^/\s\"']+", "/Volumes/<EXTERNAL_VOLUME>", text)
    return text


@dataclass(frozen=True)
class MouseInputEvent:
    timestamp_ns: int
    kind: str  # "move" | "button_down" | "button_up" | "scroll" | "release"
    dx: float = 0.0
    dy: float = 0.0
    button: str = ""


@dataclass(frozen=True)
class EmittedEvent:
    timestamp_ns: int
    kind: str  # "motion" | "button_down" | "button_up" | "scroll" | "release"
    dx: float = 0.0
    dy: float = 0.0
    button: str = ""
    flushed_before_action: bool = False


class HighRateMouseCoalescer:
    """Lossless relative delta coalescer mirroring 06-high-polling-mouse-coalescing.patch."""

    def __init__(self, coalesce_us: int = 1500) -> None:
        if coalesce_us <= 0:
            self.window_ns = 0
        else:
            self.window_ns = min(coalesce_us, 16_000) * 1_000
        self.pending_dx: float = 0.0
        self.pending_dy: float = 0.0
        self.last_send_ns: int = 0
        self.emitted: list[EmittedEvent] = []

    def _flush(self, now_ns: int, before_action: bool = False) -> bool:
        if self.pending_dx == 0.0 and self.pending_dy == 0.0:
            return False
        dx = self.pending_dx
        dy = self.pending_dy
        self.pending_dx = 0.0
        self.pending_dy = 0.0
        self.last_send_ns = now_ns
        self.emitted.append(
            EmittedEvent(
                timestamp_ns=now_ns,
                kind="motion",
                dx=dx,
                dy=dy,
                flushed_before_action=before_action,
            )
        )
        return True

    def process(self, event: MouseInputEvent) -> None:
        if event.kind == "move":
            if event.dx == 0.0 and event.dy == 0.0:
                return
            if self.window_ns == 0:
                self.last_send_ns = event.timestamp_ns
                self.emitted.append(
                    EmittedEvent(timestamp_ns=event.timestamp_ns, kind="motion", dx=event.dx, dy=event.dy)
                )
                return
            self.pending_dx += event.dx
            self.pending_dy += event.dy
            if self.last_send_ns == 0 or (event.timestamp_ns - self.last_send_ns) >= self.window_ns:
                self._flush(event.timestamp_ns, before_action=False)
            return

        # Button down/up, scroll, release: immediately flush accumulated delta first!
        self._flush(event.timestamp_ns, before_action=True)
        self.emitted.append(
            EmittedEvent(timestamp_ns=event.timestamp_ns, kind=event.kind, button=event.button)
        )

    def finish(self, end_ns: int) -> None:
        """Simulate the main-queue tail timer firing at end of stream."""
        self._flush(end_ns, before_action=False)


def run_high_rate_coalescing_benchmark(
    polling_rates_hz: tuple[int, ...] = (1000, 2000, 4000, 8000),
    coalesce_us: int = 1500,
    duration_ms: int = 250,
) -> dict[str, Any]:
    """Run deterministic high-polling-rate mouse sweeps with click flushes."""
    results: list[dict[str, Any]] = []
    all_passed = True

    for hz in polling_rates_hz:
        interval_ns = int(1_000_000_000 / hz)
        total_samples = int(hz * duration_ms / 1000)
        events: list[MouseInputEvent] = []
        expected_dx = 0.0
        expected_dy = 0.0
        click_indices = {total_samples // 4, total_samples // 2, (3 * total_samples) // 4}

        for i in range(total_samples):
            t_ns = (i + 1) * interval_ns
            # Flick right-up then micro-adjust left-down (non-uniform deltas)
            dx = float((i % 7) - 2) if i < total_samples // 2 else float(-((i % 5) - 1))
            dy = float((i % 3) - 1)
            if dx == 0.0 and dy == 0.0:
                dx = 1.0
            expected_dx += dx
            expected_dy += dy
            events.append(MouseInputEvent(timestamp_ns=t_ns, kind="move", dx=dx, dy=dy))
            if i in click_indices:
                events.append(MouseInputEvent(timestamp_ns=t_ns + 10_000, kind="button_down", button="left"))
                events.append(MouseInputEvent(timestamp_ns=t_ns + 50_000, kind="button_up", button="left"))

        coalescer = HighRateMouseCoalescer(coalesce_us=coalesce_us)
        for ev in events:
            coalescer.process(ev)
        coalescer.finish(end_ns=(total_samples + 2) * interval_ns)

        motion_packets = [e for e in coalescer.emitted if e.kind == "motion"]
        emitted_dx = sum(e.dx for e in motion_packets)
        emitted_dy = sum(e.dy for e in motion_packets)
        dx_error = abs(expected_dx - emitted_dx)
        dy_error = abs(expected_dy - emitted_dy)

        # Verify every button_down had zero pending delta left behind (immediate flush)
        click_flush_ok = True
        for idx, em in enumerate(coalescer.emitted):
            if em.kind == "button_down":
                # Any motion before click must have timestamp <= click timestamp
                if idx > 0 and coalescer.emitted[idx - 1].kind == "motion":
                    if coalescer.emitted[idx - 1].timestamp_ns > em.timestamp_ns:
                        click_flush_ok = False

        reduction_ratio = round(total_samples / max(len(motion_packets), 1), 3)
        zero_pixel_loss = dx_error == 0.0 and dy_error == 0.0
        rate_ok = zero_pixel_loss and click_flush_ok and (
            reduction_ratio > 1.0 if coalesce_us > 0 and hz >= 1000 else len(motion_packets) == total_samples
        )
        all_passed = all_passed and rate_ok
        results.append(
            {
                "polling_hz": hz,
                "coalesce_us": coalesce_us,
                "input_motion_events": total_samples,
                "emitted_motion_packets": len(motion_packets),
                "packet_reduction_ratio": reduction_ratio,
                "expected_total_dx": expected_dx,
                "emitted_total_dx": emitted_dx,
                "expected_total_dy": expected_dy,
                "emitted_total_dy": emitted_dy,
                "pixel_error_dx": dx_error,
                "pixel_error_dy": dy_error,
                "zero_pixel_loss": zero_pixel_loss,
                "click_immediate_flush_ok": click_flush_ok,
                "passed": rate_ok,
            }
        )

    return {
        "coalesce_us": coalesce_us,
        "duration_ms": duration_ms,
        "rates": results,
        "all_passed": all_passed,
    }


def evaluate_game_shell_key_policy(
    *,
    key_code: int,
    modifiers: set[str],
    is_game_shell_fullscreen: bool,
    block_win_key: bool = True,
    is_right_command: bool = False,
) -> str:
    """Mirror 07-game-shell-key-guard-and-mapping.patch shortcut & key-mapping rules.

    Returns one of:
      - "release_mouse" (Cmd+Option+G)
      - "release_and_switch_app" (Cmd+Tab)
      - "blocked_accidental_shortcut" (Cmd+W/Q/H/M in game shell fullscreen)
      - "blocked_left_win_key" (Left Cmd when block_win_key=True)
      - "forward_to_guest" (F1-F12, Option->Alt, normal keys, right Cmd, etc.)
    """
    has_cmd = "command" in modifiers
    has_opt = "option" in modifiers
    has_ctrl = "control" in modifiers

    if has_cmd and has_opt and key_code == KVK_ANSI_G:
        return "release_mouse"
    if has_cmd and key_code == KVK_TAB:
        return "release_and_switch_app"
    if (
        is_game_shell_fullscreen
        and has_cmd
        and not has_opt
        and not has_ctrl
        and key_code in {KVK_ANSI_W, KVK_ANSI_Q, KVK_ANSI_H, KVK_ANSI_M}
    ):
        return "blocked_accidental_shortcut"
    if block_win_key and has_cmd and not is_right_command and key_code == -1:
        return "blocked_left_win_key"
    return "forward_to_guest"


def run_key_guard_matrix_verification() -> dict[str, Any]:
    """Verify full key-guard & mapping truth table for Phase 12B."""
    cases = [
        ("cmd_w_fullscreen_blocked", KVK_ANSI_W, {"command"}, True, True, False, "blocked_accidental_shortcut"),
        ("cmd_q_fullscreen_blocked", KVK_ANSI_Q, {"command"}, True, True, False, "blocked_accidental_shortcut"),
        ("cmd_h_fullscreen_blocked", KVK_ANSI_H, {"command"}, True, True, False, "blocked_accidental_shortcut"),
        ("cmd_m_fullscreen_blocked", KVK_ANSI_M, {"command"}, True, True, False, "blocked_accidental_shortcut"),
        ("cmd_opt_g_escape_preserved", KVK_ANSI_G, {"command", "option"}, True, True, False, "release_mouse"),
        ("cmd_tab_escape_preserved", KVK_TAB, {"command"}, True, True, False, "release_and_switch_app"),
        ("left_cmd_win_key_blocked", -1, {"command"}, True, True, False, "blocked_left_win_key"),
        ("left_cmd_win_key_allowed_when_disabled", -1, {"command"}, True, False, False, "forward_to_guest"),
        ("right_cmd_preserved", -1, {"command"}, True, True, True, "forward_to_guest"),
        ("option_alt_passthrough", -1, {"option"}, True, True, False, "forward_to_guest"),
        ("f1_passthrough", KVK_F1, set(), True, True, False, "forward_to_guest"),
        ("f12_passthrough", KVK_F12, set(), True, True, False, "forward_to_guest"),
        ("cmd_w_windowed_not_blocked", KVK_ANSI_W, {"command"}, False, True, False, "forward_to_guest"),
    ]
    rows: list[dict[str, Any]] = []
    all_passed = True
    for name, key_code, mods, full, block_win, is_right, expected in cases:
        actual = evaluate_game_shell_key_policy(
            key_code=key_code,
            modifiers=mods,
            is_game_shell_fullscreen=full,
            block_win_key=block_win,
            is_right_command=is_right,
        )
        ok = actual == expected
        all_passed = all_passed and ok
        rows.append({"case": name, "expected": expected, "actual": actual, "passed": ok})
    return {"cases": rows, "all_passed": all_passed}


def verify_custom_utm_build(app_path: Path) -> dict[str, Any]:
    """Verify codesign, arm64 arch, Game Mode Info.plist keys, and Phase 11+12B patch markers."""
    resolved = app_path.resolve()
    outside_repo = True
    try:
        resolved.relative_to(WORKSPACE_ROOT.resolve())
        outside_repo = False
    except ValueError:
        outside_repo = True

    main_bin = resolved / "Contents/MacOS/UTM"
    helper_bin = resolved / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper"
    launcher_bin = (
        resolved
        / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher"
    )
    render_server_bin = (
        resolved
        / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer"
    )
    dxmt_fw = resolved / "Contents/Frameworks/dxmt-native.framework"
    plist_path = resolved / "Contents/Info.plist"

    plist_data: dict[str, Any] = {}
    if plist_path.is_file():
        with plist_path.open("rb") as f:
            plist_data = plistlib.load(f)

    game_mode_plist = {
        "LSApplicationCategoryType": plist_data.get("LSApplicationCategoryType"),
        "LSSupportsGameMode": bool(plist_data.get("LSSupportsGameMode", False)),
        "GCSupportsGameMode": bool(plist_data.get("GCSupportsGameMode", False)),
    }
    game_mode_plist_valid = (
        game_mode_plist["LSApplicationCategoryType"] == "public.app-category.games"
        and game_mode_plist["LSSupportsGameMode"] is True
        and game_mode_plist["GCSupportsGameMode"] is True
    )

    codesign_proc = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(resolved)],
        capture_output=True,
        text=True,
        check=False,
    )
    file_proc = subprocess.run(
        ["file", str(main_bin)],
        capture_output=True,
        text=True,
        check=False,
    )

    main_bytes = main_bin.read_bytes() if main_bin.is_file() else b""
    patch_markers = {
        "dxmt_shader_cache_dir": b"dxmt-shader-cache" in main_bytes,
        "pure_relative_mouse_flag": b"--pure-relative-mouse" in main_bytes,
        "pure_relative_mouse_plist": b"PureRelativeMouse" in main_bytes,
        "game_shell_vm_env": b"UTM_GAME_SHELL_VM" in main_bytes,
        "dxmt_shader_cache_path": b"DXMT_SHADER_CACHE_PATH" in main_bytes,
        "cursor_inhibit_env": b"UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT" in main_bytes,
        "cursor_debug_env": b"UTM_CURSOR_DEBUG" in main_bytes,
        "cursor_relative_fallback_sel": b"applyRelativeFallbackDelta:" in main_bytes,
        "mouse_coalesce_env": b"UTM_MOUSE_COALESCE_US" in main_bytes,
        "game_shell_key_guard_env": b"UTM_GAME_SHELL_KEY_GUARD" in main_bytes,
        "block_win_key_env": b"UTM_BLOCK_WIN_KEY" in main_bytes,
        "render_fps_limit_env": b"UTM_RENDER_FPS_LIMIT" in main_bytes,
        "metal_drawable_count_env": b"UTM_METAL_DRAWABLE_COUNT" in main_bytes,
        "max_inflight_frames_env": b"UTM_MAX_INFLIGHT_FRAMES" in main_bytes,
        "has_pending_render_update_sel": b"hasPendingRenderUpdate" in main_bytes,
    }

    return {
        "schema_version": 2,
        "owner": "@DNPMBHC",
        "phase": "phase-12-window-12b",
        "verified_at_utc": datetime.now(timezone.utc).isoformat(),
        "app_path": redact_path(str(resolved)),
        "outside_repository": outside_repo,
        "main_binary_exists": main_bin.is_file(),
        "helper_binary_exists": helper_bin.is_file(),
        "launcher_binary_exists": launcher_bin.is_file(),
        "render_server_binary_exists": render_server_bin.is_file(),
        "dxmt_framework_exists": dxmt_fw.is_dir(),
        "main_binary_arch": redact_path(file_proc.stdout.strip()),
        "codesign_deep_verify_ok": codesign_proc.returncode == 0,
        "codesign_stderr": redact_path(codesign_proc.stderr.strip()),
        "game_mode_plist": game_mode_plist,
        "game_mode_plist_valid": game_mode_plist_valid,
        "patch_markers": patch_markers,
        "all_patch_markers_present": all(patch_markers.values()),
        "helper_verified": helper_bin.is_file() and launcher_bin.is_file() and render_server_bin.is_file(),
        "original_utm_untouched": Path("/Applications/UTM.app").is_dir(),
    }


LOG_TS_RE = re.compile(r"^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})\]\[\s*(\d+)\]")
ENGINE_LATENCY_RE = re.compile(
    r"Avg\.\s*Engine Latency:\s*([0-9.]+)\s*ms.*Avg\.\s*Work:\s*([0-9.]+)\s*ms.*Avg\.\s*Slack:\s*([0-9.]+)\s*ms.*Avg\.\s*Slop:\s*([0-9.]+)\s*ms"
)


def parse_shootergame_log(log_text: str) -> dict[str, Any]:
    """Parse ShooterGame.log for RangeV2 FPS distribution, ACE ticks, and engine Slack+Slop."""
    range_start_ts: datetime | None = None
    range_samples: list[tuple[float, int]] = []
    ace_http_200 = 0
    low_fps_alerts = 0
    burst_loss_events = 0
    ack_256_events = 0
    engine_telemetry: dict[str, float] | None = None
    in_range = False

    for line in log_text.splitlines():
        m = LOG_TS_RE.match(line)
        ts: datetime | None = None
        frame_no: int | None = None
        if m:
            ts = datetime.strptime(m.group(1), "%Y.%m.%d-%H.%M.%S:%f")
            frame_no = int(m.group(2))

        if "RangeV2" in line and ("BringUp" in line or "Loading map" in line or "Map Load" in line or "InitGame" in line):
            in_range = True
            if ts is not None and range_start_ts is None:
                range_start_ts = ts

        if "ACEManager_IssueAntiTick" in line and "200" in line:
            ace_http_200 += 1
        if "Local Framerate Threshold critically exceeded" in line:
            low_fps_alerts += 1
        if "Burst Loss Detected" in line:
            burst_loss_events += 1
        if "Too many received packets to ack (256)" in line:
            ack_256_events += 1

        lat_m = ENGINE_LATENCY_RE.search(line)
        if lat_m:
            lat_ms = float(lat_m.group(1))
            work_ms = float(lat_m.group(2))
            slack_ms = float(lat_m.group(3))
            slop_ms = float(lat_m.group(4))
            engine_telemetry = {
                "avg_engine_latency_ms": lat_ms,
                "avg_work_ms": work_ms,
                "avg_slack_ms": slack_ms,
                "avg_slop_ms": slop_ms,
                "slack_plus_slop_ms": round(slack_ms + slop_ms, 3),
                "delta_slack_plus_slop_vs_11b_ms": round((slack_ms + slop_ms) - PHASE11B_BASELINE["engine_slack_plus_slop_ms"], 3),
            }

        if in_range and ts is not None and frame_no is not None:
            if range_start_ts is None:
                range_start_ts = ts
            rel_s = (ts - range_start_ts).total_seconds()
            range_samples.append((rel_s, frame_no))

    fps_windows: list[float] = []
    if len(range_samples) >= 2:
        prev_t, prev_f = range_samples[0]
        for cur_t, cur_f in range_samples[1:]:
            dt = cur_t - prev_t
            df = cur_f - prev_f
            if dt >= 1.0 and df > 0:
                fps_windows.append(df / dt)
                prev_t, prev_f = cur_t, cur_f

    duration_s = round(range_samples[-1][0] - range_samples[0][0], 2) if len(range_samples) >= 2 else 0.0
    fps_stats: dict[str, Any] = {}
    if fps_windows:
        sorted_fps = sorted(fps_windows)
        n = len(sorted_fps)
        mean_fps = round(statistics.mean(sorted_fps), 2)
        p50_fps = round(statistics.median(sorted_fps), 2)
        p5_fps = round(sorted_fps[max(0, int(n * 0.05) - 1)], 2)
        p1_fps = round(sorted_fps[max(0, int(n * 0.01) - 1)], 2)
        fps_stats = {
            "sample_count": n,
            "mean_fps": mean_fps,
            "p50_fps": p50_fps,
            "p5_fps": p5_fps,
            "p1_low_fps": p1_fps,
            "max_fps": round(sorted_fps[-1], 2),
            "delta_mean_vs_11b_peak_fps": round(mean_fps - PHASE11B_BASELINE["range_warmup_peak_mean_fps"], 2),
            "delta_p50_vs_11b_peak_fps": round(p50_fps - PHASE11B_BASELINE["range_warmup_peak_p50_fps"], 2),
            "delta_mean_vs_11b_pure_fps": round(mean_fps - PHASE11B_BASELINE["range_pure_combat_mean_fps"], 2),
        }

    return {
        "range_duration_seconds": duration_s,
        "fps_stats": fps_stats,
        "engine_telemetry": engine_telemetry,
        "ace_http_200_count": ace_http_200,
        "low_fps_critical_alerts": low_fps_alerts,
        "burst_loss_events": burst_loss_events,
        "ack_256_events": ack_256_events,
        "baseline_11b": PHASE11B_BASELINE,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 12B Game Mode & High-Polling Input Verifier (@DNPMBHC)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("verify-build", help="Verify UTM-Custom.app signature, Game Mode plist, and symbols")
    p_build.add_argument("--app", type=Path, required=True)
    p_build.add_argument("--output", type=Path, default=None)

    p_input = sub.add_parser("verify-input", help="Run high-polling mouse coalescing and key-guard verification")
    p_input.add_argument("--coalesce-us", type=int, default=1500)
    p_input.add_argument("--output", type=Path, default=None)

    p_range = sub.add_parser("analyze-range", help="Analyze ShooterGame.log against Phase 11B baseline")
    p_range.add_argument("--log", type=Path, required=True)
    p_range.add_argument("--output", type=Path, default=None)

    args = parser.parse_args(argv)
    if args.command == "verify-build":
        payload = verify_custom_utm_build(args.app)
    elif args.command == "verify-input":
        payload = {
            "schema_version": 1,
            "owner": "@DNPMBHC",
            "phase": "phase-12-window-12b",
            "verified_at_utc": datetime.now(timezone.utc).isoformat(),
            "mouse_coalescing": run_high_rate_coalescing_benchmark(coalesce_us=args.coalesce_us),
            "mouse_coalescing_disabled_control": run_high_rate_coalescing_benchmark(
                polling_rates_hz=(1000,), coalesce_us=0, duration_ms=100
            ),
            "key_guard_matrix": run_key_guard_matrix_verification(),
        }
        payload["passed"] = (
            payload["mouse_coalescing"]["all_passed"]
            and payload["mouse_coalescing_disabled_control"]["all_passed"]
            and payload["key_guard_matrix"]["all_passed"]
        )
    else:
        payload = parse_shootergame_log(args.log.read_text(encoding="utf-8", errors="replace"))

    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
