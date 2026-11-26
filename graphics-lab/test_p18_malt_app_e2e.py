#!/usr/bin/env python3
"""Unit tests for graphics-lab/p18_malt_app_e2e.py. Owner: @DNPMBHC."""
from __future__ import annotations

import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path

import p18_malt_app_e2e as e2e


class P18MaltAppE2ETests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="test-p18b-e2e-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def _make_utm(self, name: str, readonly: bool = False) -> Path:
        bundle = self.root / name
        (bundle / "Data").mkdir(parents=True, exist_ok=True)
        cfg = {
            "Backend": "QEMU",
            "Information": {"Name": name, "UUID": "11111111-2222-3333-4444-555555555555"},
            "System": {"CPUCount": 4, "MemorySize": 4096, "UEFIBoot": True},
            "Input": {"MaximumUsbShare": 3, "UsbSharing": True},
            "Network": [{"Hardware": "virtio-net-pci", "MacAddress": "52:54:00:aa:bb:cc", "Mode": "Emulated"}],
            "Sound": [],
            "QEMU": {"AdditionalArguments": []},
        }
        cfg_path = bundle / "config.plist"
        cfg_path.write_bytes(plistlib.dumps(cfg, fmt=plistlib.FMT_XML))
        (bundle / "Data/disk.qcow2").write_bytes(b"QFI\xfb" + b"\x00" * 128)
        if readonly:
            os.chmod(cfg_path, 0o444)
            os.chmod(bundle, 0o555)
        return bundle

    def tearDown(self) -> None:
        # Restore write permissions before TemporaryDirectory cleanup
        for path in sorted(self.root.rglob("*"), reverse=True):
            try:
                os.chmod(path, 0o755 if path.is_dir() else 0o644)
            except OSError:
                pass

    def test_protected_vm_names_are_blocked_from_hardware_mutation(self) -> None:
        for name in ("golden-win11-arm64-v1.utm", "vm-a.utm", "vm-a-backup.utm", "Windows11-ARM64.utm"):
            bundle = self._make_utm(name)
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                e2e.apply_hardware_pipeline_to_clone(bundle, "/tmp/malt-net/test.sock")

    def test_apply_hardware_pipeline_configures_non_slirp_unix_stream_and_preserves_mac(self) -> None:
        bundle = self._make_utm("ephemeral-p18b-test.utm")
        summary = e2e.apply_hardware_pipeline_to_clone(bundle, "/tmp/malt-net/p-1234.sock")
        self.assertEqual(summary["fps_limit"], 120)
        self.assertTrue(summary["slirp_eliminated"])
        self.assertTrue(summary["virtio_mouse"])
        self.assertTrue(summary["usb_redir_disabled"])

        cfg = plistlib.loads((bundle / "config.plist").read_bytes())
        self.assertEqual(cfg["Network"], [])
        self.assertEqual(cfg["Input"]["MaximumUsbShare"], 0)
        self.assertTrue(cfg["Input"]["VirtioMouse"])
        self.assertTrue(cfg["Input"]["DisableUsbRedir"])
        self.assertEqual(cfg["QEMU"]["QEMURendererFPSLimit"], 120)
        args = cfg["QEMU"]["AdditionalArguments"]
        self.assertIn("stream,id=net0,server=off,addr.type=unix,path=/tmp/malt-net/p-1234.sock", args)
        self.assertIn("virtio-net-pci,netdev=net0,mac=52:54:00:aa:bb:cc,ioeventfd=on,rx_queue_size=1024", args)
        self.assertTrue((bundle / ".provisioning-hardware-backup.plist").is_file())

    def test_zero_drift_proof_detects_unchanged_and_modified_bundles(self) -> None:
        golden = self._make_utm("golden-win11-arm64-v1.utm", readonly=True)
        primary = self._make_utm("Windows11-ARM64.utm")
        g_cfg, g_bundle = e2e.bundle_digest(golden)
        p_cfg, p_bundle = e2e.bundle_digest(primary)
        before = {
            "golden_readonly": True,
            "golden_config_sha256": g_cfg,
            "golden_bundle_sha256": g_bundle,
            "primary_config_sha256": p_cfg,
            "primary_bundle_sha256": p_bundle,
            "original_utm_codesign_ok": True,
        }
        proof_ok = e2e.build_zero_drift_proof(before, dict(before))
        self.assertTrue(proof_ok["golden_zero_drift"])
        self.assertTrue(proof_ok["primary_zero_drift"])

        drifted = dict(before)
        drifted["primary_config_sha256"] = "0" * 64
        proof_bad = e2e.build_zero_drift_proof(before, drifted)
        self.assertFalse(proof_bad["primary_zero_drift"])
        self.assertFalse(proof_bad["zero_drift"])

    def test_redaction_strips_home_user_and_external_volume_names(self) -> None:
        sample = {
            "path": "/Users/alice/Documents/test",
            "vol": "/Volumes/SecretSSD/whisky-phase2-guest/vms/test.utm",
        }
        redacted = e2e.redact_object(sample)
        dumped = json.dumps(redacted)
        self.assertNotIn("alice", dumped)
        self.assertNotIn("SecretSSD", dumped)
        self.assertIn("/Volumes/<EXTERNAL_VOLUME>", dumped)
        self.assertIn("/Users/<USER>", dumped)

    def test_extract_json_after_marker_handles_noisy_powershell_output(self) -> None:
        raw = "WARNING: something\nMALT_OPT_ROLLBACK={\"rollback_consistent\":true}\ntrailing"
        parsed = e2e._extract_json_after_marker(raw, "MALT_OPT_ROLLBACK=")
        self.assertEqual(parsed, {"rollback_consistent": True})


if __name__ == "__main__":
    unittest.main()
