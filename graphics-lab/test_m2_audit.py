import copy
import io
import sys
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import hashlib
import json
import math
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import benchmark_support as support
import run_guest_m2_benchmark as runner
import run_guest_pixel_validation as pixel_runner


def frame_evidence(mode="command-only", warmup=29, count=3,
                   command_every=30, resource_every=30):
    rows, host_rows = [], []
    for index in range(count):
        sequence = warmup + index
        commands = 16 * (32 if mode == "command-only" else 16)
        command_bytes = commands if sequence == 0 or sequence % command_every == 0 else 0
        resource_bytes = 65536 if sequence == 0 or sequence % resource_every == 0 else 0
        pixels = 0 if mode == "command-only" else 1280 * 720 * 4
        request = 32 + command_bytes + resource_bytes + pixels
        gpu = 0.168734
        row = {"command_bytes": command_bytes, "resource_bytes": resource_bytes,
               "network_bytes_out": request, "network_bytes_in": 56,
               "transferred_bytes": request + 56, "host_gpu_ms": math.floor(gpu * 1000) / 1000,
               "gpu_ms": None if mode == "command-only" else 80.0}
        host = {"frame_index": sequence, "warmup": False, "offload_mode": mode,
                "pixel_bytes": pixels, "transferred_bytes_in": request, "ack_bytes_out": 56,
                "metal_command_complete_ms": gpu, "scene_draw_count": 16,
                "capture_enabled": False, "capture_configured": False,
                "display_sync_enabled": False, "host_binary_sha256": "a" * 64,
                "completion_scope": "gpu-command-complete", "device": "Apple M4"}
        rows.append(row)
        host_rows.append(host)
    return rows, host_rows


def audit(rows, host_rows, mode="command-only", warmup=29,
          command_every=30, resource_every=30):
    return runner.audit_run(rows, host_rows, mode, warmup,
                            command_every, resource_every, 65536, 1280, 720, 16)


