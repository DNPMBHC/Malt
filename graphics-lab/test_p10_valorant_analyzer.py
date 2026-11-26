#!/usr/bin/env python3
"""Offline unit tests for Phase 10A cursor trial & training-range benchmark analyzer.

Owner: @DNPMBHC
"""
from __future__ import annotations

import json
import os
import unittest

import p10_valorant_analyzer as analyzer


class P10ValorantAnalyzerTests(unittest.TestCase):
    def test_parse_qemu_input_devices(self) -> None:
        cmd_tablet = "qemu-system-aarch64 -device usb-tablet,bus=usb-bus.0 -device usb-kbd"
        r1 = analyzer.parse_qemu_input_devices(cmd_tablet)
        self.assertTrue(r1["has_usb_tablet"])
        self.assertFalse(r1["pure_relative_mouse_only"])

        cmd_mouse = "qemu-system-aarch64 -device usb-mouse,bus=usb-bus.0 -device usb-kbd"
        r2 = analyzer.parse_qemu_input_devices(cmd_mouse)
        self.assertFalse(r2["has_usb_tablet"])
        self.assertTrue(r2["has_usb_mouse"])
        self.assertTrue(r2["pure_relative_mouse_only"])

    def test_summarize_cursor_trials(self) -> None:
        s1 = analyzer.summarize_cursor_trials(
            [
                {"trial_id": "t1_usb_mouse", "in_game_cursor_visible": False, "relative_aim_working": True},
                {"trial_id": "t2_vdagent_off", "in_game_cursor_visible": False, "relative_aim_working": True},
            ]
        )
        self.assertFalse(s1["in_game_cursor_resolved"])
        self.assertTrue(s1["requires_cocoaspice_host_patch"])

        s2 = analyzer.summarize_cursor_trials(
            [
                {"trial_id": "t1_usb_mouse", "in_game_cursor_visible": True, "relative_aim_working": True},
            ]
        )
        self.assertTrue(s2["in_game_cursor_resolved"])
        self.assertFalse(s2["requires_cocoaspice_host_patch"])

    def test_summarize_range_benchmark_and_ace_verdict(self) -> None:
        host = [
            {"elapsed_seconds": 0.0, "qemu_render_server_cpu": 40.0, "qemu_worker_cpu": 210.0, "total_hypervisor_rss_mib": 2800.0},
            {"elapsed_seconds": 120.0, "qemu_render_server_cpu": 48.0, "qemu_worker_cpu": 225.0, "total_hypervisor_rss_mib": 2950.0},
            {"elapsed_seconds": 240.0, "qemu_render_server_cpu": 44.0, "qemu_worker_cpu": 220.0, "total_hypervisor_rss_mib": 2900.0},
        ]
        guest = [
            {"elapsed_seconds": 0.0, "shipping_alive": True, "estimated_fps": 62.0},
            {"elapsed_seconds": 120.0, "shipping_alive": True, "estimated_fps": 70.0},
            {"elapsed_seconds": 240.0, "shipping_alive": True, "estimated_fps": 66.0},
        ]
        bench = analyzer.summarize_range_benchmark(host, guest)
        self.assertEqual(bench["observed_duration_seconds"], 240.0)
        self.assertTrue(bench["shipping_alive_all_samples"])
        self.assertEqual(bench["fps"]["p50"], 66.0)

        verdict = analyzer.classify_final_ace_verdict(
            entered_lobby=True,
            entered_training_range=True,
            observed_duration_seconds=240.0,
            kicked_or_error_popup=False,
            queue_precheck_attempted=False,
            queue_precheck_rejected=False,
            ace_game_1275_present=True,
            main_exit_code=None,
        )
        self.assertEqual(verdict["status"], "training_range_stable_no_kick_in_window")

    def test_build_p10_real_run_report_redacts_pii(self) -> None:
        user_name = os.environ.get("USER") or "user"
        report = analyzer.build_p10_real_run_report(
            golden_manifest_sha256="deadbeef",
            ephemeral_clone_name="ephemeral-p10a-valorant",
            cursor_trials_summary={"note": f"/Volumes/SecretVol/x /Users/{user_name}/y"},
            range_benchmark={"fps": {"mean": 65.0}},
            ace_verdict={"status": "lobby_and_range_not_reached"},
            drift_verification={"utm_defaults_restored": True, "golden_zero_drift": True, "primary_zero_drift": True},
            five_dimensions={
                "implementation": "completed",
                "local_gates": "passed",
                "real_guest_run": "executed",
                "vendor_vm_support": "unknown",
                "protected_lobby_and_match": "not_verified",
            },
            notes=["token=abc123", "id=12345678-1234-1234-1234-123456789abc"],
        )
        raw = json.dumps(report)
        self.assertNotIn("SecretVol", raw)
        self.assertNotIn("abc123", raw)
        self.assertNotIn("12345678-1234-1234-1234-123456789abc", raw)
        self.assertTrue(report["compliance"]["utm_defaults_restored"])
        if user_name:
            self.assertNotIn(user_name, raw)

    def test_dual_input_topology_and_blocked_ace_verdict(self) -> None:
        cmd_dual = (
            "qemu-system-aarch64 -device usb-tablet,bus=usb-bus.0 "
            "-device usb-mouse,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0"
        )
        parsed = analyzer.parse_qemu_input_devices(cmd_dual)
        self.assertTrue(parsed["has_usb_tablet"])
        self.assertTrue(parsed["has_usb_mouse"])
        self.assertFalse(parsed["pure_relative_mouse_only"])

        blocked = analyzer.classify_final_ace_verdict(
            entered_lobby=False,
            entered_training_range=False,
            observed_duration_seconds=32.77,
            kicked_or_error_popup=False,
            queue_precheck_attempted=False,
            queue_precheck_rejected=False,
            ace_game_1275_present=False,
            main_exit_code=None,
        )
        self.assertEqual(blocked["status"], "lobby_and_range_not_reached")

        kicked = analyzer.classify_final_ace_verdict(
            entered_lobby=True,
            entered_training_range=False,
            observed_duration_seconds=45.0,
            kicked_or_error_popup=True,
            queue_precheck_attempted=True,
            queue_precheck_rejected=True,
            ace_game_1275_present=True,
            main_exit_code=1,
        )
        self.assertEqual(kicked["status"], "ace_kick_or_restriction_observed")


if __name__ == "__main__":
    unittest.main()
