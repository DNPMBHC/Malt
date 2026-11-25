import copy
import ctypes
import hashlib
import json
import tempfile
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch
import benchmark_support as support
import guest_preflight as preflight


def baseline_fixture():
    return {"captured_at_utc": "2026-11-22T01:00:00Z", "boot_time_utc": "2026-11-22T00:00:00Z",
            "secure_boot_enabled": True, "tpm": {"present": True, "enabled": True,
            "activated": True, "owned": True, "specification_version": "2.0, 0, 1.64"},
            "hypervisor_present": True, "vbs_status": 0, "security_services_running": [0], "bcd_security": []}


def actual_fixture():
    result = copy.deepcopy(baseline_fixture())
    result.update({"captured_at_utc": "2026-11-22T02:00:00Z", "owner": "@DNPMBHC",
        "os_product": "Microsoft Windows 11 Enterprise Evaluation", "display_version": "24H2",
        "build": "26100", "architecture": "ARM64", "console_session_id": 2,
        "session_state": 0, "session_flags": 1, "session_flags_offset": 16,
        "wts_info_ex_struct_bytes": 232, "wts_returned_bytes": 232,
        "forbidden_process_count": 0, "forbidden_running_task_count": 0,
        "remaining_driver_service_count": 0, "expected_absent_driver_service_count": 2,
        "bcd_flags": {"testsigning": "absent", "nointegritychecks": "absent"},
        "code_integrity_test_signing": False, "hvci_running": False,
        "hvci_kernel_enforced": False, "baseline_comparison_required": True})
    result.update({field: True for field in preflight.SUCCESS_FIELDS})
    return result


