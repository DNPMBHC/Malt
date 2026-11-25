#!/usr/bin/env python3
"""Offline unit tests for Phase 9A UTM DXMT backend analyzer & stack parser.

Owner: @DNPMBHC
"""
from __future__ import annotations

import json
import os
import unittest

import p9_valorant_analyzer as analyzer


class P9ValorantAnalyzerTests(unittest.TestCase):
    def test_parse_lsof_backend_frameworks(self) -> None:
        dxmt_lsof = "\n".join(
            [
                "QEMURender 123 user txt REG /Applications/UTM.app/Contents/Frameworks/dxmt-native.framework/Versions/A/dxmt-native",
                "QEMURender 123 user txt REG /Applications/UTM.app/Contents/Frameworks/virglrenderer.1.framework/virglrenderer.1",
            ]
        )
        res = analyzer.parse_lsof_backend_frameworks(dxmt_lsof)
        self.assertEqual(res["active_backend"], "dxmt-native")
        self.assertTrue(res["dxmt_native_loaded"])
        self.assertFalse(res["d3dmetal_native_loaded"])
        self.assertTrue(res["virglrenderer_loaded"])

        d3d_lsof = "QEMURender 456 user txt REG /Applications/UTM.app/Contents/Frameworks/d3dmetal-native.framework/d3dmetal-native"
        res2 = analyzer.parse_lsof_backend_frameworks(d3d_lsof)
        self.assertEqual(res2["active_backend"], "d3dmetal-native")
        self.assertTrue(res2["d3dmetal_native_loaded"])

    def test_parse_sample_stack_extracts_wait_and_renderer_frames(self) -> None:
        fake_sample = "\n".join(
            [
                "Call graph:",
                "    2500 Thread_1001   DispatchQueue_1: com.apple.main-thread",
                "    + 2500 npt_context_submit_cmd (in virglrenderer.1) + 120",
                "    +   2500 dxmt::MTLD3D11DeviceContext::Flush (in dxmt-native) + 64",
                "    +     2500 __psynch_cvwait (in libsystem_kernel.dylib) + 8",
                "    2500 Thread_1002",
                "    + 2500 -[MTLCommandBuffer waitUntilCompleted] + 40",
            ]
        )
        parsed = analyzer.parse_sample_stack(fake_sample)
        self.assertEqual(parsed["thread_count_detected"], 2)
        self.assertIn("__psynch_cvwait", parsed["wait_primitives_observed"])
        self.assertIn("waituntilcompleted", parsed["wait_primitives_observed"])
        self.assertTrue(any("dxmt" in f.lower() for f in parsed["renderer_stack_frames"]))

    def test_compare_probe_backends_detects_timestamp_recovery(self) -> None:
        d3d = {"fps": 143.8, "gpu_ms_mean": 0.0, "pixel_compare": {"max_channel_error_lsb": 0}}
        dxmt = {"fps": 165.0, "gpu_ms_mean": 0.42, "pixel_compare": {"max_channel_error_lsb": 0}}
        cmp_res = analyzer.compare_probe_backends(d3d, dxmt)
        self.assertTrue(cmp_res["timestamp_query_recovered_in_dxmt"])
        self.assertTrue(cmp_res["both_zero_lsb"])
        self.assertGreater(cmp_res["dxmt_vs_d3dmetal_fps_ratio"], 1.0)

    def test_build_p9_real_run_report_redacts_and_validates(self) -> None:
        user_name = os.environ.get("USER") or "user"
        report = analyzer.build_p9_real_run_report(
            golden_manifest_sha256="abc123",
            utm_backend_config={"key": "QEMUDirectXDriver", "value": "dxmt", "defaults_restored": True, "path": f"/Users/{user_name}/x"},
            probe_comparison={"both_zero_lsb": True},
            valorant_dxmt_run={"note": "/Volumes/PrivateVol/data token=secret"},
            host_stack_capture=None,
            drift_verification={"golden_zero_drift": True, "primary_zero_drift": True},
            five_dimensions={
                "implementation": "completed",
                "local_gates": "passed",
                "real_guest_run": "executed",
                "vendor_vm_support": "unknown",
                "protected_lobby_and_match": "not_verified",
            },
        )
        raw = json.dumps(report)
        self.assertNotIn("PrivateVol", raw)
        self.assertNotIn("secret", raw)
        self.assertTrue(report["compliance"]["utm_defaults_restored"])
        if user_name:
            self.assertNotIn(user_name, raw)


if __name__ == "__main__":
    unittest.main()
