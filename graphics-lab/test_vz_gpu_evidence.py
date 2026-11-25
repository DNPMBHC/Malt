"""Evidence integrity and real native-host regression tests. Owner: @DNPMBHC."""
from __future__ import annotations
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from vz_gpu_bench_support import compare_pair, redact, sha256_file, validate_sample


def sample() -> dict:
    return {"width": 1280, "height": 720, "drawCalls": 2048, "frames": 3, "warmupFrames": 1,
            "meanMs": 2.0, "p50Ms": 2.0, "p95Ms": 3.0, "p99Ms": 3.0, "fps": 500.0,
            "wallMs": 6.0, "cpuUserMs": 2.0, "cpuSysMs": 1.0, "hostCpuPercent": 50.0,
            "metalAPI": "Metal4", "gpuCompletionBoundary": "MTLSharedEvent", "gpuCompletedFrames": 4,
            "submittedCommands": 8192, "frameLatenciesMs": [1.0, 2.0, 3.0],
            "imageSHA256": "ab" * 32, "ringAliasesMetalMemory": True, "zeroCopySurfaceActive": True}


class EvidenceIntegrityTests(unittest.TestCase):
    def worker(self) -> dict:
        return {"cpuUserMs": 2.0, "cpuSysMs": 1.0, "measurementFrames": 3, "framesRendered": 4, "imageSHA256": "ab" * 32}

    def test_valid_pair_sums_both_process_cpu_without_claiming_qemu(self):
        result = compare_pair(sample(), sample(), self.worker())
        self.assertEqual(result["ipc_cpu_percent_one_core_total"], 100.0)
        self.assertFalse(result["real_qemu_comparison"])
        self.assertEqual(result["native_cpu_pixel_payload_bytes_per_frame"], 0)

    def test_workload_mismatch_rejected(self):
        other = sample()
        other["width"] = 2560
        with self.assertRaisesRegex(ValueError, "incomparable"):
            compare_pair(sample(), other, self.worker())

    def test_full_frame_digest_mismatch_rejected(self):
        other = sample()
        other["imageSHA256"] = "cd" * 32
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            compare_pair(sample(), other, self.worker())

    def test_renderer_worker_digest_mismatch_rejected(self):
        worker = self.worker()
        worker["imageSHA256"] = "cd" * 32
        with self.assertRaises(ValueError):
            compare_pair(sample(), sample(), worker)

    def test_missing_gpu_completion_and_partial_series_rejected(self):
        for key, value in (("gpuCompletedFrames", 3), ("submittedCommands", 4), ("frameLatenciesMs", [1.0])):
            row = sample()
            row[key] = value
            with self.assertRaises(ValueError):
                validate_sample(row)

    def test_nonfinite_timing_and_wrong_api_rejected(self):
        for key, value in (("p99Ms", float("nan")), ("wallMs", float("inf")), ("metalAPI", "Metal")):
            row = sample()
            row[key] = value
            with self.assertRaises(ValueError):
                validate_sample(row)

    def test_worker_warmup_scope_and_unproven_alias_rejected(self):
        worker = self.worker()
        worker["measurementFrames"] = 4
        with self.assertRaises(ValueError):
            compare_pair(sample(), sample(), worker)
        row = sample()
        row["ringAliasesMetalMemory"] = False
        with self.assertRaises(ValueError):
            compare_pair(row, sample(), self.worker())

    def test_negative_performance_difference_is_preserved(self):
        native = sample()
        native.update(meanMs=3.0, frameLatenciesMs=[3.0, 3.0, 3.0], wallMs=9.0,
                      fps=1000 / 3, hostCpuPercent=100 / 3)
        result = compare_pair(native, sample(), self.worker())
        self.assertEqual(result["mean_latency_saved_ms"], -1.0)

    def test_negative_worker_component_cannot_be_hidden_by_positive_sum(self):
        for value in (-1.0, True, float("nan")):
            worker = self.worker()
            worker.update(cpuUserMs=value, cpuSysMs=100.0)
            with self.assertRaises(ValueError):
                compare_pair(sample(), sample(), worker)

    def test_worker_total_frame_count_and_invalid_warmup_rejected(self):
        worker = self.worker()
        worker["framesRendered"] = 3
        with self.assertRaises(ValueError):
            compare_pair(sample(), sample(), worker)
        for value in (-1, True, 1.5):
            row = sample()
            row["warmupFrames"] = value
            with self.assertRaises(ValueError):
                validate_sample(row)

    def test_private_paths_redacted(self):
        output = redact("/Users/demo-user/my-project/file /Volumes/demo-volume/file /tmp/demo-file")
        self.assertNotIn("demo-user", output)
        self.assertNotIn("demo-volume", output)
        self.assertNotIn("/tmp/", output)


