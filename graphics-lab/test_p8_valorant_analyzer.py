#!/usr/bin/env python3
"""Offline unit tests for Phase 8A telemetry analyzer and report builder.

Owner: @DNPMBHC
"""
from __future__ import annotations

import json
import os
import unittest

import p8_valorant_analyzer as analyzer


class P8ValorantAnalyzerTests(unittest.TestCase):
    def test_percentile_and_numeric_summary(self) -> None:
        vals = [10.0, 20.0, 30.0, 40.0, 50.0]
        self.assertEqual(analyzer.percentile(vals, 50.0), 30.0)
        self.assertEqual(analyzer.percentile(vals, 0.0), 10.0)
        self.assertEqual(analyzer.percentile(vals, 100.0), 50.0)
        summary = analyzer.summarize_numeric(vals)
        self.assertEqual(summary["mean"], 30.0)
        self.assertEqual(summary["p50"], 30.0)
        self.assertEqual(summary["min"], 10.0)
        self.assertEqual(summary["max"], 50.0)

    def test_summarize_stability_series_normal_vs_frozen(self) -> None:
        host_ok = [
            {"elapsed_seconds": 0.0, "qemu_render_server_cpu": 45.0, "qemu_worker_cpu": 180.0, "total_hypervisor_rss_mib": 3200.0},
            {"elapsed_seconds": 180.0, "qemu_render_server_cpu": 52.0, "qemu_worker_cpu": 190.0, "total_hypervisor_rss_mib": 3300.0},
        ]
        guest_ok = [
            {"elapsed_seconds": 0.0, "shipping_alive": True, "last_frame_number": 100, "estimated_fps": 65.0},
            {"elapsed_seconds": 90.0, "shipping_alive": True, "last_frame_number": 520, "estimated_fps": 70.0},
            {"elapsed_seconds": 180.0, "shipping_alive": True, "last_frame_number": 910, "estimated_fps": 68.0},
        ]
        res_ok = analyzer.summarize_stability_series(host_ok, guest_ok)
        self.assertEqual(res_ok["observed_duration_seconds"], 180.0)
        self.assertTrue(res_ok["shipping_alive_all_samples"])
        self.assertFalse(res_ok["freeze_detected"])
        self.assertEqual(res_ok["estimated_fps"]["p50"], 68.0)

        host_frozen = [{"elapsed_seconds": float(i), "qemu_render_server_cpu": 0.0, "qemu_worker_cpu": 100.0, "total_hypervisor_rss_mib": 2000.0} for i in range(6)]
        guest_frozen = [
            {"elapsed_seconds": 0.0, "shipping_alive": True, "last_frame_number": 132},
            {"elapsed_seconds": 15.0, "shipping_alive": True, "last_frame_number": 132},
            {"elapsed_seconds": 30.0, "shipping_alive": True, "last_frame_number": 132},
        ]
        res_frozen = analyzer.summarize_stability_series(host_frozen, guest_frozen)
        self.assertTrue(res_frozen["freeze_detected"])

    def test_classify_ace_game_1275_impact(self) -> None:
        c_stable = analyzer.classify_ace_game_1275_impact(
            entered_lobby_or_range=True,
            observed_duration_seconds=200.0,
            shipping_stayed_alive=True,
            kicked_or_anticheat_popup=False,
            main_exit_code=None,
            ace_game_1275_seen=True,
        )
        self.assertEqual(c_stable["status"], "stable_no_kick_observed_in_window")

        c_kicked = analyzer.classify_ace_game_1275_impact(
            entered_lobby_or_range=True,
            observed_duration_seconds=45.0,
            shipping_stayed_alive=False,
            kicked_or_anticheat_popup=True,
            main_exit_code=5,
            ace_game_1275_seen=True,
        )
        self.assertEqual(c_kicked["status"], "kicked_or_anticheat_error_observed")

    def test_redaction_and_report_builder(self) -> None:
        user_name = os.environ.get("USER") or "user"
        report = analyzer.build_p8_real_run_report(
            golden_manifest_sha256="deadbeef",
            ephemeral_clone_name="ephemeral-p8a-valorant",
            display_and_pointer_config={"note": f"/Volumes/SecretVol/foo /Users/{user_name}/bar"},
            stability_summary={"observed_duration_seconds": 180.0},
            ace_impact={"status": "stable_no_kick_observed_in_window"},
            drift_verification={"golden_zero_drift": True, "primary_zero_drift": True},
            five_dimensions={
                "implementation": "completed",
                "local_gates": "passed",
                "real_guest_run": "executed",
                "vendor_vm_support": "unknown",
                "protected_lobby_and_match": "not_verified",
            },
            notes=["id=12345678-1234-1234-1234-123456789abc", "password=secret"],
        )
        raw = json.dumps(report)
        self.assertNotIn("SecretVol", raw)
        self.assertNotIn("12345678-1234-1234-1234-123456789abc", raw)
        self.assertNotIn("secret", raw)
        if user_name:
            self.assertNotIn(user_name, raw)


if __name__ == "__main__":
    unittest.main()
