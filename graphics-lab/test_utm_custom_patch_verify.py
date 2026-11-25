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
        self.assertGreaterEqual(report["patch_count"], 10)
        names = {p["name"] for p in report["patches"]}
        expected = {
            "01-default-dxmt-backend.patch",
            "02-cursor-and-fps-capture.patch",
            "02-cocoaspice-cursor-overlay.patch",
            "03-clean-fullscreen-game-shell.patch",
            "04-pure-relative-mouse-option.patch",
            "05-render-thread-qos-and-dxmt-cache.patch",
            "05-cocoaspice-frame-backpressure.patch",
            "06-high-polling-mouse-coalescing.patch",
            "07-game-shell-key-guard-and-mapping.patch",
            "08-seamless-app-shell-window.patch",
        }
        self.assertTrue(expected.issubset(names), f"Missing patches: {expected - names}")

    def test_pure_relative_mouse_and_qos_patches_targets(self) -> None:
        report = ucpv.verify_patches_directory()
        by_name = {p["name"]: p for p in report["patches"]}
        self.assertEqual(
            set(by_name["04-pure-relative-mouse-option.patch"]["targets"]),
            {
                "Configuration/UTMQemuConfiguration+Arguments.swift",
                "Configuration/UTMQemuConfigurationInput.swift",
            },
        )
        self.assertIn(
            "QEMUHelper/QEMUHelper.m",
            by_name["05-render-thread-qos-and-dxmt-cache.patch"]["targets"],
        )
        self.assertIn(
            "Services/UTMQemuSystem.m",
            by_name["05-render-thread-qos-and-dxmt-cache.patch"]["targets"],
        )
        self.assertEqual(
            set(by_name["05-cocoaspice-frame-backpressure.patch"]["targets"]),
            {
                "Sources/CocoaSpiceRenderer/include/CSMetalRenderer.h",
                "Sources/CocoaSpiceRenderer/CSMetalRenderer.m",
            },
        )
        self.assertEqual(
            by_name["06-high-polling-mouse-coalescing.patch"]["targets"],
            ["Platform/macOS/Display/VMMetalView.swift"],
        )
        self.assertEqual(
            set(by_name["07-game-shell-key-guard-and-mapping.patch"]["targets"]),
            {
                "Platform/macOS/Info.plist",
                "Platform/macOS/Display/VMMetalView.swift",
                "Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift",
            },
        )
        self.assertEqual(
            set(by_name["08-seamless-app-shell-window.patch"]["targets"]),
            {
                "Platform/macOS/AppDelegate.swift",
                "Platform/macOS/Display/VMDisplayWindowController.swift",
                "Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift",
            },
        )

    def test_disallowed_target_file_is_rejected(self) -> None:
        bad_patch = """--- a/Services/QemuCPUConfig.swift
+++ b/Services/QemuCPUConfig.swift
@@ -1,1 +1,2 @@
+// harmless comment
"""
        with self.assertRaisesRegex(ValueError, "disallowed target"):
            ucpv.audit_patch_text("bad-target.patch", bad_patch)

    def test_cpuid_smbios_hypervisor_tpm_and_anticheat_keywords_are_blocked(self) -> None:
        samples = [
            ("cpuid", "+    let arg = \"-cpu host,hv-vendor-id=none,cpuid=0\""),
            ("smbios", "+    // spoof smbios serial"),
            ("tpm_secureboot", "+    // disable-secure-boot testsigning"),
            ("windows_driver", "+    // patch viogpu3d.sys in System32\\"),
            ("anticheat", "+    // bypass ACE-GAME check"),
        ]
        for label, line in samples:
            patch = f"""--- a/Configuration/UTMQemuConfiguration+Arguments.swift
+++ b/Configuration/UTMQemuConfiguration+Arguments.swift
@@ -1,1 +1,2 @@
{line}
"""
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, "Compliance violation"):
                    ucpv.audit_patch_text(f"{label}.patch", patch)


if __name__ == "__main__":
    unittest.main()
