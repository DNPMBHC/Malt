#!/usr/bin/env python3
"""Offline schema, whitelist protection, and safety lock unit tests for guest-optimizer.

Owner: @DNPMBHC
"""
from __future__ import annotations

import copy
import importlib.util
import json
import sys
import unittest
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parent.parent
PROFILE_PATH = MODULE_DIR / "profiles" / "anticheat-minimal-win11-arm64.json"
APPLY_SCRIPT_PATH = MODULE_DIR / "scripts" / "apply-optimizer.ps1"
ROLLBACK_SCRIPT_PATH = MODULE_DIR / "scripts" / "rollback-optimizer.ps1"
RUNNER_PATH = MODULE_DIR / "scripts" / "benchmark-optimizer-clone.py"

spec = importlib.util.spec_from_file_location("benchmark_optimizer_clone", RUNNER_PATH)
assert spec is not None and spec.loader is not None
runner = importlib.util.module_from_spec(spec)
sys.modules["benchmark_optimizer_clone"] = runner
spec.loader.exec_module(runner)


class GuestOptimizerProfileTests(unittest.TestCase):
    def load_profile(self) -> dict:
        return json.loads(PROFILE_PATH.read_text(encoding="utf-8"))

    def test_official_profile_passes_schema_and_whitelist_validation(self):
        profile = self.load_profile()
        runner.validate_profile(profile)
        self.assertEqual(profile["owner"], "@DNPMBHC")
        self.assertEqual(profile["profile_id"], "anticheat-minimal-win11-arm64")
        self.assertGreaterEqual(profile.get("profile_revision", 1), 2)
        self.assertGreaterEqual(len(profile["optimization_blacklist"]["services"]), 20)
        self.assertGreaterEqual(len(profile["optimization_blacklist"]["registry_tweaks"]), 12)
        self.assertGreaterEqual(len(profile["optimization_blacklist"]["uwp_packages"]), 15)

    def test_protected_core_and_anticheat_services_cannot_enter_blacklist(self):
        for service in (
            "CryptSvc",
            "cryptsvc",
            "TBS",
            "Winmgmt",
            "EventLog",
            "QEMU-GA",
            "vgc",
            "ACE-BASE",
            "ACE-CORE10405",
            "ACE-CORE20405",
            "AntiCheatExpert",
            "BEService",
        ):
            profile = self.load_profile()
            profile["optimization_blacklist"]["services"].append({
                "name": service,
                "target_start_type": "Disabled",
                "stop_running": True,
                "reason": "malicious test entry",
            })
            with self.subTest(service=service):
                with self.assertRaisesRegex(ValueError, "whitelist violation"):
                    runner.validate_profile(profile)

    def test_protected_uwp_runtimes_cannot_enter_blacklist(self):
        for pkg in ("Microsoft.VCLibs.140.00", "Microsoft.DirectX.Runtime", "Microsoft.Windows.SecHealthUI"):
            profile = self.load_profile()
            profile["optimization_blacklist"]["uwp_packages"].append(pkg)
            with self.subTest(pkg=pkg):
                with self.assertRaisesRegex(ValueError, "whitelist violation"):
                    runner.validate_profile(profile)

    def test_protected_security_tasks_cannot_enter_blacklist(self):
        profile = self.load_profile()
        profile["optimization_blacklist"]["scheduled_tasks"].append({
            "task_path": "\\Microsoft\\Windows\\Windows Defender\\",
            "task_name": "Windows Defender Verification",
            "reason": "bad entry",
        })
        with self.assertRaisesRegex(ValueError, "whitelist violation"):
            runner.validate_profile(profile)

    def test_non_hkcu_or_security_registry_tweaks_are_rejected(self):
        for path in (
            "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\DeviceGuard",
            "HKCU:\\Software\\Policies\\System",
        ):
            profile = self.load_profile()
            profile["optimization_blacklist"]["registry_tweaks"].append({
                "path": path,
                "name": "BadValue",
                "kind": "DWord",
                "value": 0,
            })
            with self.subTest(path=path):
                with self.assertRaisesRegex(ValueError, "whitelist violation"):
                    runner.validate_profile(profile)

    def test_missing_prism_files_or_weakened_compliance_is_rejected(self):
        profile = self.load_profile()
        profile["protected_whitelist"]["prism_files"] = ["System32\\wow64.dll"]
        with self.assertRaisesRegex(ValueError, "Prism"):
            runner.validate_profile(profile)

        profile = self.load_profile()
        profile["compliance"]["forbid_virtualization_hiding"] = False
        with self.assertRaisesRegex(ValueError, "compliance flag"):
            runner.validate_profile(profile)

    def test_duplicate_blacklist_service_or_invalid_start_type_is_rejected(self):
        profile = self.load_profile()
        first = copy.deepcopy(profile["optimization_blacklist"]["services"][0])
        profile["optimization_blacklist"]["services"].append(first)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            runner.validate_profile(profile)

        profile = self.load_profile()
        profile["optimization_blacklist"]["services"][0]["target_start_type"] = "Automatic"
        with self.assertRaisesRegex(ValueError, "invalid target_start_type"):
            runner.validate_profile(profile)

    def test_primary_vm_uuid_is_hard_blocked_from_clone_runner(self):
        primary = "11111111-2222-3333-4444-555555555555"
        clone = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        runner.assert_clone_vm_safe(clone, primary)
        with self.assertRaisesRegex(ValueError, "primary clean vm-a"):
            runner.assert_clone_vm_safe(primary, primary)
        with self.assertRaisesRegex(ValueError, "primary clean vm-a"):
            runner.assert_clone_vm_safe(primary.upper(), primary.lower())

    def test_redaction_strips_volume_names_home_and_uuids(self):
        raw = "/Volumes/SecretDisk/vms/11111111-2222-3333-4444-555555555555/config.plist"
        cleaned = runner.redact_text(raw)
        self.assertNotIn("SecretDisk", cleaned)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", cleaned)
        self.assertIn("/Volumes/<EXTERNAL_VOLUME>", cleaned)
        self.assertIn("vm-clone", cleaned)

    def test_powershell_scripts_contain_whitelist_guard_and_no_forbidden_primitives(self):
        apply_text = APPLY_SCRIPT_PATH.read_text(encoding="utf-8")
        rollback_text = ROLLBACK_SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("$HardProtectedServices", apply_text)
        self.assertIn("Assert-ProfileSafe", apply_text)
        self.assertIn("snapshot-initial.json", apply_text)
        self.assertIn("snapshot-initial.json", rollback_text)
        self.assertIn("rollback_consistent", rollback_text)
        for text in (apply_text, rollback_text):
            for forbidden in ("testsigning on", "nointegritychecks on", "kvm=off", "hv_vendor_id"):
                self.assertNotIn(forbidden, text.lower())


if __name__ == "__main__":
    unittest.main()
