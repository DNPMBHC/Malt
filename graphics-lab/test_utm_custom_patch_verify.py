#!/usr/bin/env python3
"""Unit tests for utm_custom_patch_verify compliance and target guards.

Owner: @DNPMBHC
"""
from __future__ import annotations

import unittest

import utm_custom_patch_verify as ucpv


class UTMCustomPatchVerifyTests(unittest.TestCase):
    def test_official_patches_pass_compliance_and_target_scope(self) -> None:
        report = ucpv.verify_patches_directory()
        self.assertTrue(report["passed"])
        self.assertGreaterEqual(report["patch_count"], 4)
        names = {p["name"] for p in report["patches"]}
        self.assertIn("01-default-dxmt-backend.patch", names)
        self.assertIn("02-cursor-and-fps-capture.patch", names)
        self.assertIn("03-clean-fullscreen-game-shell.patch", names)

    def test_disallowed_target_file_is_rejected(self) -> None:
        bad_patch = """--- a/Services/QemuCPUConfig.swift
+++ b/Services/QemuCPUConfig.swift
@@ -1,1 +1,2 @@
+// harmless comment
"""
        with self.assertRaisesRegex(ValueError, "disallowed target"):
            ucpv.audit_patch_text("bad-target.patch", bad_patch)

    def test_cpuid_smbios_hypervisor_and_anticheat_keywords_are_blocked(self) -> None:
        samples = [
            ("cpuid", "+    let arg = \"-cpu host,hv-vendor-id=none,cpuid=0\""),
            ("smbios", "+    // spoof smbios serial"),
            ("windows_driver", "+    // patch viogpu3d.sys in System32\\"),
            ("anticheat", "+    // bypass ACE-GAME check"),
        ]
        for label, line in samples:
            patch = f"""--- a/Services/UTMQemuVirtualMachine.swift
+++ b/Services/UTMQemuVirtualMachine.swift
@@ -1,1 +1,2 @@
{line}
"""
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, "Compliance violation"):
                    ucpv.audit_patch_text(f"{label}.patch", patch)


if __name__ == "__main__":
    unittest.main()
