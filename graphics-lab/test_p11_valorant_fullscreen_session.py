#!/usr/bin/env python3
"""Unit tests for Phase 11B UTM-Custom verification, cursor log parsing, and report assembly.

Owner: @DNPMBHC
"""
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import p11_valorant_fullscreen_session as p11


class P11ValorantFullscreenSessionTests(unittest.TestCase):
    def test_summarize_fps_series_computes_mean_p50_and_p1_low(self) -> None:
        samples = [40.0, 58.0, 60.0, 61.0, 62.0, 65.0, 70.0, 72.0, 75.0, 80.0]
        summary = p11.summarize_fps_series(samples)
        self.assertEqual(summary["count"], 10)
        self.assertAlmostEqual(summary["mean"], 64.3, places=2)
        self.assertAlmostEqual(summary["p50"], 63.5, places=2)
        self.assertLess(summary["p1_low"], 45.0)
        self.assertGreater(summary["p99_frame_time_ms"], summary["mean_frame_time_ms"])

    def test_scan_binary_markers_detects_all_custom_utm_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fake_bin = Path(tmp) / "UTM"
            fake_bin.write_bytes(
                b"header dxmt-shader-cache --pure-relative-mouse PureRelativeMouse UTM_GAME_SHELL_VM "
                b"DXMT_SHADER_CACHE_PATH UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT [UTM-Custom Cursor] "
                b"applyRelativeFallbackDelta: tail"
            )
            markers = p11.scan_binary_markers(fake_bin)
            self.assertTrue(all(markers.values()))

    def test_parse_cursor_debug_log_counts_events_and_modes(self) -> None:
        sample_log = "\n".join(
            [
                "2026-11-25 UTM[123] [UTM-Custom Cursor] mouse_mode=1 pos=(640.0,360.0) hasCursor=1 visible=1",
                "2026-11-25 UTM[123] [UTM-Custom Cursor] set 32x32 hotspot=(16,16) nonZeroAlpha=128/1024 hasDevice=1 hasTexture=1 pos=(640.0,360.0)",
                "2026-11-25 UTM[123] [UTM-Custom Cursor] move (652,374) visible=1",
                "2026-11-25 UTM[123] [UTM-Custom Cursor] hide",
            ]
        )
        parsed = p11.parse_cursor_debug_log(sample_log)
        self.assertEqual(parsed["cursor_set_events"], 1)
        self.assertEqual(parsed["cursor_set_with_texture_events"], 1)
        self.assertEqual(parsed["cursor_move_events"], 1)
        self.assertEqual(parsed["cursor_hide_events"], 1)
        self.assertEqual(parsed["mouse_modes_seen"], [1])

    def test_build_final_report_redacts_paths_and_classifies_ace_verdict(self) -> None:
        report = p11.build_p11_final_report(
            build_verification={"codesign_deep_verify_ok": True, "app_path": "/Volumes/MyExternalDisk/utm-custom/UTM-Custom.app"},
            cursor_validation={
                "pure_relative_mouse_only": True,
                "non_captured_cursor_visible": True,
                "captured_cursor_visible": True,
            },
            fullscreen_validation={
                "borderless_fullscreen_ok": True,
                "cmd_tab_switch_ok": True,
                "audio_output_ok": True,
            },
            host_samples=[
                {"elapsed_seconds": 0.0, "qemu_render_server_cpu": 42.0, "qemu_worker_cpu": 180.0, "total_hypervisor_rss_mib": 7800.0},
                {"elapsed_seconds": 210.0, "qemu_render_server_cpu": 48.0, "qemu_worker_cpu": 190.0, "total_hypervisor_rss_mib": 8050.0},
            ],
            guest_samples=[],
            in_game_fps_readings=[55.0, 62.0, 66.0, 71.0],
            ace_eventlog={"event_1275_count": 0, "event_7000_count": 0},
            stage_flags={
                "entered_character_creation": True,
                "entered_lobby": True,
                "entered_training_range": True,
                "kicked_or_error_popup": False,
            },
            notes=["Checked /Volumes/MyExternalDisk/path cleanly"],
        )
        serialized = str(report)
        self.assertNotIn("MyExternalDisk", serialized)
        self.assertIn("<EXTERNAL_VOLUME>", serialized)
        self.assertEqual(
            report["ace_and_five_dimension_verdict"]["ace_1275_final_verdict"],
            "training_range_3to5m_clean_no_1275_kick",
        )
        self.assertEqual(report["ace_and_five_dimension_verdict"]["protected_matchmaking"], "not_verified")
        md = p11.render_summary_markdown(report)
        self.assertIn("Phase 11B `target-cn`", md)
        self.assertIn("@DNPMBHC", md)

    def test_cursor_probe_powershell_script_contains_win32_and_rawinput(self) -> None:
        script = p11.cursor_probe_powershell_script()
        self.assertIn("CreateIconIndirect", script)
        self.assertIn("RegisterRawInputDevices", script)
        self.assertIn("GetCursorInfo", script)


if __name__ == "__main__":
    unittest.main()
