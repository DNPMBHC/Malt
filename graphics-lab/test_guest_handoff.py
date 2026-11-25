import copy
import hashlib
import io
import json
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import benchmark_support as support
import run_guest_acceptance as acceptance


NOW = datetime(2026, 11, 22, 12, 0, 0, tzinfo=timezone.utc)


def valid_handoff():
    return {"owner": "@DNPMBHC", "released": True, "next_owner": "C",
            "guest_jobs_clean": True, "captured_at_utc": (NOW - timedelta(minutes=5)).isoformat()}


class HandoffValidationTests(unittest.TestCase):
    def setUp(self):
        time_patch = patch.object(acceptance.time, "time", return_value=NOW.timestamp())
        time_patch.start()
        self.addCleanup(time_patch.stop)

    def test_clean_explicit_release_to_c_is_accepted(self):
        self.assertIsNone(acceptance.validate_handoff(valid_handoff()))

    def test_release_owner_and_clean_jobs_are_required_strictly(self):
        for field in ("released", "next_owner", "guest_jobs_clean"):
            record = valid_handoff()
            del record[field]
            with self.subTest(field=field, case="missing"):
                with self.assertRaises(ValueError):
                    acceptance.validate_handoff(record)
        cases = [("released", value) for value in (False, 1, "true", None)]
        cases += [("guest_jobs_clean", value) for value in (False, 1, "true", None)]
        cases += [("next_owner", value) for value in ("A", "B", "c", None)]
        for field, value in cases:
            record = valid_handoff()
            record[field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises(ValueError):
                    acceptance.validate_handoff(record)

    def test_timezone_aware_timestamp_aliases_are_normalized_to_utc(self):
        expected = NOW - timedelta(minutes=5)
        for field in ("captured_at_utc", "captured_at", "timestamp_utc", "released_at_utc",
                      "recorded_at_utc", "updated_at_utc", "time_utc"):
            record = valid_handoff()
            del record["captured_at_utc"]
            record[field] = expected.isoformat().replace("+00:00", "Z")
            with self.subTest(field=field):
                self.assertEqual(acceptance.handoff_time(record), expected)
                self.assertEqual(acceptance.handoff_time(record).tzinfo, timezone.utc)
        record = valid_handoff()
        record["captured_at_utc"] = expected.astimezone(timezone(timedelta(hours=8))).isoformat()
        self.assertEqual(acceptance.handoff_time(record), expected)

    def test_missing_malformed_and_timezone_naive_timestamps_are_rejected(self):
        record = valid_handoff()
        del record["captured_at_utc"]
        with self.assertRaises(ValueError):
            acceptance.handoff_time(record)
        for value in (None, True, 42, "not-a-time", "2026-11-22", "2026-11-22T11:55:00"):
            record = valid_handoff()
            record["captured_at_utc"] = value
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    acceptance.handoff_time(record)
                with self.assertRaises(ValueError):
                    acceptance.validate_handoff(record)

    def test_future_timestamp_is_rejected(self):
        for seconds in (1, 61, 120):
            record = valid_handoff()
            record["captured_at_utc"] = (NOW + timedelta(seconds=seconds)).isoformat()
            with self.subTest(seconds=seconds):
                with self.assertRaises(ValueError):
                    acceptance.validate_handoff(record)

    def test_c_release_at_or_after_a_release_consumes_handoff(self):
        record = valid_handoff()
        instant = acceptance.handoff_time(record)
        for previous_time in (instant, instant + timedelta(seconds=1)):
            previous = {"owner": "@DNPMBHC", "released": True, "next_owner": "B",
                        "guest_jobs_clean": True, "captured_at_utc": previous_time.isoformat()}
            with self.subTest(previous_time=previous_time.isoformat()):
                with self.assertRaises(ValueError):
                    acceptance.validate_handoff(record, previous)

    def test_older_c_release_and_unreleased_c_record_allow_fresh_a_handoff(self):
        record = valid_handoff()
        instant = acceptance.handoff_time(record)
        older = {"released": True, "captured_at_utc": (instant - timedelta(seconds=1)).isoformat()}
        self.assertIsNone(acceptance.validate_handoff(record, older))
        for previous in ({"released": False}, {"released": False, "captured_at_utc": "not-a-time"}, {}):
            with self.subTest(previous=previous):
                self.assertIsNone(acceptance.validate_handoff(record, previous))


class FrozenAcceptanceInputTests(unittest.TestCase):
    INPUT_NAMES = (
        "run_guest_acceptance.py", "run_guest_m2_benchmark.py", "run_guest_pixel_validation.py",
        "run_m0_fingerprints.py", "guest_preflight.py", "guest_preflight.ps1",
        "benchmark_support.py", "analyze.py", "command_protocol.py", "pixel_compare.py",
        "d3d11_probe.cpp", "metal_host.swift", "restart_metal_host.sh",
        "build_probe.sh", "build_metal_host.sh", "build/d3d11_probe.exe")

    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)
        self.sources = self.directory / "fixture-inputs"
        self.output = self.directory / "fixture-acceptance"
        for name in self.INPUT_NAMES:
            source = self.sources / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(("fixture bytes for " + name + "\n").encode())
        source_patch = patch.object(acceptance, "SCRIPT_DIR", self.sources)
        source_patch.start()
        self.addCleanup(source_patch.stop)

    def tearDown(self):
        self.scratch.cleanup()

    def test_frozen_manifest_digests_are_bound_to_all_archived_input_bytes(self):
        files = acceptance.freeze_inputs(self.output)
        manifest = json.loads((self.output / "acceptance-inputs.json").read_text())
        self.assertEqual(manifest["owner"], "@DNPMBHC")
        self.assertEqual(manifest["files"], files)
        self.assertEqual(set(files), set(self.INPUT_NAMES))
        self.assertEqual(len(files), 16)
        for name, record in files.items():
            with self.subTest(input=name):
                archived = self.output / record["file"]
                self.assertEqual(record["file"], "acceptance-inputs/" + name)
                self.assertEqual(archived.read_bytes(), (self.sources / name).read_bytes())
                self.assertEqual(record["sha256"], hashlib.sha256(archived.read_bytes()).hexdigest())
        self.assertIsNone(acceptance.verify_inputs(files))

    def test_source_or_probe_binary_change_rejects_frozen_acceptance(self):
        files = acceptance.freeze_inputs(self.output)
        for name in ("d3d11_probe.cpp", "build/d3d11_probe.exe"):
            source = self.sources / name
            original = source.read_bytes()
            with self.subTest(input=name):
                source.write_bytes(original + b"changed-input")
                with self.assertRaisesRegex(RuntimeError, "source or probe binary changed"):
                    acceptance.verify_inputs(files)
                archived = self.output / files[name]["file"]
                self.assertEqual(archived.read_bytes(), original)
                self.assertEqual(files[name]["sha256"], hashlib.sha256(original).hexdigest())
                source.write_bytes(original)
                self.assertIsNone(acceptance.verify_inputs(files))


