import unittest

import analyze
from run_guest_m2_benchmark import summarize_mode_comparison


def frame_rows(count, interval_ms, gpu_ms, transfer_bytes):
    rows = []
    for index in range(count):
        row = {field: 0 for field in analyze.FIELDS}
        row.update({"transport_mode": "offload_tcp", "frame_index": index,
                    "cpu_frame_ms": interval_ms if index else 0,
                    "host_gpu_ms": gpu_ms, "transferred_bytes": transfer_bytes})
        rows.append(row)
    return rows


def run_sample(count, wall_ms, transfer_bytes):
    return {"completion": {"measurement_wall_ms": wall_ms,
                           "throughput_including_gpu_drain_fps": count * 1000 / wall_ms},
            "byte_accounting": {"mean_total_bytes": transfer_bytes}}


class BenchmarkComparisonTests(unittest.TestCase):
    def test_formal_three_round_intervals_exclude_each_first_frame(self):
        rows = [frame_rows(300, interval, gpu, transferred)
                for interval, gpu, transferred in ((10, 2, 1000), (20, 4, 2000), (30, 6, 3000))]
        runs = [run_sample(300, wall, transferred)
                for wall, transferred in ((9000, 1000), (12000, 2000), (15000, 3000))]
        result = summarize_mode_comparison(runs, rows, "command-only")
        self.assertEqual(result["rounds"], 3)
        self.assertEqual(result["measured_frames"], 900)
        self.assertEqual(result["frame_interval_ms"]["sample_count"], 897)
        self.assertEqual(result["frame_interval_ms"]["mean"], 20)
        self.assertEqual(result["frame_interval_ms"]["p50"], 20)
        self.assertEqual(result["frame_interval_ms"]["p95"], 30)
        self.assertEqual(result["frame_interval_ms"]["p99"], 30)
        self.assertEqual(result["fps_including_gpu_drain_pooled"], 25)
        self.assertEqual(result["host_gpu_ms_mean"], 4)
        self.assertEqual(result["mean_total_bytes"], 2000)

    def test_first_frames_remain_in_gpu_mean_and_completed_fps(self):
        rows = [frame_rows(2, interval, 1, 100) for interval in (4, 8, 12)]
        for run in rows:
            run[0]["host_gpu_ms"] = 9
        samples = [run_sample(2, 10, 100) for _ in rows]
        result = summarize_mode_comparison(samples, rows, "pixel-readback")
        self.assertEqual(result["frame_interval_ms"]["sample_count"], 3)
        self.assertEqual(result["frame_interval_ms"]["mean"], 8)
        self.assertEqual(result["frame_interval_ms"]["p50"], 8)
        self.assertEqual(result["measured_frames"], 6)
        self.assertEqual(result["fps_including_gpu_drain_pooled"], 200)
        self.assertEqual(result["host_gpu_ms_mean"], 5)
        self.assertEqual(result["mean_total_bytes"], 100)

    def test_direct_present_preserves_absent_host_gpu_telemetry(self):
        rows = [frame_rows(3, 10, None, 0)]
        result = summarize_mode_comparison([run_sample(3, 30, 0)], rows, "direct-present")
        self.assertEqual(result["frame_interval_ms"]["sample_count"], 2)
        self.assertEqual(result["measured_frames"], 3)
        self.assertEqual(result["fps_including_gpu_drain_pooled"], 100)
        self.assertIsNone(result["host_gpu_ms_mean"])
        self.assertEqual(result["mean_total_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
