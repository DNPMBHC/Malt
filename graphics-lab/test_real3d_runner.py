from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import bench_real3d_runner as runner


class Real3DRunnerTests(unittest.TestCase):
    def test_summarize_real3d_csv_excludes_frame_zero_from_intervals_and_computes_percentiles(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_name:
            csv_path = Path(tmp_name) / "sample.csv"
            csv_path.write_text(
                "frame_index,cpu_frame_ms,cpu_submit_ms,resident_bytes,device_memory_bytes\n"
                "0,99.0,10.0,104857600,209715200\n"
                "1,4.0,3.8,104857600,209715200\n"
                "2,5.0,4.8,104857600,209715200\n"
                "3,6.0,5.8,104857600,209715200\n"
                "4,10.0,9.5,104857600,209715200\n",
                encoding="utf-8",
            )
            summary = runner.summarize_real3d_csv(csv_path)
            self.assertEqual(summary["frame_count"], 5)
            self.assertEqual(summary["interval_sample_count"], 4)
            self.assertAlmostEqual(summary["frame_interval_ms"]["mean"], 6.25)
            self.assertAlmostEqual(summary["frame_interval_ms"]["p50"], 5.5)
            self.assertAlmostEqual(summary["process_resident_mib_mean"], 100.0)
            self.assertAlmostEqual(summary["device_memory_mib_mean"], 200.0)

    def test_five_way_gate_requires_matching_binary_and_complete_rounds(self):
        workload={"draws":2048,"frames":900}
        runs=[]
        for arm in ("wine_dxmt","wine_d3dmetal","wine_dxvk_kosmickrisp",
                    "wine_dxvk_moltenvk","guest_qemu_viogpu3d"):
            for index in range(1,4):
                runs.append({"arm":arm,"round":index,"probe_sha256":"a"*64,
                             "native_exit_code":0,"metadata":{"draws_per_frame":2048,"adapter_is_software":False},
                             "completion":{"measured_frames":900},"csv_summary":{"frame_count":900},
                             "host_cpu":{"sample_count":20}})
        self.assertTrue(runner.validate_baseline_runs(runs,workload,3,"a"*64))
        self.assertFalse(runner.validate_baseline_runs(runs[:-1],workload,3,"a"*64))
        runs[-1]["probe_sha256"]="b"*64
        with self.assertRaisesRegex(RuntimeError,"binding mismatch"):
            runner.validate_baseline_runs(runs,workload,3,"a"*64)
        runs[-1]["probe_sha256"]="a"*64
        runs[-1]["native_exit_code"]=17
        with self.assertRaisesRegex(RuntimeError,"incomplete"):
            runner.validate_baseline_runs(runs,workload,3,"a"*64)

    def test_five_way_gate_rejects_mixed_resolution_and_constant_updates(self):
        workload = {"draws":16384,"frames":900,"width":1280,"height":720,
                    "cb_updates":4096,"passes_per_frame":2,"async_swapchain":True}
        metadata = {"draws_per_frame":16384,"adapter_is_software":False,
                    "width":1280,"height":720,"cb_updates_per_frame":4096,
                    "passes_per_frame":2,"async_swapchain":True}
        run = {"arm":"wine_dxmt","round":1,"probe_sha256":"a"*64,
               "native_exit_code":0,"metadata":metadata,
               "completion":{"measured_frames":900},"csv_summary":{"frame_count":900},
               "host_cpu":{"sample_count":20}}
        self.assertFalse(runner.validate_baseline_runs([run],workload,3,"a"*64))
        for field in ("width","cb_updates_per_frame"):
            original=metadata[field]
            metadata[field]=original+1
            with self.assertRaisesRegex(RuntimeError,"configuration mismatch"):
                runner.validate_baseline_runs([run],workload,3,"a"*64)
            metadata[field]=original

    def test_parse_probe_json_lines_and_aggregate_arms(self) -> None:
        stdout = (
            'real3d_metadata_json={"adapter_description":"Apple M4","selected_feature_level":"11_1","draws_per_frame":2048}\n'
            'real3d_completion_json={"measured_frames":180,"warmup_ms":250.0,"gpu_drain_ms":4.2,'
            '"throughput_including_gpu_drain_fps":120.5}\n'
        )
        meta, comp = runner.parse_probe_json_lines(stdout)
        self.assertEqual(meta["draws_per_frame"], 2048)
        self.assertAlmostEqual(comp["throughput_including_gpu_drain_fps"], 120.5)

        agg = runner.aggregate_arms([
            {
                "arm": "wine_dxmt",
                "metadata": meta,
                "completion": comp,
                "csv_summary": {
                    "frame_interval_ms": {"mean": 8.0, "p50": 7.5, "p95": 11.0, "p99": 12.5},
                    "device_memory_mib_mean": 48.0,
                    "process_resident_mib_mean": 92.0,
                },
                "host_cpu": {"host_cpu_percent_mean": 115.0, "host_cpu_percent_peak": 140.0},
            },
            {
                "arm": "guest_qemu_viogpu3d",
                "metadata": {"adapter_description": "Red Hat VirtIO GPU 3D controller", "selected_feature_level": "11_1"},
                "completion": {"warmup_ms": 800.0, "gpu_drain_ms": 20.0, "throughput_including_gpu_drain_fps": 32.0},
                "csv_summary": {
                    "frame_interval_ms": {"mean": 31.2, "p50": 30.0, "p95": 40.0, "p99": 48.0},
                    "device_memory_mib_mean": 0.0,
                    "process_resident_mib_mean": 120.0,
                },
                "host_cpu": {"host_cpu_percent_mean": 240.0, "host_cpu_percent_peak": 310.0},
            },
        ])
        self.assertIn("wine_dxmt", agg)
        self.assertIn("guest_qemu_viogpu3d", agg)
        self.assertAlmostEqual(agg["wine_dxmt"]["throughput_fps_mean"], 120.5)
        self.assertAlmostEqual(agg["guest_qemu_viogpu3d"]["host_cpu_percent_mean"], 240.0)


if __name__ == "__main__":
    unittest.main()
