import unittest

import run_guest_c3_benchmark as c3


class GuestC3BenchmarkTests(unittest.TestCase):
    def test_summarize_breakdown_computes_paired_stage_attribution(self) -> None:
        runs = [
            {
                "mode": "direct_present",
                "round": 1,
                "summary": {
                    "run": {"initialization_ms": 60.0, "warmup_ms": 200.0},
                    "timing": {
                        "derived_fps_from_mean_interval": 20.0,
                        "cpu_frame_interval_ms": {"mean": 50.0, "p50": 49.0, "p95": 55.0, "p99": 58.0},
                        "cpu_submit_ms": {"mean": 48.0},
                        "gpu_ms": {"mean": 45.0},
                        "host_gpu_ms": {"mean": None},
                        "process_cpu_ms": {"mean": 200.0},
                    },
                    "memory": {"process_resident_bytes": {"mean": 34 * 1024 * 1024}},
                    "transfer": {"network_bytes_total": {"per_frame_mean": 0.0}},
                },
            },
            {
                "mode": "offload_tcp",
                "round": 1,
                "summary": {
                    "run": {"initialization_ms": 58.0, "warmup_ms": 300.0},
                    "timing": {
                        "derived_fps_from_mean_interval": 8.0,
                        "cpu_frame_interval_ms": {"mean": 125.0, "p50": 124.0, "p95": 140.0, "p99": 145.0},
                        "cpu_submit_ms": {"mean": 124.0},
                        "gpu_ms": {"mean": 60.0},
                        "host_gpu_ms": {"mean": 0.2},
                        "process_cpu_ms": {"mean": 280.0},
                    },
                    "memory": {"process_resident_bytes": {"mean": 28 * 1024 * 1024}},
                    "transfer": {"network_bytes_total": {"per_frame_mean": 3_688_681.0}},
                },
            },
        ]
        agg = c3.summarize_breakdown(runs)
        bd = agg["frame_time_breakdown_ms"]
        self.assertAlmostEqual(bd["guest_d3d11_render_ms"], 45.0)
        self.assertAlmostEqual(bd["guest_copyresource_overhead_ms"], 15.0)
        self.assertAlmostEqual(bd["map_read_plus_tcp_and_host_present_ms"], 64.0)
        self.assertAlmostEqual(bd["host_metal_gpu_ms"], 0.2)
        self.assertAlmostEqual(bd["guest_render_plus_copy_share_pct"], 60.0 / 124.0 * 100.0)


if __name__ == "__main__":
    unittest.main()
