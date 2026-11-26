import copy
import base64
import re
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import benchmark_support as support


def valid_fingerprint():
    return {"adapter_description": "adapter-a", "vendor_id": 0x1414,
            "device_id": 0x8C, "adapter_flags": 2, "selected_feature_level": "11_0",
            "windows_session_id": 2, "requested_driver_type": "hardware",
            "device_create_hresult": "0x00000000", "adapter_get_desc1_hresult": "0x00000000",
            "session_api_success": True}


class ScopedScratchTests(unittest.TestCase):
    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def test_writable_paths_stay_inside_the_two_authorized_trees(self):
        inside = self.directory / "artifact.json"
        self.assertEqual(support.writable_path(inside), inside.resolve())
        evidence = support.EVIDENCE_DIR / "test-artifact.json"
        self.assertEqual(support.writable_path(evidence), evidence.resolve())
        for outside in (support.WORKSPACE_ROOT / "unapproved.json", support.SCRIPT_DIR / ".." / "unapproved.json"):
            with self.subTest(case="outside authorized trees"):
                with self.assertRaises(ValueError):
                    support.writable_path(outside)

    def test_symlink_does_not_bypass_write_boundary(self):
        link = self.directory / "outside-link"
        link.symlink_to(support.WORKSPACE_ROOT, target_is_directory=True)
        with self.assertRaises(ValueError):
            support.writable_path(link / "unapproved.json")

    def test_runtime_environment_scopes_temporary_and_module_cache_files(self):
        environment = support.runtime_environment(self.directory)
        for key in ("TMPDIR", "TMP", "TEMP", "XDG_CACHE_HOME", "CLANG_MODULE_CACHE_PATH",
                    "SWIFT_MODULECACHE_PATH", "PYTHONPYCACHEPREFIX"):
            destination = Path(environment[key]).resolve()
            self.assertTrue(self.directory.resolve() in destination.parents, "runtime output escaped scoped scratch")
        self.assertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")

    def test_file_digest_is_computed_and_changes_when_bytes_change(self):
        binary = self.directory / "probe.exe"
        binary.write_bytes(b"synthetic-pe-content")
        initial = support.sha256_file(binary)
        self.assertEqual(initial, hashlib.sha256(binary.read_bytes()).hexdigest())
        binary.write_bytes(b"synthetic-pe-content-changed")
        self.assertNotEqual(support.sha256_file(binary), initial)

    def test_json_output_redacts_nested_local_identifiers_and_preserves_owner(self):
        artifact = self.directory / "privacy.json"
        source = {"owner": "@DNPMBHC", "nested": [{"path": str(support.WORKSPACE_ROOT / "module-x"),
                  "home": str(Path.home() / "example"), "vm": "11111111-2222-3333-4444-555555555555"}]}
        support.write_json(artifact, source)
        text = artifact.read_text()
        self.assertNotIn(str(support.WORKSPACE_ROOT), text)
        self.assertNotIn(str(Path.home()), text)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", text)
        self.assertEqual(json.loads(text)["owner"], "@DNPMBHC")

    def test_probe_upload_requires_guest_binary_sha_match(self):
        probe = self.directory / "probe.exe"
        probe.write_bytes(b"synthetic-probe")
        expected = support.sha256_file(probe)
        guest = support.GuestSession(Path("control-tool"), "vm-a")
        result = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(guest, "powershell", side_effect=["", json.dumps(expected.upper())]) as query, \
             patch.object(support.subprocess, "run", return_value=result) as upload:
            self.assertEqual(guest.prepare_probe(probe), expected.upper())
            self.assertEqual(upload.call_count, 1)
            self.assertEqual(upload.call_args.args[0][1:3], ["file", "push"])
            self.assertIn("Get-FileHash -Algorithm SHA256 -LiteralPath", query.call_args_list[-1].args[0])
            self.assertIn("ConvertTo-Json -Compress", query.call_args_list[-1].args[0])
        with patch.object(guest, "powershell", side_effect=["", json.dumps("0" * 64)]) as query, \
             patch.object(support.subprocess, "run", return_value=result) as upload, \
             patch.object(support.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                guest.prepare_probe(probe)
            self.assertEqual(query.call_count, 2)
            upload.assert_called_once()
            sleep.assert_not_called()

    def test_probe_hash_empty_response_retries_query_without_reupload(self):
        probe = self.directory / "probe.exe"
        probe.write_bytes(b"synthetic-probe")
        expected = hashlib.sha256(probe.read_bytes()).hexdigest()
        guest = support.GuestSession(Path("control-tool"), "vm-a")
        result = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(guest, "powershell", side_effect=["", "", json.dumps(expected)]) as query, \
             patch.object(support.subprocess, "run", return_value=result) as upload, \
             patch.object(support, "EVIDENCE_DIR", self.directory), \
             patch.object(support.time, "sleep") as sleep:
            self.assertEqual(guest.prepare_probe(probe), expected)
        upload.assert_called_once()
        self.assertEqual(query.call_count, 3)
        self.assertEqual(query.call_args_list[-2].args, query.call_args_list[-1].args)
        sleep.assert_called_once_with(0.25)
        rows = [json.loads(line) for line in (self.directory / "guest-control-json-retries.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["response_bytes"], 0)
        self.assertEqual(rows[0]["response_sha256"], hashlib.sha256(b"").hexdigest())

    def test_probe_hash_valid_nonstring_json_is_rejected_without_retry(self):
        probe = self.directory / "probe.exe"
        probe.write_bytes(b"synthetic-probe")
        guest = support.GuestSession(Path("control-tool"), "vm-a")
        result = subprocess.CompletedProcess([], 0, b"", b"")
        for value in (None, {}, [], True, 123):
            with self.subTest(json_type=type(value).__name__), \
                 patch.object(guest, "powershell", side_effect=["", json.dumps(value)]) as query, \
                 patch.object(support.subprocess, "run", return_value=result) as upload, \
                 patch.object(support.time, "sleep") as sleep:
                with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                    guest.prepare_probe(probe)
                self.assertEqual(query.call_count, 2)
                upload.assert_called_once()
                sleep.assert_not_called()

    def _receiver_fixture(self):
        source = self.directory / "metal_host.swift"
        binary = self.directory / "build" / "metal_host"
        binary.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"synthetic-metal-source")
        binary.write_bytes(b"synthetic-metal-binary")
        return support.sha256_file(source), support.sha256_file(binary)

    def test_restart_evidence_uses_actual_source_and_binary_digests(self):
        source, binary = self._receiver_fixture()
        stdout = f"status=running\nsource_sha256={source}\nbinary_sha256={binary}\nready bind=127.0.0.1 port=39003 device=adapter-a\n"
        result = subprocess.CompletedProcess([], 0, stdout, "")
        with patch.object(support, "SCRIPT_DIR", self.directory), \
             patch.object(support, "checked", return_value=result) as restart:
            output = self.directory / "receiver-evidence"
            digests = support.start_metal_host(output, "command-only", "127.0.0.1", 39003)
            self.assertEqual(digests, {"metal_host_swift": source, "metal_host_binary": binary})
            record = json.loads((output / "receiver-start.json").read_text())
            self.assertTrue(record["restarted_from_source"])
            self.assertEqual(record["status"], "running")
            command = restart.call_args.args[0]
            self.assertEqual(Path(command[0]).name, "restart_metal_host.sh")
            self.assertEqual(command[command.index("--offload-mode") + 1], "command-only")

    def test_restart_rejects_wrong_source_or_binary_digest(self):
        source, binary = self._receiver_fixture()
        for reported_source, reported_binary in (("0" * 64, binary), (source, "0" * 64)):
            result = subprocess.CompletedProcess([], 0,
                f"status=running\nsource_sha256={reported_source}\nbinary_sha256={reported_binary}\n", "")
            with self.subTest(case="digest mismatch"), \
                 patch.object(support, "SCRIPT_DIR", self.directory), \
                 patch.object(support, "checked", return_value=result):
                with self.assertRaises(RuntimeError):
                    support.start_metal_host(self.directory / "receiver-evidence", "command-only", "127.0.0.1", 39003)

    def test_restart_rejects_build_only_and_missing_running_status(self):
        source, binary = self._receiver_fixture()
        for status in ("status=built\n", ""):
            result = subprocess.CompletedProcess([], 0,
                f"{status}source_sha256={source}\nbinary_sha256={binary}\n", "")
            with self.subTest(status=status), \
                 patch.object(support, "SCRIPT_DIR", self.directory), \
                 patch.object(support, "checked", return_value=result):
                with self.assertRaises(RuntimeError):
                    support.start_metal_host(self.directory / "receiver-evidence", "command-only", "127.0.0.1", 39003)


class FingerprintTests(unittest.TestCase):
    def test_software_flag_comes_from_actual_desc_flags(self):
        metadata = valid_fingerprint()
        actual = support.fingerprint(metadata)
        self.assertTrue(actual["adapter_software_flag"])
        metadata["adapter_flags"] = 0
        self.assertFalse(support.fingerprint(metadata)["adapter_software_flag"])
        self.assertEqual(actual["requested_driver_type"], "hardware")

    def test_missing_requested_fingerprint_field_is_rejected(self):
        for field in support.FINGERPRINT_FIELDS:
            metadata = valid_fingerprint()
            del metadata[field]
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    support.fingerprint(metadata)

    def test_ids_and_session_are_uint32_and_cannot_be_string_zero_or_bool(self):
        for field in ("vendor_id", "device_id", "adapter_flags", "windows_session_id"):
            for value in (-1, 1 << 32, True, False, "0", 2.0):
                metadata = valid_fingerprint()
                metadata[field] = value
                with self.subTest(field=field, value=value):
                    with self.assertRaises(RuntimeError):
                        support.fingerprint(metadata)

    def test_service_session_zero_is_preserved_for_diagnostics(self):
        metadata = valid_fingerprint()
        metadata["windows_session_id"] = 0
        self.assertEqual(support.fingerprint(metadata)["windows_session_id"], 0)

    def test_failed_adapter_or_session_api_cannot_produce_valid_fingerprint(self):
        for field, value in (("device_create_hresult", "0x80004005"),
                             ("adapter_get_desc1_hresult", "0x80004005"),
                             ("session_api_success", False), ("session_api_success", 1),
                             ("adapter_description", ""), ("adapter_description", 1)):
            metadata = valid_fingerprint()
            metadata[field] = value
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    support.fingerprint(metadata)


class EnvironmentAndWorkloadTests(unittest.TestCase):
    def valid_environment(self):
        return {"os_product": "Microsoft Windows 11 Enterprise Evaluation", "build": "26100",
                "display_version": "24H2", "architecture": "ARM64", "cpu_architecture_code": 12}

    def test_actual_24h2_arm64_environment_is_accepted(self):
        self.assertIsNone(support.validate_guest_environment(self.valid_environment()))
        metadata = self.valid_environment()
        metadata["build"] = "26100.1234"
        metadata["architecture"] = "ARM 64-bit"
        self.assertIsNone(support.validate_guest_environment(metadata))

    def test_wrong_guest_version_or_native_architecture_is_rejected(self):
        for field, value in (("os_product", "Microsoft Windows 10"), ("display_version", "25H2"),
                             ("build", "26200"), ("build", True), ("architecture", "AMD64"),
                             ("architecture", "64-bit"), ("cpu_architecture_code", 9),
                             ("cpu_architecture_code", True), ("cpu_architecture_code", "12")):
            metadata = self.valid_environment()
            metadata[field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises(RuntimeError):
                    support.validate_guest_environment(metadata)

    def test_environment_requires_all_actual_os_fields(self):
        for field in ("os_product", "display_version", "build", "architecture"):
            metadata = self.valid_environment()
            del metadata[field]
            with self.subTest(field=field):
                with self.assertRaisesRegex(RuntimeError, "missing required OS fields"):
                    support.validate_guest_environment(metadata)
            metadata[field] = None
            with self.subTest(field=field, value=None):
                with self.assertRaisesRegex(RuntimeError, "missing required OS fields"):
                    support.validate_guest_environment(metadata)

    def expected_workload(self):
        return {"requested_driver_type": "hardware", "transport_mode": "offload_tcp",
                "offload_mode": "command-only", "completion_mode": "gpu-complete",
                "width": 1280, "height": 720, "commands": 16, "resource_bytes": 65536,
                "command_every": 30, "resource_every": 30, "resource_pattern": "seeded",
                "seed": 7, "capture_requested": False, "capture_frame": 31}

    def test_workload_checks_allow_extra_diagnostics_but_require_all_expectations(self):
        expected = self.expected_workload()
        metadata = dict(expected, adapter_description="adapter-a")
        self.assertIsNone(support.validate_probe_metadata(metadata, expected))
        for field in expected:
            bad = metadata.copy()
            del bad[field]
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    support.validate_probe_metadata(bad, expected)

    def test_wrong_scene_mode_capture_seed_or_scalar_type_is_rejected(self):
        expected = self.expected_workload()
        for field, value in (("requested_driver_type", "warp"), ("offload_mode", "pixel-readback"),
                             ("completion_mode", "submit-only"), ("capture_requested", True),
                             ("capture_requested", 0), ("capture_frame", 30), ("seed", 8),
                             ("seed", "7"), ("width", 1280.0), ("commands", True),
                             ("resource_pattern", "legacy"), ("resource_every", 1)):
            metadata = expected.copy()
            metadata[field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises(RuntimeError):
                    support.validate_probe_metadata(metadata, expected)

    def test_native_architecture_metadata_uses_processor_code_not_emulated_process(self):
        guest = support.GuestSession(Path("control-tool"), "vm-a")
        with patch.object(guest, "powershell", return_value=json.dumps(self.valid_environment())) as query:
            self.assertEqual(guest.metadata()["architecture"], "ARM64")
        source = query.call_args.args[0]
        self.assertIn("Win32_Processor", source)
        self.assertIn("$cpu.Architecture -eq 12", source)
        self.assertNotIn("PROCESSOR_ARCHITECTURE", source)


class GuestJsonQueryTests(unittest.TestCase):
    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)
        self.guest = support.GuestSession(Path("control-tool"), "vm-a")
        self.source = "@{field='service-a'}|ConvertTo-Json -Compress"
        self.log = self.directory / "guest-control-json-retries.jsonl"
        evidence_patch = patch.object(support, "EVIDENCE_DIR", self.directory)
        evidence_patch.start()
        self.addCleanup(evidence_patch.stop)

    def tearDown(self):
        self.scratch.cleanup()

    def failure_rows(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_digest_only_evidence(self, responses):
        rows = self.failure_rows()
        self.assertEqual(len(rows), len(responses))
        text = self.log.read_text()
        self.assertNotIn(self.source, text)
        self.assertNotIn("service-a", text)
        self.assertNotIn(str(support.WORKSPACE_ROOT), text)
        self.assertNotIn(str(Path.home()), text)
        for attempt, (row, raw) in enumerate(zip(rows, responses), 1):
            self.assertEqual(set(row), {"captured_at_utc", "attempt", "query_sha256",
                                       "response_sha256", "response_bytes", "response_valid_json"})
            self.assertEqual(row["attempt"], attempt)
            self.assertEqual(row["query_sha256"], hashlib.sha256(self.source.encode()).hexdigest())
            self.assertEqual(row["response_sha256"], hashlib.sha256(raw.encode()).hexdigest())
            self.assertEqual(row["response_bytes"], len(raw.encode()))
            self.assertIs(row["response_valid_json"], False)
            self.assertNotIn(raw, text)

    def test_first_valid_json_returns_without_retry_or_failure_evidence(self):
        expected = {"field": "value-a", "passed": True}
        with patch.object(self.guest, "powershell", return_value=json.dumps(expected)) as query, \
             patch.object(support.time, "sleep") as sleep:
            self.assertEqual(support.guest_json_query(self.guest, self.source), expected)
        query.assert_called_once_with(self.source)
        sleep.assert_not_called()
        self.assertFalse(self.log.exists())

    def test_bom_prefixed_json_is_accepted_without_retry(self):
        raw = "\ufeff" + json.dumps({"field": "value-a"})
        with patch.object(self.guest, "powershell", return_value=raw) as query, \
             patch.object(support.time, "sleep") as sleep:
            self.assertEqual(support.guest_json_query(self.guest, self.source), {"field": "value-a"})
        query.assert_called_once_with(self.source)
        sleep.assert_not_called()
        self.assertFalse(self.log.exists())

    def test_two_invalid_json_responses_then_success_retry_with_digest_only_evidence(self):
        invalid = ["invalid-response-service-a", "{无效:'service-a'}"]
        expected = {"passed": True}
        with patch.object(self.guest, "powershell", side_effect=invalid + [json.dumps(expected)]) as query, \
             patch.object(support.time, "sleep") as sleep:
            self.assertEqual(support.guest_json_query(self.guest, self.source), expected)
        self.assertEqual(query.call_count, 3)
        self.assertTrue(all(call.args == (self.source,) for call in query.call_args_list))
        self.assertEqual([call.args for call in sleep.call_args_list], [(0.25,), (0.25,)])
        self.assert_digest_only_evidence(invalid)

    def test_invalid_json_exhausts_after_three_attempts_without_fourth_query(self):
        invalid = ["invalid-service-a-first", "invalid-service-a-second", "invalid-service-a-third"]
        with patch.object(self.guest, "powershell", side_effect=invalid + ['{"passed":true}']) as query, \
             patch.object(support.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "read-only JSON query returned invalid responses") as error:
                support.guest_json_query(self.guest, self.source)
        self.assertEqual(query.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertNotIn("service-a", str(error.exception))
        self.assertTrue(error.exception.__suppress_context__)
        self.assert_digest_only_evidence(invalid)

    def test_control_exceptions_propagate_without_retry_or_failure_response_log(self):
        errors = (RuntimeError("control action failed"), OSError("control unavailable"),
                  subprocess.TimeoutExpired(["control-tool"], 1))
        for original in errors:
            with self.subTest(error_type=type(original).__name__), \
                 patch.object(self.guest, "powershell", side_effect=original) as query, \
                 patch.object(support.time, "sleep") as sleep:
                with self.assertRaises(type(original)) as caught:
                    support.guest_json_query(self.guest, self.source)
                self.assertIs(caught.exception, original)
                query.assert_called_once_with(self.source)
                sleep.assert_not_called()
                self.assertFalse(self.log.exists())

    def test_caller_schema_failure_does_not_retry_valid_json(self):
        with patch.object(self.guest, "powershell", return_value='{"field":"value-a"}') as query, \
             patch.object(support.time, "sleep") as sleep:
            with self.assertRaises(KeyError):
                support.guest_json_query(self.guest, self.source)["required-field"]
        query.assert_called_once_with(self.source)
        sleep.assert_not_called()
        self.assertFalse(self.log.exists())

    def test_validator_retries_stale_mismatched_json_then_succeeds(self):
        stale = json.dumps({"ServiceName": "service-a", "FailureServiceName": "service-b"})
        expected = {"schema_version": 1, "preflight_gates_passed": True}
        with patch.object(self.guest, "powershell", side_effect=[stale, json.dumps(expected)]) as query, \
             patch.object(support.time, "sleep") as sleep:
            result = support.guest_json_query(
                self.guest,
                self.source,
                validator=lambda v: isinstance(v, dict) and v.get("schema_version") == 1,
            )
        self.assertEqual(result, expected)
        self.assertEqual(query.call_count, 2)
        sleep.assert_called_once_with(0.25)
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertIs(rows[0]["response_valid_json"], True)
        self.assertIs(rows[0]["response_schema_matched"], False)
        self.assertNotIn("service-a", self.log.read_text())

    def test_validator_exhausts_after_three_mismatched_responses(self):
        stale = json.dumps({"ServiceName": "service-a", "FailureServiceName": "service-b"})
        with patch.object(self.guest, "powershell", side_effect=[stale, stale, stale]) as query, \
             patch.object(support.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "mismatched responses") as error:
                support.guest_json_query(
                    self.guest,
                    self.source,
                    validator=lambda v: isinstance(v, dict) and v.get("schema_version") == 1,
                )
        self.assertEqual(query.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertNotIn("service-a", str(error.exception))


class InteractiveCleanupTests(unittest.TestCase):
    PROOF_KEYS = ("owned_task_absent", "owned_pid_file_absent", "owned_probe_process_absent")

    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)
        self.guest = support.GuestSession(Path("control-tool"), "vm-a")
        self.token = "1234567890abcdef1234567890abcdef"
        self.proof = dict.fromkeys(self.PROOF_KEYS, True)
        self.proof_json = json.dumps(self.proof)
        evidence_patch = patch.object(support, "EVIDENCE_DIR", self.directory)
        evidence_patch.start()
        self.addCleanup(evidence_patch.stop)

    def tearDown(self):
        self.scratch.cleanup()

    def pull_fixture(self, name, path):
        path.write_text("probe_ready_ms=1.000\n" if name.endswith(".stderr.log") else "artifact-a")

    def assert_one_launch_and_cleanup(self, actions):
        sources = [call.args[0] for call in actions.call_args_list]
        self.assertEqual(sum("Start-ScheduledTask" in source for source in sources), 1)
        self.assertEqual(sum("Stop-ScheduledTask" in source for source in sources), 1)
        self.assertEqual(sum("Unregister-ScheduledTask" in source for source in sources), 1)

    def test_fresh_run_clears_stale_markers_and_binds_cleanup_to_process_instance(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "0", "cleanup-verified", self.proof_json]) as actions, \
             patch.object(self.guest, "pull", side_effect=self.pull_fixture), \
             patch.object(support.secrets, "token_hex", return_value=self.token), \
             patch.object(support, "guest_json_query", wraps=support.guest_json_query) as retry_query:
            result = self.guest.run_interactive("run-a", ["--fingerprint-only"], self.directory,
                                                ["run-a.json", "run-a.rgba"])
        self.assertEqual(result["launch"], "interactive-scheduled-task")
        self.assertEqual(actions.call_count, 4)
        self.assert_one_launch_and_cleanup(actions)
        launch = actions.call_args_list[0].args[0]
        removed = launch[launch.index("Remove-Item -LiteralPath @("):launch.index(") -ErrorAction SilentlyContinue")]
        for name in ("run-a.pid", "run-a.done", "run-a.stdout.log", "run-a.stderr.log", "run-a.json", "run-a.rgba"):
            self.assertIn(name, removed)
        self.assertLess(launch.index("Remove-Item -LiteralPath"), launch.index("Start-ScheduledTask"))
        payload = re.search(r"FromBase64String\('([^']+)'\)", launch).group(1)
        script = base64.b64decode(payload).decode("utf-8")
        cleanup = actions.call_args_list[-2].args[0]
        proof_query = actions.call_args_list[-1].args[0]
        retry_query.assert_called_once_with(self.guest, proof_query)
        self.assertIn(self.token, script)
        self.assertIn(self.token, cleanup)
        self.assertIn("creation_time_utc_ticks", script)
        self.assertIn("creation_time_utc_ticks", cleanup)
        self.assertIn("$processHandle=$live.Handle", cleanup)
        self.assertIn("$live.Kill()", cleanup)
        self.assertNotIn("Stop-Process -Id", cleanup)
        self.assertLess(cleanup.index("PID was reused; refusing cleanup"), cleanup.index("$live.Kill()"))
        self.assertLess(cleanup.index("probe executable identity mismatch"), cleanup.index("$live.Kill()"))
        task_name = "module-c-run-a-" + self.token[:8]
        task_query = "Get-ScheduledTask -ErrorAction Stop|Where-Object {$_.TaskName -eq " + support.ps_quote(task_name) + "}"
        self.assertIn(task_query, cleanup)
        absence_gate = "if($remainingTasks.Count -ne 0){throw 'owned scheduled task remains after cleanup'}"
        self.assertIn(absence_gate, cleanup)
        self.assertLess(cleanup.index("Unregister-ScheduledTask"), cleanup.index(task_query))
        self.assertLess(cleanup.index("Remove-Item -LiteralPath $pidFile"), cleanup.index(task_query))
        self.assertLess(cleanup.index(task_query), cleanup.index(absence_gate))
        self.assertLess(cleanup.index(absence_gate), cleanup.index("'cleanup-verified'"))
        self.assertIn(task_query, proof_query)
        self.assertIn("Get-CimInstance Win32_Process -ErrorAction Stop", proof_query)
        self.assertIn("$_.ExecutablePath -eq " + support.ps_quote(support.GUEST_DIR + r"\d3d11_probe.exe"), proof_query)
        self.assertIn("Test-Path -LiteralPath " + support.ps_quote(support.GUEST_DIR + r"\run-a.pid"), proof_query)
        for key in self.PROOF_KEYS:
            self.assertIn(key, proof_query)
        for mutation in ("Stop-ScheduledTask", "Unregister-ScheduledTask", "Remove-Item", ".Kill(", "Start-Process"):
            self.assertNotIn(mutation, proof_query)
        record = json.loads((self.directory / "guest-cleanup.json").read_text())
        self.assertIs(record["verified"], True)
        self.assertIs(record["owned_task_absent_verified"], True)
        self.assertEqual(record["absence_proof"], self.proof)
        for call in actions.call_args_list:
            encoded = base64.b64encode(call.args[0].encode("utf-16-le")).decode("ascii")
            command = subprocess.list2cmdline(["powershell.exe", "-NoProfile", "-EncodedCommand", encoded])
            self.assertLess(len(command) + 1, 32767, "Windows command line exceeded its limit")

    def test_artifact_escape_is_rejected_before_any_guest_action(self):
        for artifact in ("../unapproved.json", "nested/artifact.json", "..", "artifact\\other.json"):
            with self.subTest(artifact=artifact), patch.object(self.guest, "powershell") as action:
                with self.assertRaises(ValueError):
                    self.guest.run_interactive("run-a", [], self.directory, [artifact])
                action.assert_not_called()

    def test_empty_poll_waits_for_zero_without_relaunch(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "", "0", "cleanup-verified", self.proof_json]) as actions, \
             patch.object(self.guest, "pull", side_effect=self.pull_fixture), \
             patch.object(support.time, "sleep") as sleep:
            result = self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
        self.assertEqual(result["launch"], "interactive-scheduled-task")
        self.assertEqual(actions.call_count, 5)
        self.assertEqual(actions.call_args_list[1].args, actions.call_args_list[2].args)
        sleep.assert_called_once_with(0.5)
        self.assert_one_launch_and_cleanup(actions)
        self.assertIs(json.loads((self.directory / "guest-cleanup.json").read_text())["verified"], True)

    def test_empty_cleanup_response_is_accepted_only_after_actual_absence_proof(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "0", "", self.proof_json]) as actions, \
             patch.object(self.guest, "pull", side_effect=self.pull_fixture):
            self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
        self.assertEqual(actions.call_count, 4)
        self.assert_one_launch_and_cleanup(actions)
        record = json.loads((self.directory / "guest-cleanup.json").read_text())
        self.assertIs(record["verified"], True)
        self.assertEqual(record["absence_proof"], self.proof)

    def test_successful_run_with_unverified_cleanup_fails_closed(self):
        invalid = dict(self.proof, owned_task_absent=False)
        with patch.object(self.guest, "powershell", side_effect=["started", "0", "refused", json.dumps(invalid)]), \
             patch.object(self.guest, "pull", side_effect=self.pull_fixture):
            with self.assertRaisesRegex(RuntimeError, "cleanup could not be verified"):
                self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
        self.assertFalse(json.loads((self.directory / "guest-cleanup.json").read_text())["verified"])

    def test_unknown_or_residual_absence_proof_fails_closed(self):
        invalid_proofs = [None, [], True, {}]
        for key in self.PROOF_KEYS:
            missing = dict(self.proof)
            del missing[key]
            invalid_proofs.append(missing)
            invalid_proofs.extend(dict(self.proof, **{key: value}) for value in (False, None, 0, 1, "true"))
        for index, proof in enumerate(invalid_proofs):
            with self.subTest(proof_case=index), \
                 patch.object(self.guest, "powershell", side_effect=["started", "0", "", json.dumps(proof)]) as actions, \
                 patch.object(self.guest, "pull", side_effect=self.pull_fixture):
                with self.assertRaisesRegex(RuntimeError, "cleanup could not be verified"):
                    self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
                self.assertEqual(actions.call_count, 4)
                self.assert_one_launch_and_cleanup(actions)
                record = json.loads((self.directory / "guest-cleanup.json").read_text())
                self.assertIs(record["verified"], False)
                self.assertIsNot(record.get("owned_task_absent_verified"), True)
                self.assertIn("owned process and task absence", record["error"])

    def test_empty_proof_json_retries_read_only_query_without_repeating_cleanup(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "0", "", "", "", self.proof_json]) as actions, \
             patch.object(self.guest, "pull", side_effect=self.pull_fixture), \
             patch.object(support.time, "sleep") as sleep:
            self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
        self.assertEqual(actions.call_count, 6)
        self.assert_one_launch_and_cleanup(actions)
        proof_calls = actions.call_args_list[-3:]
        self.assertTrue(all(call.args == proof_calls[0].args for call in proof_calls))
        self.assertNotIn("Stop-ScheduledTask", proof_calls[0].args[0])
        self.assertEqual([call.args for call in sleep.call_args_list], [(0.25,), (0.25,)])
        rows = [json.loads(line) for line in (self.directory / "guest-control-json-retries.jsonl").read_text().splitlines()]
        self.assertEqual([row["attempt"] for row in rows], [1, 2])
        self.assertTrue(all(row["response_bytes"] == 0 for row in rows))
        self.assertTrue(all(row["response_sha256"] == hashlib.sha256(b"").hexdigest() for row in rows))
        self.assertIs(json.loads((self.directory / "guest-cleanup.json").read_text())["verified"], True)

    def test_empty_proof_json_exhausts_without_repeating_mutations(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "0", "", "", "", "", self.proof_json]) as actions, \
             patch.object(self.guest, "pull", side_effect=self.pull_fixture), \
             patch.object(support.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "cleanup could not be verified"):
                self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
        self.assertEqual(actions.call_count, 6)
        self.assert_one_launch_and_cleanup(actions)
        proof_calls = actions.call_args_list[-3:]
        self.assertTrue(all(call.args == proof_calls[0].args for call in proof_calls))
        self.assertEqual(sleep.call_count, 2)
        record = json.loads((self.directory / "guest-cleanup.json").read_text())
        self.assertIs(record["verified"], False)
        self.assertIn("read-only JSON query returned invalid responses", record["error"])
        rows = [json.loads(line) for line in (self.directory / "guest-control-json-retries.jsonl").read_text().splitlines()]
        self.assertEqual([row["attempt"] for row in rows], [1, 2, 3])

    def test_task_query_failure_or_remaining_owned_task_rejects_cleanup(self):
        for message in ("task query failed", "owned scheduled task remains after cleanup"):
            with self.subTest(cleanup_error=message), \
                 patch.object(self.guest, "powershell", side_effect=["started", "0", RuntimeError(message)]) as actions, \
                 patch.object(self.guest, "pull", side_effect=self.pull_fixture):
                with self.assertRaisesRegex(RuntimeError, "cleanup could not be verified"):
                    self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
                self.assertEqual(actions.call_count, 3)
                record = json.loads((self.directory / "guest-cleanup.json").read_text())
                self.assertIs(record["verified"], False)
                self.assertIsNot(record.get("owned_task_absent_verified"), True)
                self.assertIn(message, record["error"])

    def test_cleanup_failure_preserves_primary_artifact_error(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "0", RuntimeError("cleanup refusal")]), \
             patch.object(self.guest, "pull", side_effect=RuntimeError("artifact missing")):
            with self.assertRaisesRegex(RuntimeError, "artifact missing"):
                self.guest.run_interactive("run-a", [], self.directory, ["run-a.json"])
        cleanup = json.loads((self.directory / "guest-cleanup.json").read_text())
        self.assertFalse(cleanup["verified"])
        self.assertIn("cleanup refusal", cleanup["error"])

    def test_timeout_still_runs_owned_instance_cleanup(self):
        with patch.object(self.guest, "powershell", side_effect=["started", "", "pending", "cleanup-verified", self.proof_json]) as actions, \
             patch.object(support.time, "perf_counter", side_effect=[0.0, 1.0, 901.0]), \
             patch.object(support.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                self.guest.run_interactive("run-a", [], self.directory, [], timeout=900)
        self.assertEqual(actions.call_count, 5)
        self.assert_one_launch_and_cleanup(actions)
        self.assertIn("probe PID was reused; refusing cleanup", actions.call_args_list[-2].args[0])
        self.assertIn("owned_task_absent", actions.call_args_list[-1].args[0])
        record = json.loads((self.directory / "guest-cleanup.json").read_text())
        self.assertIs(record["verified"], True)
        self.assertIs(record["owned_task_absent_verified"], True)
        self.assertEqual(record["absence_proof"], self.proof)


if __name__ == "__main__":
    unittest.main()
