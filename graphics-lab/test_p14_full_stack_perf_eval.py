#!/usr/bin/env python3
"""Unit tests for graphics-lab/p14_full_stack_perf_eval.py (@DNPMBHC)."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import p14_full_stack_perf_eval as p14


class TestP14FullStackPerfEval(unittest.TestCase):
    def test_summarize_frame_times_ms(self) -> None:
        samples = [16.0] * 95 + [20.0, 25.0, 35.0, 42.0, 50.0]
        res = p14.summarize_frame_times_ms(samples, severe_threshold_ms=33.333)
        self.assertEqual(res["count"], 100)
        self.assertEqual(res["severe_drop_count"], 3)
        self.assertAlmostEqual(res["severe_drop_pct"], 3.0)
        self.assertGreater(res["fps_mean"], 55.0)
        self.assertLess(res["fps_p1_low"], 25.0)
        self.assertGreater(res["frame_ms_jitter_p99_p50"], 20.0)

    def test_compare_dual_cache_runs(self) -> None:
        cold = {
            "frame_metrics": {
                "fps_mean": 48.0,
                "fps_p1_low": 22.0,
                "frame_ms_p99": 45.0,
                "severe_drop_count": 10,
            },
            "host_cpu": {"qemu_worker_cpu_mean": 420.0, "render_server_cpu_mean": 35.0},
            "guest_cpu_avg_pct": 78.0,
            "dxmt_cache_before_bytes": 0,
            "xtacache_before_bytes": 0,
        }
        warm = {
            "frame_metrics": {
                "fps_mean": 57.6,
                "fps_p1_low": 33.0,
                "frame_ms_p99": 30.0,
                "severe_drop_count": 2,
            },
            "host_cpu": {"qemu_worker_cpu_mean": 357.0, "render_server_cpu_mean": 28.0},
            "guest_cpu_avg_pct": 62.4,
            "dxmt_cache_before_bytes": 9_000_000,
            "xtacache_before_bytes": 45_000_000,
        }
        cmp = p14.compare_dual_cache_runs(cold, warm)
        self.assertEqual(cmp["fps_mean_delta_pct"], 20.0)
        self.assertEqual(cmp["fps_p1_low_delta_pct"], 50.0)
        self.assertEqual(cmp["severe_drop_reduction_pct"], 80.0)
        self.assertEqual(cmp["guest_cpu_delta_pct"], -20.0)
        self.assertTrue(cmp["dxmt_cache_persisted"])
        self.assertTrue(cmp["xtacache_persisted"])

    def test_select_best_frame_sync_arm(self) -> None:
        arms = [
            {
                "label": "fps_limit_0_triple",
                "fps_limit": 0,
                "metal_drawable_count": 3,
                "max_inflight_frames": 3,
                "frame_metrics": {"fps_mean": 62.0, "fps_p1_low": 38.0, "frame_ms_jitter_p99_p50": 11.5},
            },
            {
                "label": "fps_limit_120_lowlat_d2_i1",
                "fps_limit": 120,
                "metal_drawable_count": 2,
                "max_inflight_frames": 1,
                "frame_metrics": {"fps_mean": 63.5, "fps_p1_low": 49.0, "frame_ms_jitter_p99_p50": 4.2},
            },
        ]
        sel = p14.select_best_frame_sync_arm(arms)
        self.assertEqual(sel["recommended_arm"], "fps_limit_120_lowlat_d2_i1")
        self.assertEqual(sel["fps_limit"], 120)
        self.assertEqual(sel["metal_drawable_count"], 2)
        self.assertEqual(sel["max_inflight_frames"], 1)

    def test_audit_qemu_polling_devices_clean_vs_bloated(self) -> None:
        clean_cmd = (
            "/usr/bin/qemu-aarch64-softmmu -smp cpus=8 -m 10240 "
            "-device virtio-gpu-gl-pci -device virtio-blk-pci,num-queues=4 "
            "-netdev stream,id=net0,addr.type=inet -device virtio-net-pci,netdev=net0,ioeventfd=on "
            "-device usb-mouse,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0 "
            "-device intel-hda -device tpm-tis-device"
        )
        clean = p14.audit_qemu_polling_devices(clean_cmd)
        self.assertFalse(clean["has_usb_tablet"])
        self.assertFalse(clean["has_virtio_balloon"])
        self.assertFalse(clean["has_slirp_user_net"])
        self.assertTrue(clean["clean_of_known_polling_bloat"])
        self.assertEqual(clean["removable_polling_devices"], [])

        bloated_cmd = clean_cmd + " -device usb-tablet -device virtio-balloon-pci -netdev user,id=u0"
        bloated = p14.audit_qemu_polling_devices(bloated_cmd)
        self.assertTrue(bloated["has_usb_tablet"])
        self.assertTrue(bloated["has_virtio_balloon"])
        self.assertTrue(bloated["has_slirp_user_net"])
        self.assertFalse(bloated["clean_of_known_polling_bloat"])
        self.assertIn("usb-tablet", bloated["removable_polling_devices"])

    def test_parse_shooter_engine_latency_and_warnings(self) -> None:
        sample_log = "\n".join([
            "[2026.11.25-14:00:01] LogClientPerRoundTelemetryComponent: Avg. Engine Latency: 18.10 ms (Work: 16.50 ms, Slack: 1.25 ms, Slop: 0.35 ms)",
            "[2026.11.25-14:01:00] LogACE: ACEManager_IssueAntiTick HTTP 200 OK",
            "[2026.11.25-14:02:00] LogACE: ACEManager_IssueAntiTick HTTP 200 OK",
            "[2026.11.25-14:04:55] LogNet: Disconnect Reason: ManualQuit",
        ])
        parsed = p14.parse_shooter_engine_latency(sample_log)
        self.assertIsNotNone(parsed["latest_engine_latency"])
        self.assertEqual(parsed["latest_engine_latency"]["slack_plus_slop_ms"], 1.6)
        self.assertEqual(parsed["slirp_network_warnings_total"], 0)
        self.assertEqual(parsed["ace_anti_tick_http_200_count"], 2)
        self.assertTrue(parsed["clean_manual_quit"])

    def test_compare_against_phase11b_baseline(self) -> None:
        cur = {
            "range_mean_fps": 61.2,
            "range_p50_fps": 63.0,
            "range_p1_low_fps": 38.5,
            "slack_plus_slop_ms": 1.6,
            "slirp_network_warnings_total": 0,
        }
        cmp = p14.compare_against_phase11b_baseline(cur)
        self.assertTrue(cmp["reached_60fps_steady"])
        self.assertTrue(cmp["slirp_warnings_zero"])
        self.assertGreater(cmp["mean_fps_delta_pct"], 10.0)
        self.assertLess(cmp["slack_plus_slop_delta_ms"], 0.0)

    def test_redaction_and_report_markdown(self) -> None:
        user = os.environ.get("USER") or Path.home().name
        raw = {
            "path": f"/Volumes/SecretSSD/vms/test-12345678-1234-1234-1234-123456789abc.utm",
            "user_path": f"/Users/{user}/Documents/secret",
        }
        redacted = p14.redact_p14_value(raw)
        self.assertNotIn("SecretSSD", redacted["path"])
        self.assertNotIn("12345678-1234", redacted["path"])
        self.assertNotIn(user, redacted["user_path"])

        md = p14.render_p14a_report_markdown(
            deep_dive={"exp_dual_cache": {"comparison": {}}, "exp_frame_sync": {"selection": {}}, "exp_irq_audit": {}},
            e2e_report={"phase11b_comparison": {}, "next_gen_physical_ceiling": {"summary": "honest ceiling"}},
            zero_drift={"zero_drift": True},
        )
        self.assertIn("Phase 14 窗口 14A", md)
        self.assertIn("honest ceiling", md)


if __name__ == "__main__":
    unittest.main()
