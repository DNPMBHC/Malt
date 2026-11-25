import json
import tempfile
import unittest
from pathlib import Path

import run_wine_benchmark as bench


class WineBenchmarkHelperTests(unittest.TestCase):
    def test_redact_text_removes_home_workspace_and_tmp_paths(self) -> None:
        workspace = bench.SCRIPT_DIR.parent.resolve()
        home = Path.home().resolve()
        tmp = Path(tempfile.gettempdir()).resolve()
        raw = f"ws={workspace}/a home={home}/secret tmp={tmp}/x"
        cleaned = bench.redact_text(raw)
        self.assertNotIn(str(workspace), cleaned)
        self.assertNotIn(str(home), cleaned)
        self.assertNotIn(str(tmp), cleaned)
        self.assertIn("<workspace>", cleaned)
        self.assertIn("<home>", cleaned)
        self.assertIn("<tmp>", cleaned)

    def test_aggregate_runs_computes_means_and_preserves_missing_gpu_timing(self) -> None:
        sample_runs = [
            {
                "backend_evidence": {"backend": "dxvk", "cache_state": "cold"},
                "startup": {"process_start_to_d3d_ready_ms": 1000.0, "probe_internal_initialization_ms": 500.0},
                "summary": {
                    "run": {"warmup_ms": 200.0},
                    "timing": {
                        "derived_fps_from_mean_interval": 100.0,
                        "cpu_frame_interval_ms": {"mean": 10.0, "p50": 9.5, "p95": 12.0, "p99": 14.0},
                        "gpu_ms": {"mean": 0.5, "coverage": 1.0},
                    },
                    "memory": {
                        "process_resident_bytes": {"mean": 100 * 1024 * 1024},
                        "device_memory_bytes": {"mean": 200 * 1024 * 1024, "sample_count": 900},
                    },
                },
            },
            {
                "backend_evidence": {"backend": "d3dmetal", "cache_state": "hot"},
                "startup": {"process_start_to_d3d_ready_ms": 2000.0, "probe_internal_initialization_ms": 1200.0},
                "summary": {
                    "run": {"warmup_ms": 300.0},
                    "timing": {
                        "derived_fps_from_mean_interval": 120.0,
                        "cpu_frame_interval_ms": {"mean": 8.0, "p50": 8.0, "p95": 9.0, "p99": 10.0},
                        "gpu_ms": {"mean": None, "coverage": 0.0},
                    },
                    "memory": {
                        "process_resident_bytes": {"mean": 80 * 1024 * 1024},
                        "device_memory_bytes": {"mean": 50 * 1024 * 1024, "sample_count": 900},
                    },
                },
            },
        ]
        agg = bench.aggregate_runs(sample_runs)
        self.assertAlmostEqual(agg["dxvk"]["cold"]["frame_interval_p50_ms_mean"], 9.5)
        self.assertAlmostEqual(agg["dxvk"]["cold"]["gpu_ms_mean"], 0.5)
        self.assertIsNone(agg["d3dmetal"]["hot"]["gpu_ms_mean"])
        self.assertAlmostEqual(agg["d3dmetal"]["hot"]["device_memory_mib_mean"], 50.0)

    def test_aggregate_runs_supports_dxmt_third_engine(self) -> None:
        sample_runs = [
            {
                "backend_evidence": {"backend": "dxmt", "cache_state": "hot"},
                "startup": {"process_start_to_d3d_ready_ms": 2500.0, "probe_internal_initialization_ms": 400.0},
                "summary": {
                    "run": {"warmup_ms": 300.0},
                    "timing": {
                        "derived_fps_from_mean_interval": 360.0,
                        "cpu_frame_interval_ms": {"mean": 2.77, "p50": 1.0, "p95": 8.1, "p99": 8.4},
                        "gpu_ms": {"mean": 2.5, "coverage": 1.0},
                    },
                    "memory": {
                        "process_resident_bytes": {"mean": 85 * 1024 * 1024},
                        "device_memory_bytes": {"mean": 12 * 1024 * 1024, "sample_count": 900},
                    },
                },
            },
        ]
        agg = bench.aggregate_runs(sample_runs)
        self.assertAlmostEqual(agg["dxmt"]["hot"]["derived_fps_mean"], 360.0)
        self.assertAlmostEqual(agg["dxmt"]["hot"]["gpu_ms_mean"], 2.5)
        self.assertAlmostEqual(agg["dxmt"]["hot"]["device_memory_mib_mean"], 12.0)


if __name__ == "__main__":
    unittest.main()
