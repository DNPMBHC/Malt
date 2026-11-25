#!/usr/bin/env python3
"""Offline unit tests for Phase 11A VM v2 vs v3 CPU/memory benchmark analyzer.

Owner: @DNPMBHC
"""
from __future__ import annotations

import os
import unittest

import p11_vm_perf_benchmark as bench


class P11VmPerfBenchmarkTests(unittest.TestCase):
    def test_parse_d3d11_probe_csv_computes_fps_p1_p01_low_and_submit(self) -> None:
        header = (
            "transport_mode,frame_index,initialization_ms,warmup_ms,cpu_frame_ms,cpu_submit_ms,"
            "process_cpu_ms,gpu_ms,synthetic_input_to_present_return_ms,transferred_bytes,"
            "command_bytes,resource_bytes,resident_bytes,device_memory_bytes,power_w,"
            "temperature_c,network_bytes_out,network_bytes_in,host_receive_to_present_ms,"
            "host_gpu_ms,host_resident_bytes,host_texture_bytes\n"
        )
        rows = []
        # 99 fast frames at 10.0ms (100 FPS) and 1 spike frame at 50.0ms (20 FPS)
        for i in range(99):
            rows.append(f"direct_present,{i},5.0,10.0,10.0,3.2,2.0,6.5,10.0,0,0,0,0,0,0,0,0,0,0,0,0,0")
        rows.append("direct_present,99,5.0,10.0,50.0,12.0,5.0,8.0,50.0,0,0,0,0,0,0,0,0,0,0,0,0,0")
        res = bench.parse_d3d11_probe_csv(header + "\n".join(rows))

        self.assertEqual(res["frame_count"], 100)
        self.assertEqual(res["fps"]["p50"], 100.0)
        self.assertLess(res["fps"]["p1_low"], 99.0)
        self.assertLess(res["fps"]["p0_1_low"], res["fps"]["p1_low"])
        self.assertGreater(res["cpu_submit_ms"]["mean"], 3.2)
        self.assertAlmostEqual(res["gpu_ms"]["p50"], 6.5, places=2)

    def test_select_best_memory_compression_and_compare_v2_vs_v3(self) -> None:
        v2 = {
            "probe": {"fps": {"mean": 60.0, "p50": 62.0, "p1_low": 40.0, "p0_1_low": 30.0}, "cpu_submit_ms": {"mean": 8.0}},
            "host": {
                "qemu_worker_cpu": {"mean": 210.0},
                "qemu_render_server_cpu": {"mean": 30.0},
                "total_hypervisor_rss_mib": {"max": 3200.0},
            },
            "guest": {"event26_count": 2, "sound_ready": False, "zh_cn_ime_ready": False, "update_services_paused": False},
        }
        v3_preserve = {
            "probe": {"fps": {"mean": 66.0, "p50": 68.0, "p1_low": 50.0, "p0_1_low": 44.0}, "cpu_submit_ms": {"mean": 6.5}},
            "host": {
                "qemu_worker_cpu": {"mean": 185.0},
                "qemu_render_server_cpu": {"mean": 28.0},
                "total_hypervisor_rss_mib": {"max": 3400.0},
            },
            "guest": {"event26_count": 0, "sound_ready": True, "zh_cn_ime_ready": True, "update_services_paused": True},
        }
        v3_disable = {
            "probe": {"fps": {"mean": 68.0, "p50": 69.0, "p1_low": 55.0, "p0_1_low": 48.0}, "cpu_submit_ms": {"mean": 6.0}},
            "host": {
                "qemu_worker_cpu": {"mean": 180.0},
                "qemu_render_server_cpu": {"mean": 28.0},
                "total_hypervisor_rss_mib": {"max": 3500.0},
            },
            "guest": {"event26_count": 0, "sound_ready": True, "zh_cn_ime_ready": True, "update_services_paused": True},
        }
        decision = bench.select_best_memory_compression(v3_preserve, v3_disable)
        self.assertEqual(decision["selected_mode"], "disable")

        cmp_res = bench.compare_v2_vs_v3(v2, v3_disable)
        self.assertGreater(cmp_res["fps_p1_low_delta_pct"], 30.0)
        self.assertLess(cmp_res["cpu_submit_mean_ms_delta_pct"], 0.0)
        self.assertEqual(cmp_res["v3_event26_count"], 0)
        self.assertTrue(cmp_res["v3_sound_ready"])
        self.assertTrue(cmp_res["v3_zh_cn_ime_ready"])

    def test_redaction_strips_user_volume_and_uuid(self) -> None:
        user = os.environ.get("USER") or "user"
        raw = f"/Volumes/MyDisk/vms/11111111-2222-3333-4444-555555555555 /Users/{user}/secret"
        cleaned = bench.redact_p11_text(raw)
        self.assertNotIn("MyDisk", cleaned)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", cleaned)
        self.assertIn("/Volumes/<EXTERNAL_VOLUME>", cleaned)
        if user:
            self.assertNotIn(user, cleaned)


if __name__ == "__main__":
    unittest.main()