class ByteAuditTests(unittest.TestCase):
    def test_command_only_accounts_for_cached_and_refreshed_frames(self):
        rows, host_rows = frame_evidence()
        result = audit(rows, host_rows)
        self.assertEqual(result["cache_frame_count"], 2)
        self.assertEqual(result["refresh_frame_count"], 1)
        self.assertEqual(result["cache_total_bytes"], 88)
        self.assertEqual(result["refresh_total_bytes"], 32 + 512 + 65536 + 56)
        self.assertEqual(result["mean_total_bytes"], (88 * 2 + 66136) / 3)
        self.assertEqual(result["max_total_bytes"], 66136)
        self.assertEqual(result["hello_bytes"], 32)
        self.assertEqual(result["ack_bytes_per_frame"], 56)

    def test_pixel_readback_keeps_rgba_bytes_in_every_frame(self):
        rows, host_rows = frame_evidence("pixel-readback")
        result = audit(rows, host_rows, "pixel-readback")
        self.assertEqual(result["cache_total_bytes"], 1280 * 720 * 4 + 88)
        self.assertEqual(result["refresh_total_bytes"], 1280 * 720 * 4 + 32 + 256 + 65536 + 56)

    def test_zero_warmup_first_frame_forces_both_state_updates(self):
        rows, host_rows = frame_evidence(warmup=0, count=2, command_every=31, resource_every=37)
        result = audit(rows, host_rows, warmup=0, command_every=31, resource_every=37)
        self.assertEqual(result["refresh_frame_count"], 1)
        self.assertEqual(rows[0]["command_bytes"], 512)
        self.assertEqual(rows[0]["resource_bytes"], 65536)
        self.assertEqual(rows[1]["transferred_bytes"], 88)

    def test_command_and_resource_refresh_intervals_are_independent(self):
        rows, host_rows = frame_evidence(warmup=29, count=7, command_every=30, resource_every=31)
        result = audit(rows, host_rows, command_every=30, resource_every=31)
        self.assertEqual(result["refresh_frame_count"], 2)
        self.assertEqual(rows[1]["transferred_bytes"], 32 + 512 + 56)
        self.assertEqual(rows[2]["transferred_bytes"], 32 + 65536 + 56)

    def test_direct_present_has_no_application_transport_bytes(self):
        rows = [{"transferred_bytes": 0, "network_bytes_out": 0, "network_bytes_in": 0}] * 2
        result = audit(rows, [], "direct-present")
        self.assertEqual(result["mean_total_bytes"], 0)
        self.assertEqual(result["hello_bytes"], 0)
        for field in rows[0]:
            bad = copy.deepcopy(rows)
            bad[0][field] = 1
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    audit(bad, [], "direct-present")

    def test_any_guest_or_host_byte_mismatch_is_rejected(self):
        rows, host_rows = frame_evidence()
        for field in ("command_bytes", "resource_bytes", "network_bytes_out", "network_bytes_in", "transferred_bytes"):
            bad = copy.deepcopy(rows)
            bad[1][field] += 1
            with self.subTest(side="guest", field=field):
                with self.assertRaises(ValueError):
                    audit(bad, host_rows)
        for field in ("frame_index", "pixel_bytes", "transferred_bytes_in", "ack_bytes_out"):
            bad_host = copy.deepcopy(host_rows)
            bad_host[1][field] += 1
            with self.subTest(side="host", field=field):
                with self.assertRaises(ValueError):
                    audit(rows, bad_host)

    def test_host_count_mode_capture_and_draw_count_are_required(self):
        rows, host_rows = frame_evidence()
        with self.assertRaises(ValueError):
            audit(rows, host_rows[:-1])
        for field, value in (("offload_mode", "pixel-readback"), ("capture_enabled", True),
                             ("capture_configured", True), ("scene_draw_count", 1)):
            bad = copy.deepcopy(host_rows)
            bad[1][field] = value
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    audit(rows, bad)

    def test_host_display_sync_enabled_is_rejected_for_both_offload_modes(self):
        for mode in ("command-only", "pixel-readback"):
            rows, host_rows = frame_evidence(mode)
            host_rows[1]["display_sync_enabled"] = True
            with self.subTest(mode=mode):
                with self.assertRaisesRegex(ValueError, "display sync"):
                    audit(rows, host_rows, mode)

    def test_missing_host_display_sync_state_is_rejected_for_both_offload_modes(self):
        for mode in ("command-only", "pixel-readback"):
            rows, host_rows = frame_evidence(mode)
            del host_rows[1]["display_sync_enabled"]
            with self.subTest(mode=mode):
                with self.assertRaisesRegex(ValueError, "display sync"):
                    audit(rows, host_rows, mode)

    def test_command_only_does_not_claim_guest_gpu_work(self):
        rows, host_rows = frame_evidence()
        rows[0]["gpu_ms"] = 0.0
        with self.assertRaises(ValueError):
            audit(rows, host_rows)

    def test_host_gpu_timing_requires_positive_finite_real_and_ack_measurements(self):
        rows, host_rows = frame_evidence()
        for value in (None, 0, -1, float("nan"), float("inf"), True, "0.168"):
            bad_rows = copy.deepcopy(rows)
            bad_rows[1]["host_gpu_ms"] = value
            with self.subTest(side="guest ack", value=value):
                with self.assertRaises(ValueError):
                    audit(bad_rows, host_rows)
            bad_host = copy.deepcopy(host_rows)
            bad_host[1]["metal_command_complete_ms"] = value
            with self.subTest(side="actual host", value=value):
                with self.assertRaises(ValueError):
                    audit(rows, bad_host)

    def test_ack_gpu_time_matches_host_duration_after_microsecond_truncation(self):
        rows, host_rows = frame_evidence()
        audit(rows, host_rows)
        rows[1]["host_gpu_ms"] = 0.169
        with self.assertRaises(ValueError):
            audit(rows, host_rows)