class PreflightAcceptanceTests(unittest.TestCase):
    def test_recovered_baseline_and_unlocked_actual_console_pass(self):
        self.assertIsNone(preflight.validate_preflight(actual_fixture(), baseline_fixture()))

    def test_locked_unknown_disconnected_or_service_console_is_rejected(self):
        for field, value in (("unlocked", False), ("logged_in", False), ("session_flags", 0),
                             ("session_flags", -1), ("session_flags", 2), ("session_state", 4),
                             ("console_session_id", 0), ("console_session_id", 0xFFFFFFFF),
                             ("session_matches_console", False), ("session_flags_offset", 12),
                             ("wts_info_ex_struct_bytes", 224), ("wts_returned_bytes", 231)):
            actual = actual_fixture()
            actual[field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises(RuntimeError):
                    preflight.validate_preflight(actual, baseline_fixture())

    def test_every_required_query_must_succeed_and_bool_cannot_be_counter(self):
        for field in preflight.SUCCESS_FIELDS:
            for value in (False, None, 1):
                actual = actual_fixture()
                actual[field] = value
                with self.subTest(field=field, value=value):
                    with self.assertRaises(RuntimeError):
                        preflight.validate_preflight(actual, baseline_fixture())
        for field in ("console_session_id", "forbidden_process_count", "forbidden_running_task_count"):
            actual = actual_fixture()
            actual[field] = False
            with self.assertRaises(RuntimeError):
                preflight.validate_preflight(actual, baseline_fixture())

    def test_in_flight_jobs_and_incomplete_driver_cleanup_are_rejected(self):
        for field, value in (("forbidden_process_count", 1), ("forbidden_running_task_count", 1),
                             ("remaining_driver_service_count", 1), ("owned_services_absent", False),
                             ("expected_absent_driver_service_count", 0), ("expected_absent_driver_service_count", 1)):
            actual = actual_fixture()
            actual[field] = value
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    preflight.validate_preflight(actual, baseline_fixture())

    def test_secure_boot_bcd_and_live_test_signing_cannot_weaken(self):
        for field, value in (("secure_boot_enabled", False), ("code_integrity_test_signing", True),
                             ("bcd_query_succeeded", False), ("bcd_flags", {}),
                             ("bcd_flags", {"testsigning": "on", "nointegritychecks": "absent"}),
                             ("bcd_flags", {"testsigning": "absent", "nointegritychecks": "unknown"}),
                             ("bcd_security", ["testsigning Yes"])):
            actual = actual_fixture()
            actual[field] = value
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    preflight.validate_preflight(actual, baseline_fixture())
        actual = actual_fixture()
        actual["bcd_flags"] = {"testsigning": "off", "nointegritychecks": "absent"}
        actual["bcd_security"] = ["testsigning No"]
        self.assertIsNone(preflight.validate_preflight(actual, baseline_fixture()))

    def test_tpm_vbs_hypervisor_and_hvci_must_match_restored_baseline(self):
        for field, value in (("hypervisor_present", False), ("vbs_status", 2),
                             ("security_services_running", [2]), ("security_services_running", [False]),
                             ("hvci_running", True), ("hvci_kernel_enforced", True)):
            actual = actual_fixture()
            actual[field] = value
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    preflight.validate_preflight(actual, baseline_fixture())
        for field in baseline_fixture()["tpm"]:
            actual = actual_fixture()
            actual["tpm"][field] = "other" if field == "specification_version" else False
            with self.subTest(tpm_field=field):
                with self.assertRaises(RuntimeError):
                    preflight.validate_preflight(actual, baseline_fixture())

    def test_missing_baseline_security_fields_and_stale_capture_are_rejected(self):
        for field in preflight.BASELINE_FIELDS:
            baseline = baseline_fixture()
            del baseline[field]
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    preflight.validate_preflight(actual_fixture(), baseline)
        actual = actual_fixture()
        actual["captured_at_utc"] = "2026-11-22T00:30:00Z"
        with self.assertRaises(RuntimeError):
            preflight.validate_preflight(actual, baseline_fixture())


class WtsLayoutTests(unittest.TestCase):
    def test_windows_unicode_struct_is_232_bytes_with_flags_at_16(self):
        class Level1(ctypes.Structure):
            _fields_ = [("SessionId", ctypes.c_uint32), ("SessionState", ctypes.c_int32),
                ("SessionFlags", ctypes.c_int32), ("WinStationName", ctypes.c_uint16 * 33),
                ("UserName", ctypes.c_uint16 * 21), ("DomainName", ctypes.c_uint16 * 18),
                ("LogonTime", ctypes.c_int64), ("ConnectTime", ctypes.c_int64),
                ("DisconnectTime", ctypes.c_int64), ("LastInputTime", ctypes.c_int64),
                ("CurrentTime", ctypes.c_int64), ("IncomingBytes", ctypes.c_uint32),
                ("OutgoingBytes", ctypes.c_uint32), ("IncomingFrames", ctypes.c_uint32),
                ("OutgoingFrames", ctypes.c_uint32), ("IncomingCompressedBytes", ctypes.c_uint32),
                ("OutgoingCompressedBytes", ctypes.c_uint32)]
        class InfoEx(ctypes.Structure):
            _fields_ = [("Level", ctypes.c_uint32), ("Data", Level1)]
        self.assertEqual(ctypes.sizeof(Level1), 224)
        self.assertEqual(ctypes.sizeof(InfoEx), 232)
        self.assertEqual(InfoEx.Data.offset + Level1.SessionFlags.offset, 16)
        text = (preflight.SCRIPT_DIR / "guest_preflight.ps1").read_text(encoding="utf-8-sig")
        self.assertIn('Marshal.OffsetOf(typeof(WTSINFOEX_W), "Data")', text)
        self.assertIn('WTSQuerySessionInformationW(IntPtr.Zero, result.ConsoleSessionId, 25', text)
        self.assertIn('information.Data.SessionFlags == 1', text)
        self.assertIn('finally {', text)
        self.assertIn('WTSFreeMemory(buffer)', text)
        for size in (33, 21, 18):
            self.assertIn(f'SizeConst = {size}', text)
        self.assertNotIn('public string UserName;', text.split('public sealed class SessionSnapshot')[1])

    def test_ps_security_queries_are_read_only_and_compiler_temp_is_owned(self):
        text = (preflight.SCRIPT_DIR / "guest_preflight.ps1").read_text(encoding="utf-8-sig")
        for forbidden in ("Stop-Process", "Stop-Service", "Set-ItemProperty", "Remove-Item", "/set ", "/deletevalue "):
            self.assertNotIn(forbidden, text)
        self.assertIn("$scratch = Join-Path $env:SystemDrive 'graphics-lab\\module-c\\tmp'", text)
        self.assertIn('$env:TEMP = $scratch', text)
        self.assertIn('$env:TMP = $scratch', text)
        self.assertIn('$env:TEMP = $originalTemp', text)
        self.assertIn("-ClassName Win32_Tpm", text)
        self.assertIn('IsEnabled_InitialValue', text)
        self.assertIn('IsActivated_InitialValue', text)
        self.assertIn('IsOwned_InitialValue', text)


class PreflightProvenanceTests(unittest.TestCase):
    def setUp(self):
        scratch = preflight.SCRIPT_DIR / "build" / "test-scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        evidence_patch = patch.object(support, "EVIDENCE_DIR", self.root)
        evidence_patch.start()
        self.addCleanup(evidence_patch.stop)

    def tearDown(self):
        self.temp.cleanup()

    def write_baseline(self, **changes):
        path = self.root / "handoff/phase-2/evidence/window-b/b2-recovery-boot-security-result.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        wrapper = {"exit_code": 0, "recovery_pending": False, "stdout": json.dumps(baseline_fixture())}
        wrapper.update(changes)
        path.write_text(json.dumps(wrapper))
        return path

    def test_recovery_success_and_exact_file_sha_are_required(self):
        path = self.write_baseline()
        baseline, digest = preflight.load_baseline(self.root)
        self.assertEqual(baseline, baseline_fixture())
        self.assertEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest())
        for changes in ({"exit_code": 1}, {"exit_code": False}, {"recovery_pending": True}, {"stdout": "invalid"}):
            self.write_baseline(**changes)
            with self.assertRaises(RuntimeError):
                preflight.load_baseline(self.root)

    def test_dynamic_local_driver_names_are_literal_unique_and_bound_to_source(self):
        path = self.root / "Modules/module-b/tests/verify-lifecycle.ps1"
        path.parent.mkdir(parents=True)
        path.write_text("param([string]$ServiceName='service-a',[string]$FailureServiceName='service-b')")
        names, digest = preflight.discover_owned_services(self.root)
        self.assertEqual(names, ["service-a", "service-b"])
        self.assertEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest())
        duplicate = self.root / "Modules/module-x/tests/verify-lifecycle.ps1"
        duplicate.parent.mkdir(parents=True)
        duplicate.write_bytes(path.read_bytes())
        with self.assertRaises(RuntimeError):
            preflight.discover_owned_services(self.root)

    def test_nonliteral_or_duplicate_service_defaults_fail_closed(self):
        path = self.root / "Modules/module-b/tests/verify-lifecycle.ps1"
        path.parent.mkdir(parents=True)
        for source in ("$ServiceName='service-a' + '-suffix'; $FailureServiceName='service-b'",
                       "$ServiceName='service-a'; $FailureServiceName='service-a'",
                       "$ServiceName='service-a'; $ServiceName='service-x'; $FailureServiceName='service-b'"):
            path.write_text(source)
            with self.subTest(case="unsafe source default"):
                with self.assertRaises(RuntimeError):
                    preflight.discover_owned_services(self.root)

    def test_guest_fallback_is_only_read_and_returned_names_stay_in_memory(self):
        guest = type('GuestFixture', (), {})()
        guest.powershell = lambda source: json.dumps({"ServiceName": "service-a", "FailureServiceName": "service-b",
                                                    "source_sha256": "a" * 64})
        names, digest = preflight.discover_owned_services(self.root, guest)
        self.assertEqual(names, ["service-a", "service-b"])
        self.assertEqual(digest, "a" * 64)
        with self.assertRaises(RuntimeError):
            preflight.discover_owned_services(self.root)

    def test_staged_preflight_artifact_is_byte_exact_and_remote_sha_verified(self):
        source = self.root / "guest-preflight.ps1"
        source.write_bytes(b"# neutral preflight source\r\n")
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        expected = hashlib.sha256(source.read_bytes()).hexdigest()
        result = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(guest, "powershell", side_effect=["", json.dumps(expected.upper())]) as control, \
             patch.object(preflight.subprocess, "run", return_value=result) as upload:
            path, digest = preflight.stage_preflight_script(guest, source)
        self.assertEqual(digest, expected)
        self.assertTrue(path.endswith('guest-preflight.ps1'))
        self.assertEqual(upload.call_args.kwargs['input'], source.read_bytes())
        self.assertEqual(upload.call_args.args[0][1:3], ['file', 'push'])
        self.assertIn('Get-FileHash', control.call_args_list[-1].args[0])

    def test_upload_failure_or_remote_digest_mismatch_blocks_execution(self):
        source = self.root / "guest-preflight.ps1"
        source.write_bytes(b"# neutral script")
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        failed = subprocess.CompletedProcess([], 1, b"", b"upload failure")
        with patch.object(guest, 'powershell', return_value='') as control, \
             patch.object(preflight.subprocess, 'run', return_value=failed):
            with self.assertRaises(RuntimeError):
                preflight.stage_preflight_script(guest, source)
            self.assertEqual(control.call_count, 1)
        succeeded = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(guest, 'powershell', side_effect=['', json.dumps('0' * 64)]) as control, \
             patch.object(preflight.subprocess, 'run', return_value=succeeded) as upload, \
             patch.object(support.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, 'SHA-256 differs'):
                preflight.stage_preflight_script(guest, source)
            self.assertEqual(control.call_count, 2)
            upload.assert_called_once()
            sleep.assert_not_called()

    def test_empty_remote_script_hash_retries_only_query_without_reupload(self):
        source = self.root / "guest-preflight.ps1"
        source.write_bytes(b"\xef\xbb\xbf# neutral preflight source\r\n")
        expected = hashlib.sha256(source.read_bytes()).hexdigest()
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        succeeded = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(guest, "powershell", side_effect=["", "", json.dumps(expected)]) as control, \
             patch.object(preflight.subprocess, "run", return_value=succeeded) as upload, \
             patch.object(support.time, "sleep") as sleep:
            path, digest = preflight.stage_preflight_script(guest, source)
        self.assertEqual(digest, expected)
        self.assertTrue(path.endswith("guest-preflight.ps1"))
        upload.assert_called_once()
        self.assertEqual(upload.call_args.kwargs["input"], source.read_bytes())
        self.assertEqual(control.call_count, 3)
        self.assertEqual(control.call_args_list[-2].args, control.call_args_list[-1].args)
        self.assertIn("Get-FileHash -Algorithm SHA256 -LiteralPath", control.call_args_list[-1].args[0])
        self.assertIn("ConvertTo-Json -Compress", control.call_args_list[-1].args[0])
        sleep.assert_called_once_with(0.25)
        rows = [json.loads(line) for line in (self.root / "guest-control-json-retries.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["response_bytes"], 0)
        self.assertEqual(rows[0]["response_sha256"], hashlib.sha256(b"").hexdigest())

    def test_valid_nonstring_remote_script_hash_is_rejected_without_retry(self):
        source = self.root / "guest-preflight.ps1"
        source.write_bytes(b"# neutral preflight source")
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        succeeded = subprocess.CompletedProcess([], 0, b"", b"")
        for value in (None, {}, [], True, 123):
            with self.subTest(json_type=type(value).__name__), \
                 patch.object(guest, "powershell", side_effect=["", json.dumps(value)]) as control, \
                 patch.object(preflight.subprocess, "run", return_value=succeeded) as upload, \
                 patch.object(support.time, "sleep") as sleep:
                with self.assertRaisesRegex(RuntimeError, "SHA-256 differs"):
                    preflight.stage_preflight_script(guest, source)
                self.assertEqual(control.call_count, 2)
                upload.assert_called_once()
                sleep.assert_not_called()

    def test_collected_evidence_never_stores_dynamic_service_names(self):
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        actual = actual_fixture()
        invocation = []
        def fake_control(source):
            invocation.append(source)
            return json.dumps(actual)
        with patch.object(preflight, 'load_baseline', return_value=(baseline_fixture(), 'a' * 64)), \
             patch.object(preflight, 'discover_owned_services', return_value=(["service-a", "service-b"], 'b' * 64)), \
             patch.object(preflight, 'stage_preflight_script', return_value=(preflight.GUEST_DIR + r'\guest-preflight.ps1',
                preflight.sha256_file(preflight.SCRIPT_DIR / 'guest_preflight.ps1'))), \
             patch.object(guest, 'powershell', side_effect=fake_control):
            result = preflight.collect_preflight(guest, self.root)
        self.assertTrue(result['baseline_verified'])
        text = (self.root / 'guest-preflight.json').read_text()
        self.assertNotIn('service-a', text)
        self.assertNotIn('service-b', text)
        self.assertEqual(result['service_baseline_count'], 2)
        self.assertEqual(len(invocation), 1)
        self.assertIn('& ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath ', invocation[0])
        self.assertIn("))) -ExpectedAbsentDriverServices @('service-a','service-b')", invocation[0])
        self.assertNotIn('executionpolicy', invocation[0].casefold())
        self.assertLess(len(invocation[0].encode('utf-16-le')) * 4 / 3, 1000)
        self.assertNotIn('FromBase64String', invocation[0])

    def test_collect_preflight_retries_stale_service_discovery_json_response(self):
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        stale = json.dumps({
            "ServiceName": "service-a",
            "FailureServiceName": "service-b",
            "source_sha256": "b" * 64,
        })
        actual = actual_fixture()
        with patch.object(preflight, 'load_baseline', return_value=(baseline_fixture(), 'a' * 64)), \
             patch.object(preflight, 'discover_owned_services', return_value=(["service-a", "service-b"], 'b' * 64)), \
             patch.object(preflight, 'stage_preflight_script', return_value=(preflight.GUEST_DIR + r'\guest-preflight.ps1',
                preflight.sha256_file(preflight.SCRIPT_DIR / 'guest_preflight.ps1'))), \
             patch.object(guest, 'powershell', side_effect=[stale, json.dumps(actual)]) as control, \
             patch.object(support.time, 'sleep') as sleep:
            result = preflight.collect_preflight(guest, self.root)
        self.assertTrue(result['passed'])
        self.assertEqual(control.call_count, 2)
        sleep.assert_called_once_with(0.25)

    def test_collect_preflight_persistent_stale_json_does_not_misreport_windows_11(self):
        guest = preflight.GuestSession(Path("control-tool"), "vm-a")
        stale = json.dumps({
            "ServiceName": "service-a",
            "FailureServiceName": "service-b",
            "source_sha256": "b" * 64,
        })
        with patch.object(preflight, 'load_baseline', return_value=(baseline_fixture(), 'a' * 64)), \
             patch.object(preflight, 'discover_owned_services', return_value=(["service-a", "service-b"], 'b' * 64)), \
             patch.object(preflight, 'stage_preflight_script', return_value=(preflight.GUEST_DIR + r'\guest-preflight.ps1',
                preflight.sha256_file(preflight.SCRIPT_DIR / 'guest_preflight.ps1'))), \
             patch.object(guest, 'powershell', side_effect=[stale, stale, stale]) as control, \
             patch.object(support.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, "mismatched responses"):
                preflight.collect_preflight(guest, self.root)
        self.assertEqual(control.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_utc_accepts_seven_digit_dotnet_fractional_seconds(self):
        parsed = preflight._utc("2026-11-22T06:08:17.6999380Z")
        self.assertEqual(parsed.year, 2026)
        self.assertEqual(parsed.microsecond, 699938)


if __name__ == '__main__':
    unittest.main()
