#!/usr/bin/env python3
"""Offline unit tests for Phase 13A burst performance & warm-standby benchmark. Owner: @DNPMBHC."""
from __future__ import annotations

import unittest

import p13_burst_perf_benchmark as p13b


class P13BurstPerfBenchmarkTests(unittest.TestCase):
    def test_compare_burst_arms_quantifies_p1_low_and_max_frame_ms(self) -> None:
        baseline = {
            "phases": {
                "burst": {
                    "fps": {"mean": 72.0, "p50": 74.0, "p1_low": 38.0, "p0_1_low": 24.0},
                    "cpu_frame_ms": {"p99": 26.3, "max": 48.5},
                }
            }
        }
        optimized = {
            "phases": {
                "burst": {
                    "fps": {"mean": 82.0, "p50": 84.0, "p1_low": 52.0, "p0_1_low": 41.0},
                    "cpu_frame_ms": {"p99": 19.2, "max": 28.0},
                }
            }
        }
        cmp_res = p13b.compare_burst_arms(baseline, optimized)
        self.assertTrue(cmp_res["burst_p1_low_improved"])
        self.assertTrue(cmp_res["burst_max_frame_ms_reduced"])
        self.assertGreater(cmp_res["burst_fps_p1_low_delta_pct"], 30.0)
        self.assertLess(cmp_res["burst_max_frame_ms_delta_pct"], -35.0)

    def test_compare_cold_vs_warm_launch(self) -> None:
        res = p13b.compare_cold_vs_warm_launch(28.5, 2.5)
        self.assertEqual(res["cold_boot_ready_seconds"], 28.5)
        self.assertEqual(res["warm_resume_ready_seconds"], 2.5)
        self.assertEqual(res["saved_seconds"], 26.0)
        self.assertGreater(res["speedup_factor"], 10.0)
        self.assertGreater(res["reduction_pct"], 90.0)

    def test_build_phase_runner_ps1_includes_burst_and_priority_controls(self) -> None:
        ps = p13b.build_phase_runner_ps1(
            phase_label="burst",
            frames=100,
            warmup=10,
            commands=4096,
            resource_bytes=4194304,
            bg_compute_threads=4,
            elevate_high_priority=True,
            shader_cache_dir=r"C:\graphics-lab\p13a\dxmt-cache",
            csv_guest=r"C:\graphics-lab\p13a\out.csv",
            done_guest=r"C:\graphics-lab\p13a\out.done",
            err_guest=r"C:\graphics-lab\p13a\out.err",
        )
        self.assertIn("DXMT_SHADER_CACHE", ps)
        self.assertIn("P13BurstCompute", ps)
        self.assertIn("PriorityClass = 'High'", ps)
        self.assertIn("4096", ps)
        self.assertIn("4194304", ps)

    def test_redaction_strips_volumes_and_uuids(self) -> None:
        raw = "/Volumes/SecretSSD/11111111-2222-3333-4444-555555555555/test.utm"
        cleaned = p13b.redact_p13_text(raw)
        self.assertNotIn("SecretSSD", cleaned)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", cleaned)
        self.assertIn("/Volumes/<EXTERNAL_VOLUME>", cleaned)
        self.assertIn("<uuid>", cleaned)

    def test_render_report_md_contains_required_sections(self) -> None:
        fake_phase = {
            "fps": {"mean": 80.0, "p50": 82.0, "p1_low": 55.0, "p0_1_low": 42.0},
            "cpu_frame_ms": {"p99": 18.0, "max": 25.0},
        }
        payload = {
            "captured_at_utc": "2026-11-25T10:00:00+00:00",
            "baseline_arm": {"phases": {"steady": fake_phase, "burst": fake_phase, "recovery": fake_phase}},
            "optimized_arm": {"phases": {"steady": fake_phase, "burst": fake_phase, "recovery": fake_phase}},
            "burst_comparison": p13b.compare_burst_arms(
                {"phases": {"burst": fake_phase}},
                {"phases": {"burst": fake_phase}},
            ),
            "warm_standby": {"standby_metrics": {"qemu_cpu_pct": 0.0, "macos_compressor_mib": 512.0}},
            "cold_vs_warm_launch": p13b.compare_cold_vs_warm_launch(28.0, 2.2),
            "post_resume_health": {
                "viogpu3d_post_resume_probe": {"passed": True, "fps_mean": 95.0},
                "secure_boot_enabled": True,
                "tpm_ready": True,
                "prism_files_present": True,
                "test_signing_disabled": True,
            },
            "kiosk_shell_verification": {
                "compliance": {
                    "zero_dwm_hook": True,
                    "zero_process_injection": True,
                    "read_only_foreground_polling": True,
                },
                "enter": {"taskbar_hidden": True, "desktop_icons_hidden": True, "background_solid_black": True},
                "restore": {"restored": True, "taskbar_visible": True, "desktop_icons_visible": True},
            },
        }
        zero_drift = {
            "golden_zero_drift": True,
            "golden_readonly": True,
            "primary_zero_drift": True,
            "original_utm_app_present": True,
            "zero_drift": True,
        }
        md = p13b.render_report_md(payload, zero_drift)
        self.assertIn("突发大特效稳帧对比", md)
        self.assertIn("冷启动精简 vs 热待机秒开", md)
        self.assertIn("无桌面 Kiosk 会话脚本", md)
        self.assertIn("零漂移校验", md)


if __name__ == "__main__":
    unittest.main()
