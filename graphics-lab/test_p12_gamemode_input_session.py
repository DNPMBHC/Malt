#!/usr/bin/env python3
"""Unit tests for Phase 12B Game Mode, high-polling mouse coalescing, and key guard.

Owner: @DNPMBHC
"""
from __future__ import annotations

import unittest

import p12_gamemode_input_session as p12b


class P12GameModeInputSessionTests(unittest.TestCase):
    def test_high_polling_coalescer_zero_pixel_loss_and_packet_reduction(self) -> None:
        report = p12b.run_high_rate_coalescing_benchmark(
            polling_rates_hz=(1000, 2000, 4000, 8000),
            coalesce_us=1500,
            duration_ms=200,
        )
        self.assertTrue(report["all_passed"])
        by_hz = {r["polling_hz"]: r for r in report["rates"]}
        for hz in (1000, 2000, 4000, 8000):
            row = by_hz[hz]
            self.assertEqual(row["pixel_error_dx"], 0.0)
            self.assertEqual(row["pixel_error_dy"], 0.0)
            self.assertTrue(row["zero_pixel_loss"])
            self.assertTrue(row["click_immediate_flush_ok"])
        self.assertGreater(by_hz[4000]["packet_reduction_ratio"], 4.0)
        self.assertGreater(by_hz[8000]["packet_reduction_ratio"], 8.0)

    def test_coalescer_disabled_when_window_zero(self) -> None:
        report = p12b.run_high_rate_coalescing_benchmark(
            polling_rates_hz=(1000,),
            coalesce_us=0,
            duration_ms=50,
        )
        self.assertTrue(report["all_passed"])
        row = report["rates"][0]
        self.assertEqual(row["input_motion_events"], row["emitted_motion_packets"])
        self.assertEqual(row["pixel_error_dx"], 0.0)

    def test_click_flushes_pending_delta_immediately_before_button_down(self) -> None:
        c = p12b.HighRateMouseCoalescer(coalesce_us=2000)
        c.process(p12b.MouseInputEvent(timestamp_ns=1_000_000, kind="move", dx=3.0, dy=-1.0))
        c.process(p12b.MouseInputEvent(timestamp_ns=1_250_000, kind="move", dx=4.0, dy=2.0))
        c.process(p12b.MouseInputEvent(timestamp_ns=1_500_000, kind="move", dx=5.0, dy=-3.0))
        # Click arrives inside the 2000 us window; pending (9, -1) MUST flush before button_down
        c.process(p12b.MouseInputEvent(timestamp_ns=1_600_000, kind="button_down", button="left"))
        self.assertEqual(len(c.emitted), 3)
        self.assertEqual(c.emitted[1].kind, "motion")
        self.assertEqual(c.emitted[1].dx, 9.0)
        self.assertEqual(c.emitted[1].dy, -1.0)
        self.assertTrue(c.emitted[1].flushed_before_action)
        self.assertEqual(c.emitted[2].kind, "button_down")

    def test_game_shell_key_guard_matrix(self) -> None:
        matrix = p12b.run_key_guard_matrix_verification()
        self.assertTrue(matrix["all_passed"])

    def test_parse_shootergame_log_against_11b_baseline(self) -> None:
        sample_log = "\n".join(
            [
                "[2026.11.25-07.00.00:000][  100]LogWorld: BringUp World RangeV2",
                "[2026.11.25-07.00.01:000][  162]LogAres: ACEManager_IssueAntiTick HTTP 200",
                "[2026.11.25-07.00.02:000][  225]LogAres: ACEManager_IssueAntiTick HTTP 200",
                "[2026.11.25-07.00.03:000][  287]LogClientPerRoundTelemetryComponent: Avg. Engine Latency: 20.10 ms, Avg. Work: 18.60 ms, Avg. Slack: 1.20 ms, Avg. Slop: 0.30 ms",
            ]
        )
        parsed = p12b.parse_shootergame_log(sample_log)
        self.assertEqual(parsed["ace_http_200_count"], 2)
        self.assertAlmostEqual(parsed["fps_stats"]["mean_fps"], 62.33, places=1)
        self.assertIsNotNone(parsed["engine_telemetry"])
        self.assertAlmostEqual(parsed["engine_telemetry"]["slack_plus_slop_ms"], 1.50, places=2)
        self.assertLess(parsed["engine_telemetry"]["delta_slack_plus_slop_vs_11b_ms"], 0.0)


if __name__ == "__main__":
    unittest.main()