class CompletionAuditTests(unittest.TestCase):
    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)
        self.stderr = self.directory / "run.stderr.log"

    def tearDown(self):
        self.scratch.cleanup()

    @staticmethod
    def record():
        return {"measured_frames": 300, "measurement_wall_ms": 2500.0,
                "throughput_including_gpu_drain_fps": 120.0, "completion_mode": "gpu-complete",
                "completion_scope": "gpu-command-complete-not-screen-display"}

    def write_records(self, records):
        self.stderr.write_text("probe_ready_ms=3.000\n" + "".join(
            "probe_completion_json=" + json.dumps(record) + "\n" for record in records))

    def test_valid_completion_binds_throughput_to_wall_time_including_drain(self):
        record = self.record()
        self.write_records([record])
        self.assertEqual(runner.completion_record(self.stderr), record)

    def test_missing_duplicate_and_malformed_completion_records_are_rejected(self):
        for records in ([], [self.record(), self.record()]):
            self.write_records(records)
            with self.subTest(record_count=len(records)):
                with self.assertRaises(RuntimeError):
                    runner.completion_record(self.stderr)
        self.stderr.write_text("probe_completion_json={invalid}\n")
        with self.assertRaises((ValueError, RuntimeError)):
            runner.completion_record(self.stderr)

    def test_completion_frame_count_and_gpu_boundary_are_required(self):
        for field, value in (("measured_frames", 0), ("measured_frames", -1),
                             ("measured_frames", True), ("measured_frames", "300"),
                             ("completion_mode", "submit-only"), ("completion_mode", None)):
            record = self.record()
            record[field] = value
            self.write_records([record])
            with self.subTest(field=field, value=value):
                with self.assertRaises(RuntimeError):
                    runner.completion_record(self.stderr)

    def test_completion_rejects_nonfinite_nonpositive_or_contradictory_timings(self):
        for field in ("measurement_wall_ms", "throughput_including_gpu_drain_fps"):
            for value in (None, 0, -1, float("nan"), float("inf"), True, "120"):
                record = self.record()
                record[field] = value
                self.write_records([record])
                with self.subTest(field=field, value=value):
                    with self.assertRaises(RuntimeError):
                        runner.completion_record(self.stderr)
        record = self.record()
        record["throughput_including_gpu_drain_fps"] = 150
        self.write_records([record])
        with self.assertRaises(RuntimeError):
            runner.completion_record(self.stderr)

    def test_source_snapshot_digests_are_bound_to_copied_bytes(self):
        sources = self.directory / "source-fixture"
        sources.mkdir()
        names = ("d3d11_probe.cpp", "metal_host.swift", "analyze.py", "benchmark_support.py",
                 "run_guest_m2_benchmark.py", "restart_metal_host.sh", "build_metal_host.sh")
        for index, name in enumerate(names):
            (sources / name).write_bytes(f"synthetic-source-{index}".encode())
        (sources / "build").mkdir()
        (sources / "build" / "d3d11_probe.exe").write_bytes(b"synthetic-probe-binary")
        output = self.directory / "snapshot"
        with patch.object(runner, "SCRIPT_DIR", sources):
            inputs = runner.snapshot_inputs(output)
        self.assertEqual(set(inputs), set(names) | {"d3d11_probe.exe"})
        for name, item in inputs.items():
            artifact = output / item["file"]
            self.assertEqual(item["sha256"], hashlib.sha256(artifact.read_bytes()).hexdigest())
        (sources / "d3d11_probe.cpp").write_bytes(b"changed-after-snapshot")
        copied = output / inputs["d3d11_probe.cpp"]["file"]
        self.assertEqual(inputs["d3d11_probe.cpp"]["sha256"], support.sha256_file(copied))
        self.assertNotEqual(support.sha256_file(sources / "d3d11_probe.cpp"), inputs["d3d11_probe.cpp"]["sha256"])


