from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import wine_kosmickrisp_benchmark as bench


class WineKosmicKrispBenchmarkTests(unittest.TestCase):
    def test_redact_text_removes_home_workspace_tmp_and_external_volume(self) -> None:
        workspace = bench.REPO_ROOT
        home = Path.home().resolve()
        tmp = Path(tempfile.gettempdir()).resolve()
        raw = (
            f"ws={workspace}/a home={home}/secret tmp={tmp}/x "
            "vol=/Volumes/PrivateDrive/cache user=/Users/alice/work"
        )
        cleaned = bench.redact_text(raw)
        self.assertNotIn(str(workspace), cleaned)
        self.assertNotIn(str(home), cleaned)
        self.assertNotIn(str(tmp), cleaned)
        self.assertNotIn("PrivateDrive", cleaned)
        self.assertNotIn("alice", cleaned)
        self.assertIn("<workspace>", cleaned)
        self.assertIn("<home>", cleaned)
        self.assertIn("<tmp>", cleaned)
        self.assertIn("<EXTERNAL_VOLUME>", cleaned)

    def test_build_backend_env_wires_kosmickrisp_and_moltenvk_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_name:
            root = Path(tmp_name)
            components = {
                "dxvk_root": root / "dxvk",
                "mvk_root": root / "mvk",
                "gptk_root": root / "gptk",
                "dxmt_root": root / "dxmt",
                "kk_loader": root / "kk/lib/libvulkan.1.dylib",
                "kk_icd_json": root / "kk/icd.d/kosmickrisp_icd.json",
            }
            prefix = root / "prefix"
            kk_env = bench.build_backend_env(components, "dxvk_kosmickrisp", prefix, root / "w1")
            self.assertEqual(kk_env["WINE_SONAME_LIBVULKAN"], str(components["kk_loader"]))
            self.assertEqual(kk_env["VK_DRIVER_FILES"], str(components["kk_icd_json"]))
            self.assertEqual(kk_env["VK_ICD_FILENAMES"], str(components["kk_icd_json"]))
            self.assertNotIn("DXMT_METALFX_SPATIAL_SWAPCHAIN", kk_env)

            mvk_env = bench.build_backend_env(components, "dxvk_moltenvk", prefix, root / "w2")
            self.assertEqual(
                mvk_env["WINE_SONAME_LIBVULKAN"],
                str(root / "mvk/external/libMoltenVK.dylib"),
            )
            self.assertNotIn("VK_DRIVER_FILES", mvk_env)
            self.assertNotIn("VK_ICD_FILENAMES", mvk_env)

    def test_build_backend_env_controls_dxmt_metalfx_presets_and_explicit_off(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_name:
            root = Path(tmp_name)
            components = {
                "dxvk_root": root / "dxvk",
                "mvk_root": root / "mvk",
                "gptk_root": root / "gptk",
                "dxmt_root": root / "dxmt",
                "kk_loader": root / "kk/lib/libvulkan.1.dylib",
                "kk_icd_json": root / "kk/icd.d/kosmickrisp_icd.json",
            }
            prefix = root / "prefix"

            off_env = bench.build_backend_env(components, "dxmt", prefix, root / "w0", metalfx_preset="off")
            self.assertEqual(off_env["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")
            self.assertNotIn("DXMT_CONFIG", off_env)

            quality_env = bench.build_backend_env(components, "dxmt", prefix, root / "w1", metalfx_preset="quality")
            self.assertEqual(quality_env["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
            self.assertEqual(quality_env["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5")

            perf_env = bench.build_backend_env(components, "dxmt", prefix, root / "w2", metalfx_preset="performance")
            self.assertEqual(perf_env["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
            self.assertEqual(perf_env["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2.0")

            with self.assertRaises(ValueError):
                bench.build_backend_env(components, "dxmt", prefix, root / "w3", metalfx_preset="invalid")

    def test_aggregate_runs_supports_all_four_arms_and_missing_gpu_timing(self) -> None:
        def sample(arm: str, state: str, fps: float, gpu_ms: float | None, vram_mib: float) -> dict:
            return {
                "backend_evidence": {"arm": arm, "backend": arm, "cache_state": state},
                "startup": {
                    "process_start_to_d3d_ready_ms": 3000.0,
                    "probe_internal_initialization_ms": 400.0,
                },
                "summary": {
                    "run": {"warmup_ms": 600.0},
                    "timing": {
                        "derived_fps_from_mean_interval": fps,
                        "cpu_frame_interval_ms": {
                            "mean": 1000.0 / fps,
                            "p50": 2.0,
                            "p95": 7.0,
                            "p99": 9.0,
                        },
                        "gpu_ms": {
                            "mean": gpu_ms,
                            "coverage": 1.0 if gpu_ms is not None else 0.0,
                        },
                    },
                    "memory": {
                        "process_resident_bytes": {"mean": 75 * 1024 * 1024},
                        "device_memory_bytes": {"mean": vram_mib * 1024 * 1024, "sample_count": 900},
                    },
                },
            }

        runs = [
            sample("dxmt", "hot", 360.0, 2.4, 20.0),
            sample("d3dmetal", "hot", 355.0, None, 67.0),
            sample("dxvk_kosmickrisp", "hot", 350.0, 0.6, 350.0),
            sample("dxvk_moltenvk", "hot", 335.0, 2.2, 224.0),
        ]
        agg = bench.aggregate_runs(runs)
        self.assertEqual(sorted(agg.keys()), sorted(bench.FOUR_WAY_BACKENDS))
        self.assertIsNone(agg["d3dmetal"]["hot"]["gpu_ms_mean"])
        self.assertAlmostEqual(agg["dxvk_kosmickrisp"]["hot"]["gpu_ms_mean"], 0.6)
        self.assertAlmostEqual(agg["dxmt"]["hot"]["device_memory_mib_mean"], 20.0)


if __name__ == "__main__":
    unittest.main()