class HandoffCheckOnlyTests(unittest.TestCase):
    def setUp(self):
        directory = support.SCRIPT_DIR / "build" / "test-scratch"
        directory.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=directory)
        self.directory = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def check_only(self, handoff_error=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with ExitStack() as stack:
            stack.enter_context(patch.object(acceptance, "EVIDENCE_DIR", self.directory))
            stack.enter_context(patch.object(sys, "argv", ["acceptance", "--check-only"]))
            # A None module sentinel makes any lazy Guest-preflight import fail.
            stack.enter_context(patch.dict(sys.modules, {"guest_preflight": None}))
            require = stack.enter_context(patch.object(acceptance, "require_handoff", return_value=valid_handoff()))
            require.side_effect = handoff_error
            guest = stack.enter_context(patch.object(acceptance, "GuestSession"))
            control = stack.enter_context(patch.object(acceptance, "discover_utmctl"))
            vm = stack.enter_context(patch.object(acceptance, "discover_started_vm"))
            stage = stack.enter_context(patch.object(acceptance, "run_stage"))
            process = stack.enter_context(patch.object(acceptance.subprocess, "Popen"))
            stop = stack.enter_context(patch.object(acceptance, "stop_metal_host"))
            with redirect_stdout(stdout), redirect_stderr(stderr):
                result = acceptance.main()
            require.assert_called_once()
            for operation in (guest, control, vm, stage, process, stop):
                operation.assert_not_called()
        self.assertNotIn("Traceback", stdout.getvalue() + stderr.getvalue())
        return result, json.loads(stdout.getvalue())

    def test_missing_a_handoff_check_only_records_block_without_guest_import_or_operation(self):
        result, status = self.check_only(ValueError("waiting for module-a Guest handoff file"))
        self.assertEqual(result, 2)
        self.assertFalse(status["ready"])
        blocked = json.loads((self.directory / "guest-acceptance-blocked.json").read_text())
        self.assertIs(blocked["guest_operations"], False)
        self.assertIn("handoff file", blocked["reason"])

    def test_valid_handoff_check_only_still_does_not_import_or_operate_guest(self):
        result, status = self.check_only()
        self.assertEqual(result, 0)
        self.assertIs(status["handoff_valid"], True)
        self.assertIs(status["guest_operations"], False)
        self.assertFalse((self.directory / "guest-acceptance-blocked.json").exists())


if __name__ == "__main__":
    unittest.main()
