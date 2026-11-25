#!/usr/bin/env python3
"""Offline unit tests for Phase 7A target-cn blackscreen & Venus log analyzer.

Owner: @DNPMBHC
"""
from __future__ import annotations

import json
import os
import unittest

import p7_valorant_analyzer as analyzer


class P7ValorantAnalyzerTests(unittest.TestCase):
    def test_parse_ue4_log_detects_zero_vram_neptune_and_swapchain_errors(self) -> None:
        sample = "\n".join(
            [
                "[2026.11.24-10.00.01:000][  0]LogD3D11RHI: Found D3D11 adapter 0: Red Hat VirtIO GPU 3D controller",
                "[2026.11.24-10.00.01:001][  0]LogD3D11RHI: Dedicated Video Memory: 0 MB",
                "[2026.11.24-10.00.01:002][  0]LogD3D11RHI: Feature Level: 11_1",
                "[2026.11.24-10.00.02:100][  1]LogD3D11RHI: Error: CreateSwapChain failed with 0x887A0005 DXGI_ERROR_DEVICE_REMOVED",
                "[2026.11.24-10.00.02:101][  1]neptune: virtgpu: window release failed 0xc0000001",
                "[2026.11.24-10.00.02:200][  1]LogShaderCompilers: Error: Shader compile failed for GlobalShader",
                "[2026.11.24-10.00.02:300][  1]LogInit: user_id=123456 token=secret_abc_999",
            ]
        )
        parsed = analyzer.parse_ue4_log(sample)
        self.assertEqual(parsed["dedicated_vram_mb"], 0)
        self.assertIn("11_1", parsed["feature_levels"])
        self.assertIn("0x887a0005", parsed["hresults"])
        self.assertIn("0xc0000001", parsed["hresults"])
        self.assertIn("zero_dedicated_vram", parsed["blackscreen_indicators"])
        self.assertIn("device_removed_or_hung", parsed["blackscreen_indicators"])
        self.assertIn("swapchain_or_present_error", parsed["blackscreen_indicators"])
        self.assertIn("neptune_error", parsed["blackscreen_indicators"])
        self.assertIn("shader_compile_failure", parsed["blackscreen_indicators"])
        joined = "\n".join(parsed["highlights"])
        self.assertNotIn("secret_abc_999", joined)
        self.assertIn("<redacted-sensitive-line>", joined)

    def test_redact_p7_text_strips_private_paths_and_auth_lines(self) -> None:
        user_name = os.environ.get("USER") or "testuser"
        raw = (
            f"Path: /Volumes/PrivateDisk/data and /Users/{user_name}/file.log\n"
            "Email: player@example.com\n"
            "Login ticket=xyz123\n"
            "Safe line: Red Hat VirtIO GPU 3D controller\n"
        )
        redacted = analyzer.redact_p7_text(raw)
        self.assertNotIn("PrivateDisk", redacted)
        self.assertIn("/Volumes/<EXTERNAL_VOLUME>", redacted)
        self.assertNotIn("player@example.com", redacted)
        self.assertNotIn("xyz123", redacted)
        self.assertIn("<redacted-sensitive-line>", redacted)
        self.assertIn("Red Hat VirtIO GPU 3D controller", redacted)
        if user_name:
            self.assertNotIn(user_name, redacted)

    def test_parse_dxgi_and_vulkan_probe(self) -> None:
        summary = analyzer.parse_dxgi_and_vulkan_probe(
            {
                "wmi_adapter_ram_bytes": 0,
                "dxgi_adapters": [
                    {
                        "description": "Red Hat VirtIO GPU 3D controller",
                        "dedicated_video_memory_bytes": 0,
                        "shared_system_memory_bytes": 3221225472,
                    }
                ],
                "vulkan_icd_files": ["C:\\Windows\\System32\\vulkan_virtio_arm64.json"],
                "vulkan_devices": [{"device_name": "Virtio-GPU Venus (KosmicKrisp Apple M4)"}],
            }
        )
        self.assertTrue(summary["dedicated_vram_is_zero"])
        self.assertTrue(summary["wmi_adapter_ram_is_zero"])
        self.assertTrue(summary["venus_vulkan_ready"])
        self.assertEqual(summary["vulkan_device_count"], 1)

    def test_classify_ace_dxvk_reaction_conservative_modes(self) -> None:
        c1 = analyzer.classify_ace_dxvk_reaction(
            dxvk_tested=True,
            dxvk_dlls_loaded=True,
            ace_drivers_running=True,
            game_visual_lit=True,
            explicit_anticheat_rejection=False,
            main_exit_code=None,
        )
        self.assertEqual(c1["status"], "allowed_and_rendered")

        c2 = analyzer.classify_ace_dxvk_reaction(
            dxvk_tested=True,
            dxvk_dlls_loaded=False,
            ace_drivers_running=True,
            game_visual_lit=False,
            explicit_anticheat_rejection=True,
            main_exit_code=5,
        )
        self.assertEqual(c2["status"], "rejected_by_anticheat")

        c3 = analyzer.classify_ace_dxvk_reaction(
            dxvk_tested=True,
            dxvk_dlls_loaded=True,
            ace_drivers_running=True,
            game_visual_lit=False,
            explicit_anticheat_rejection=False,
            main_exit_code=1,
        )
        self.assertEqual(c3["status"], "exited_nonzero_unattributed")

    def test_build_real_run_report_enforces_five_dimensions_and_redaction(self) -> None:
        report = analyzer.build_real_run_report(
            golden_manifest_sha256="abc123",
            ephemeral_clone_name="ephemeral-p7a-valorant",
            dxgi_vulkan_summary={"venus_vulkan_ready": True},
            neptune_run={"note": "checked /Volumes/SecretVol/foo"},
            venus_dxvk_run={"status": "tested"},
            drift_verification={"golden_zero_drift": True, "primary_zero_drift": True},
            five_dimensions={
                "implementation": "completed",
                "local_gates": "passed",
                "real_guest_run": "executed",
                "vendor_vm_support": "unknown",
                "protected_lobby_and_match": "not_verified",
            },
        )
        serialized = json.dumps(report)
        self.assertNotIn("SecretVol", serialized)
        self.assertTrue(report["compliance"]["golden_image_untouched"])
        self.assertTrue(report["compliance"]["primary_vm_a_untouched"])

        with self.assertRaises(ValueError):
            analyzer.build_real_run_report(
                golden_manifest_sha256="abc123",
                ephemeral_clone_name="ephemeral-p7a-valorant",
                dxgi_vulkan_summary={},
                neptune_run={},
                venus_dxvk_run={},
                drift_verification={},
                five_dimensions={"implementation": "completed"},
            )


if __name__ == "__main__":
    unittest.main()