class HostTelemetryTests(unittest.TestCase):
    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def test_host_identity_requires_nonempty_matching_gpu_and_binary_records(self):
        rows = frame_evidence()[1]
        receiver = {"metal_host_binary": "a" * 64}
        self.assertIsNone(runner.validate_host_identity(rows, receiver))
        with self.assertRaises(RuntimeError):
            runner.validate_host_identity([], receiver)

    def test_missing_host_binary_device_or_completion_scope_is_rejected(self):
        rows = frame_evidence()[1]
        receiver = {"metal_host_binary": "a" * 64}
        for field in ("host_binary_sha256", "device", "completion_scope"):
            bad = copy.deepcopy(rows)
            del bad[1][field]
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    runner.validate_host_identity(bad, receiver)

    def test_wrong_host_binary_device_or_completion_scope_is_rejected(self):
        rows = frame_evidence()[1]
        receiver = {"metal_host_binary": "a" * 64}
        for field, value in (("host_binary_sha256", "b" * 64),
                             ("device", "adapter-a"), ("completion_scope", "submit-only")):
            bad = copy.deepcopy(rows)
            bad[1][field] = value
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    runner.validate_host_identity(bad, receiver)

    def test_partial_json_line_is_waited_for_until_newline_completes_it(self):
        telemetry = self.directory / "host.jsonl"
        telemetry.write_text('{"frame_index":0}\n{"frame_index":1')
        def complete_partial_line(_duration):
            with telemetry.open("a") as handle:
                handle.write("}\n")
        with patch.object(runner.time, "sleep", side_effect=complete_partial_line) as wait:
            rows = runner.read_host_rows(telemetry, 2)
        self.assertEqual(rows, [{"frame_index": 0}, {"frame_index": 1}])
        wait.assert_called_once()

    def test_extra_complete_host_row_is_rejected_without_wait(self):
        telemetry = self.directory / "host.jsonl"
        telemetry.write_text('{"frame_index":0}\n{"frame_index":1}\n')
        with patch.object(runner.time, "sleep") as wait:
            with self.assertRaisesRegex(RuntimeError, "extra frames"):
                runner.read_host_rows(telemetry, 1)
        wait.assert_not_called()