@unittest.skipUnless(sys.platform == "darwin", "Native Virtualization/Metal requires macOS")
class NativeHostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import vz_gpu_bench_runner as runner
        cls.runner = runner
        if not runner.BINARY.exists():
            runner.build()
        else:
            binding = json.loads((runner.EVIDENCE / "build-binding.json").read_text())
            source_names = {path.name for path in runner.MODULE.iterdir() if path.suffix in (".swift", ".c", ".h")}
            sources_match = source_names == set(binding["sources"]) and all(sha256_file(runner.MODULE / name) == digest
                                for name, digest in binding["sources"].items())
            if not sources_match or sha256_file(runner.BINARY) != binding["binary_sha256"]:
                runner.build()

    def test_real_protocol_and_unimplemented_commands_fail_closed(self):
        report = self.runner.run_mode("protocol-self-test")
        self.assertTrue(all(report.values()))

    def test_real_configuration_modern_gpu_and_single_region(self):
        report = self.runner.run_mode("validate")
        self.assertGreater(report["maxValidatedSharedMemoryMiB"], 0)
        self.assertEqual(report["pciModernSpec"]["virtioDeviceID"], 16)
        self.assertEqual(report["pciModernSpec"]["virtioQueues"], 2)
        self.assertEqual(report["maxAllowedSharedMemoryRegions"], 1)
        self.assertFalse(report["twoRegionsCase"]["validated"])
        self.assertTrue(report["entitlementProbe"]["hardenedRuntimeFlag"])

    def test_real_runtime_mapping_uses_isolated_efi_and_same_metal_buffer(self):
        report = self.runner.run_mode("runtime-probe")
        self.assertTrue(report["configurationValidated"])
        self.assertTrue(report["deviceCreated"])
        self.assertTrue(report["guestStarted"])
        self.assertTrue(report["guestStopped"])
        self.assertTrue(all(row["succeeded"] for row in report["mappings"]))
        self.assertTrue(any(row["name"] == "VZ_and_Metal4_same_command_ring" for row in report["mappings"]))
        self.assertIn("not_Windows", report["guestScope"])

    def test_real_live_capacity_runs_complete_efi_lifecycle(self):
        report = self.runner.run_mode("live-capacity-case", ["--region-bytes", str(64 * 1024 * 1024)])
        self.assertTrue(report["configurationValidated"])
        self.assertTrue(report["deviceCreated"])
        self.assertTrue(report["guestStarted"])
        self.assertTrue(report["guestStopped"])
        self.assertTrue(report["mappedAndUnmapped"])
        self.assertEqual(report["mapping"]["bytes"], 64 * 1024 * 1024)
        self.assertFalse(report["physicalPagesFullyTouched"])

    def test_failed_live_aperture_preserves_error_without_invalid_stop(self):
        report = self.runner.run_mode("live-capacity-case", ["--region-bytes", str(1 << 46)])
        self.assertFalse(report["mappedAndUnmapped"])
        self.assertEqual(report["errorDomain"], "VZErrorDomain")
        self.assertEqual(report["errorCode"], 10)
        self.assertNotIn("stopErrorDomain", report)
        if report["stopSkippedBecauseUnavailable"]:
            self.assertFalse(report["stopRequested"])
            self.assertFalse(report["guestStopped"])

    def test_live_capacity_rejects_unbounded_request_before_vm_creation(self):
        report = self.runner.run_mode("live-capacity-case", ["--region-bytes", str((1 << 64) - 1)])
        self.assertFalse(report["guestStarted"])
        self.assertFalse(report["deviceCreated"])
        self.assertEqual(report["errorDomain"], "LiveCapacityInputBounds")

    def test_real_secure_boot_default_signatures_persist(self):
        report = self.runner.run_mode("secure-boot-probe")
        self.assertTrue(report["enabled"])
        self.assertTrue(report["persistedEnabled"])
        self.assertGreater(report["allowedSignatures"], 0)
        self.assertFalse(report["windowsBootTested"])

    def test_real_metal4_and_ipc_consume_identical_payload(self):
        extra = ["--frames", "3", "--warmup", "1", "--draws", "2048"]
        native = self.runner.run_mode("bench-zerocopy", extra)
        with tempfile.TemporaryDirectory(prefix="demo-app-ipc-test-") as temporary:
            ipc, worker = self.runner.ipc_run(extra, Path(temporary) / "frame.sock")
            control, control_worker = self.runner.ipc_run(extra, Path(temporary) / "frame.sock", copy_frames=False)
        compare_pair(native, ipc, worker)
        comparison = compare_pair(native, control, control_worker)
        self.assertEqual(comparison["ipc_pixel_payload_bytes_per_frame"], 0)
        self.assertEqual(comparison["pixel_validation_scope"], "renderer_worker")
        self.assertEqual(native["metalAPI"], "Metal4")

    def test_draw_payload_changes_the_completed_gpu_image(self):
        first = self.runner.run_mode("bench-zerocopy", ["--frames", "2", "--warmup", "1"])
        second = self.runner.run_mode("bench-zerocopy", ["--frames", "3", "--warmup", "1"])
        self.assertNotEqual(first["imageSHA256"], second["imageSHA256"])

    def test_public_producer_library_entry_is_callable_from_another_target(self):
        from vz_gpu_bench_library import build_and_smoke
        report = build_and_smoke()
        self.assertTrue(all(report["checks"].values()), report)
        self.assertFalse(report["supports_real_guest_scanout"])
        self.assertFalse(report["supports_virtual_hid_sink"])

    def test_producer_retains_surfaces_until_gpu_release_and_applies_backpressure(self):
        checks = self.runner.run_mode("producer-probe")
        self.assertGreaterEqual(len(checks), 14)
        self.assertTrue(all(checks.values()), checks)

    def test_real_cli_rejects_invalid_sizes_and_missing_values(self):
        cases = (("--width", "-1"), ("--draws", "0"), ("--frames", "0"), ("--width",),
                 ("--region-bytes", "-1"), ("--region-bytes", str(1 << 64)))
        for arguments in cases:
            result = self.runner.capture([str(self.runner.BINARY), *arguments])
            self.assertNotEqual(result.returncode, 0)

    def test_efi_rejects_small_shared_aperture_before_vm_start(self):
        result = self.runner.capture([str(self.runner.BINARY), "--mode", "efi-guest-probe",
                                      "--fixture-disk", "unused-fixture", "--region-bytes", "1"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("EFIGuestBounds:2", result.stderr)

    def test_real_efi_pci_queues_and_guest_written_metal_ring(self):
        from vz_gpu_bench_efi import build_guest, run_case
        with tempfile.TemporaryDirectory(prefix="demo-app-efi-integration-") as temporary:
            directory = Path(temporary)
            executable, binding = build_guest(directory)
            report = run_case(directory, executable, 1280, 720)
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["native"]["drawCalls"], 2048)
        self.assertEqual(report["guest"]["sharedMemoryRegionID"], 1)
        self.assertEqual(report["guest"]["featuresOkDeviceStatus"], 11)
        self.assertEqual(report["guest"]["finalDeviceStatus"], 15)
        self.assertIn("not_Windows", report["native"]["scope"])
        self.assertEqual(len(binding["guest_executable_sha256"]), 64)

    def test_real_efi_surface_lease_is_consumed_by_independent_target(self):
        from vz_gpu_bench_efi import build_guest, run_external_consumer
        with tempfile.TemporaryDirectory(prefix="demo-app-efi-consumer-test-") as temporary:
            directory = Path(temporary)
            executable, _ = build_guest(directory)
            report = run_external_consumer(directory, executable)
        self.assertTrue(report["passed"], report)
        self.assertGreaterEqual(len(report["checks"]), 10)
        self.assertTrue(all(report["checks"].values()), report)

    def test_real_efi_to_downstream_graphics_keeps_exact_pixels_and_lease(self):
        from vz_gpu_bench_c_efi import run
        report = run()
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["frames_consumed"], 4)
        self.assertTrue(report["gpu_all_pixels_equal"])
        self.assertFalse(report["real_windows_scanout_verified"])
        self.assertFalse(report["production_game_backend_enabled"])
        self.assertTrue(all(all(row["checks"].values()) for row in report["runs"]))

    def test_ffi_never_claims_unmeasured_venus_or_iosurface(self):
        report = self.runner.run_mode("virgl-probe")
        self.assertFalse(report["venusNeptuneSubmissionTested"])
        self.assertFalse(report["iosurfaceExportTested"])
        runtime = report.get("runtime")
        if runtime:
            self.assertFalse(runtime["renderServerFlagEnabled"])