class RunnerFailureRegressionTests(unittest.TestCase):
    """Exercise runner control flow while replacing every external operation."""

    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)
        self.digest = "a" * 64

    def tearDown(self):
        self.scratch.cleanup()

    def patched_runner(self, module, output, *, changed_adapter=None):
        stack = ExitStack()
        self.addCleanup(stack.close)
        guest = Mock()
        guest.prepare_probe.return_value = self.digest
        guest.metadata.return_value = {"display_version": "24H2", "architecture": "ARM64",
                                       "build": "26100", "os_product": "Windows 11"}

        def interactive(stem, arguments, destination, artifacts):
            metadata = {"adapter_description": "adapter-a", "vendor_id": 0x1414,
                        "device_id": 0x8C, "adapter_flags": 2, "selected_feature_level": "11_0",
                        "windows_session_id": 2, "requested_driver_type": "hardware",
                        "device_create_hresult": "0x00000000", "adapter_get_desc1_hresult": "0x00000000",
                        "session_api_success": True}
            if "--driver-type" in arguments:
                metadata["requested_driver_type"] = arguments[arguments.index("--driver-type") + 1]
            if changed_adapter and "-pixel-readback-" in stem:
                metadata.update(changed_adapter)
            destination.mkdir(parents=True, exist_ok=True)
            for artifact in artifacts:
                path = destination / artifact
                if artifact.endswith(".json"):
                    path.write_text(json.dumps(metadata))
                else:
                    path.write_bytes(b"synthetic-artifact")
            frames = int(arguments[arguments.index("--frames") + 1])
            completion = {"measured_frames": frames, "measurement_wall_ms": 2000.0,
                          "throughput_including_gpu_drain_fps": frames / 2,
                          "completion_mode": "gpu-complete",
                          "completion_scope": "gpu-command-complete-not-screen-display"}
            (destination / (stem + ".stderr.log")).write_text(
                "probe_completion_json=" + json.dumps(completion) + "\n")
            return {"wall_ms": 2100.0, "launch": "interactive-scheduled-task", "vm": "vm-a"}

        guest.run_interactive.side_effect = interactive
        stack.enter_context(patch.object(module, "GuestSession", return_value=guest))
        stack.enter_context(patch.object(module, "discover_utmctl", return_value=Path("control-tool")))
        stack.enter_context(patch.object(module, "discover_started_vm", return_value="vm-a"))
        stack.enter_context(patch.object(module, "snapshot_inputs", return_value={
            "d3d11_probe.exe": {"file": "inputs/d3d11_probe.exe", "sha256": self.digest}}))
        sources = {key: self.digest for key in ("d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift",
                                               "metal_host_binary", "analyze_py", "benchmark_support_py")}
        stack.enter_context(patch.object(module, "source_digests", return_value=sources))
        stack.enter_context(patch.object(module, "sha256_file", return_value=self.digest))
        stack.enter_context(patch.object(module.shutil, "copy2"))
        environment = stack.enter_context(patch.object(module, "validate_guest_environment", return_value=None))
        stack.enter_context(patch.object(module, "collect_preflight", return_value={
            "console_session_id": 2, "passed": True, "baseline_verified": True}))
        metadata = stack.enter_context(patch.object(module, "validate_probe_metadata", return_value=None))
        start = stack.enter_context(patch.object(module, "start_metal_host", return_value={
            "metal_host_swift": self.digest, "metal_host_binary": self.digest}))
        stop = stack.enter_context(patch.object(module, "stop_metal_host", return_value=None))
        if module is runner:
            stack.enter_context(patch.object(module, "checked", return_value=Mock(stdout="synthetic thermal state")))
            stack.enter_context(patch.object(module.analyze, "load_rows", return_value=[
                {"cpu_frame_ms": 0.0}, {"cpu_frame_ms": 1000.0}]))
            summary = {"timing": {"cpu_frame_interval_ms": dict.fromkeys(("mean", "p50", "p95", "p99"), 1000.0),
                                   "host_gpu_ms": {"mean": 0.168}}}
            stack.enter_context(patch.object(module.analyze, "summarize", return_value=summary))
            def host_rows(path, count):
                mode = "pixel-readback" if "pixel-readback" in path.parent.name else "command-only"
                return frame_evidence(mode, warmup=0, count=count)[1]
            stack.enter_context(patch.object(module, "read_host_rows", side_effect=host_rows))
            stack.enter_context(patch.object(module, "audit_run", return_value={"mean_total_bytes": 88.0}))
        argv = ["runner", "--output-dir", str(output)]
        if module is runner:
            argv += ["--frames", "2", "--warmup", "0", "--rounds", "1"]
        stack.enter_context(patch.object(sys, "argv", argv))
        return guest, environment, metadata, start, stop

    def call_main(self, module):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = module.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_environment_gate_failure_never_launches_probe_or_receiver(self):
        for module in (runner, pixel_runner):
            with self.subTest(runner=module.__name__):
                output = self.directory / (module.__name__ + "-environment")
                guest, environment, metadata, start, stop = self.patched_runner(module, output)
                environment.side_effect = RuntimeError("environment gate rejected synthetic Guest")
                result, stdout, stderr = self.call_main(module)
                self.assertEqual(result, 1)
                environment.assert_called_once_with(guest.metadata.return_value)
                module.collect_preflight.assert_not_called()
                guest.run_interactive.assert_not_called()
                start.assert_not_called()
                stop.assert_not_called()
                failure = json.loads((output / "failure.json").read_text())
                self.assertIn("environment gate", failure["error"])
                self.assertNotIn("Traceback", stdout + stderr)

    def test_probe_uploaded_archived_and_current_binary_digests_must_match(self):
        for changed in ("uploaded", "archived", "current"):
            with self.subTest(changed=changed):
                output = self.directory / ("probe-sha-mismatch-" + changed)
                guest, environment, metadata, start, stop = self.patched_runner(runner, output)
                different = "b" * 64
                if changed == "uploaded":
                    guest.prepare_probe.return_value = different
                elif changed == "archived":
                    runner.snapshot_inputs.return_value["d3d11_probe.exe"]["sha256"] = different
                else:
                    runner.source_digests.return_value["d3d11_probe_exe"] = different
                result, stdout, stderr = self.call_main(runner)
                self.assertEqual(result, 1)
                guest.prepare_probe.assert_called_once()
                guest.run_interactive.assert_not_called()
                start.assert_not_called()
                stop.assert_not_called()
                failure = json.loads((output / "failure.json").read_text())
                self.assertIn("Guest probe binary SHA", failure["error"])
                self.assertEqual(failure["completed_runs"], 0)
                self.assertNotIn("Traceback", stdout + stderr)

    def test_truncated_direct_present_csv_is_rejected_before_statistics(self):
        output = self.directory / "truncated-direct-csv"
        guest, environment, metadata, start, stop = self.patched_runner(runner, output)
        runner.analyze.load_rows.return_value = [{"cpu_frame_ms": 0}]
        result, stdout, stderr = self.call_main(runner)
        self.assertEqual(result, 1)
        self.assertEqual(guest.run_interactive.call_count, 1)
        runner.audit_run.assert_not_called()
        runner.analyze.summarize.assert_not_called()
        runner.read_host_rows.assert_not_called()
        start.assert_not_called()
        stop.assert_not_called()
        failure = json.loads((output / "failure.json").read_text())
        self.assertIn("measured CSV frame count", failure["error"])
        self.assertEqual(failure["completed_runs"], 0)
        self.assertNotIn("Traceback", stdout + stderr)

    def test_probe_session_must_match_its_preflight_console_before_statistics(self):
        output = self.directory / "preflight-session-mismatch"
        guest, environment, metadata, start, stop = self.patched_runner(runner, output)
        runner.collect_preflight.return_value = {
            "console_session_id": 3, "passed": True, "baseline_verified": True}
        result, stdout, stderr = self.call_main(runner)
        self.assertEqual(result, 1)
        self.assertEqual(guest.run_interactive.call_count, 1)
        runner.analyze.load_rows.assert_not_called()
        runner.analyze.summarize.assert_not_called()
        failure = json.loads((output / "failure.json").read_text())
        self.assertIn("interactive Windows session", failure["error"])
        self.assertEqual(failure["completed_runs"], 0)
        self.assertNotIn("Traceback", stdout + stderr)

    def test_replay_probe_session_must_match_its_own_preflight_console(self):
        output = self.directory / "replay-preflight-session-mismatch"
        guest, environment, metadata, start, stop = self.patched_runner(pixel_runner, output)
        pixel_runner.collect_preflight.side_effect = [
            {"console_session_id": session, "passed": True, "baseline_verified": True}
            for session in (2, 2, 3)]
        with patch.object(pixel_runner, "CASES", (("legacy", 0),)), \
                patch.object(pixel_runner, "read_host_rows") as host_rows, \
                patch.object(pixel_runner, "compare_rgba") as compare:
            result, stdout, stderr = self.call_main(pixel_runner)
        self.assertEqual(result, 1)
        self.assertEqual(guest.run_interactive.call_count, 2)
        self.assertEqual(metadata.call_count, 2)
        self.assertEqual([call.args[1].name for call in pixel_runner.collect_preflight.call_args_list],
                         ["preflight-initial", "preflight-reference", "preflight-replay"])
        host_rows.assert_not_called()
        compare.assert_not_called()
        start.assert_called_once()
        stop.assert_called_once()
        failure = json.loads((output / "failure.json").read_text())
        self.assertIn("actual interactive Windows session", failure["error"])
        self.assertEqual(failure["completed_cases"], [])
        self.assertNotIn("Traceback", stdout + stderr)

    def test_primary_and_cleanup_failures_are_saved_separately_without_traceback(self):
        for module in (runner, pixel_runner):
            with self.subTest(runner=module.__name__):
                output = self.directory / (module.__name__ + "-cleanup")
                guest, environment, metadata, start, stop = self.patched_runner(module, output)
                if module is runner:
                    mode_patch = patch.object(module, "MODES", ("command-only",))
                else:
                    mode_patch = patch.object(module, "CASES", (("legacy", 0),))
                primary = "primary receiver failure " + str(support.WORKSPACE_ROOT / "module-x")
                cleanup = "cleanup receiver failure " + str(support.WORKSPACE_ROOT / "module-y")
                start.side_effect = RuntimeError(primary)
                stop.side_effect = RuntimeError(cleanup)
                with mode_patch:
                    result, stdout, stderr = self.call_main(module)
                self.assertEqual(result, 1)
                stop.assert_called_once()
                failure_text = (output / "failure.json").read_text()
                cleanup_text = (output / "cleanup-failure.json").read_text()
                self.assertIn("primary receiver failure", json.loads(failure_text)["error"])
                self.assertNotIn("cleanup receiver failure", json.loads(failure_text)["error"])
                self.assertIn("cleanup receiver failure", json.loads(cleanup_text)["error"])
                all_output = stdout + stderr + failure_text + cleanup_text
                self.assertNotIn(str(support.WORKSPACE_ROOT), all_output)
                self.assertNotIn(str(Path.home()), all_output)
                self.assertNotIn("Traceback", all_output)

    def test_three_modes_with_same_adapter_pass_and_each_runs_metadata_gate(self):
        output = self.directory / "same-adapter"
        guest, environment, metadata, start, stop = self.patched_runner(runner, output)
        result, stdout, stderr = self.call_main(runner)
        self.assertEqual(result, 0)
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertTrue(manifest["complete"])
        fingerprints = [run["fingerprint"] for run in manifest["runs"]]
        self.assertEqual(len(fingerprints), 3)
        self.assertTrue(all(value == fingerprints[0] for value in fingerprints))
        self.assertEqual(guest.run_interactive.call_count, 3)
        self.assertEqual(metadata.call_count, 3)
        expected_modes = [call.args[1]["offload_mode"] for call in metadata.call_args_list]
        self.assertEqual(expected_modes, ["pixel-readback", "pixel-readback", "command-only"])
        self.assertNotIn("Traceback", stdout + stderr)

    def test_cross_mode_adapter_change_is_rejected_even_if_session_is_same(self):
        mutations = ({"vendor_id": 1}, {"device_id": 1}, {"adapter_flags": 0},
                     {"selected_feature_level": "11_1"}, {"adapter_description": "adapter-b"})
        for index, changed_adapter in enumerate(mutations):
            with self.subTest(field=next(iter(changed_adapter))):
                output = self.directory / ("changed-adapter-" + str(index))
                guest, environment, metadata, start, stop = self.patched_runner(
                    runner, output, changed_adapter=changed_adapter)
                result, stdout, stderr = self.call_main(runner)
                self.assertEqual(result, 1)
                failure = json.loads((output / "failure.json").read_text())
                self.assertIn("selected DXGI adapter", failure["error"])
                self.assertEqual(failure["completed_runs"], 1)
                self.assertEqual(guest.run_interactive.call_count, 2)
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertFalse(manifest["complete"])
                self.assertNotIn("Traceback", stdout + stderr)


if __name__ == "__main__":
    unittest.main()
