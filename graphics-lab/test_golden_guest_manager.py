#!/usr/bin/env python3
"""Unit tests for Golden Guest v1 manager. Owner: @DNPMBHC."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest import mock

import golden_guest_manager as ggm


def make_fake_bundle(
    path: Path,
    *,
    name: str,
    vm_uuid: str,
    display_hw: str = "virtio-ramfb-gl",
    share_mode: str = "None",
    clipboard: bool = False,
    usb_sharing: bool = False,
    tpm: bool = True,
    uefi: bool = True,
    mac: str = "AA:BB:CC:DD:EE:01",
) -> None:
    data_dir = path / "Data"
    data_dir.mkdir(parents=True, exist_ok=True)
    disk_name = "disk-0.qcow2"
    (data_dir / disk_name).write_bytes(b"QCOW-FAKE-DATA")
    cfg = {
        "Backend": "QEMU",
        "ConfigurationVersion": 4,
        "Display": [{"Hardware": display_hw, "DynamicResolution": True}],
        "Drive": [
            {
                "Identifier": "DISK-1",
                "ImageName": disk_name,
                "ImageType": "Disk",
                "Interface": "NVMe",
            }
        ],
        "Information": {"Name": name, "UUID": vm_uuid},
        "Input": {"UsbSharing": usb_sharing},
        "Network": [{"Hardware": "virtio-net-pci", "MacAddress": mac, "Mode": "Shared"}],
        "QEMU": {
            "AdditionalArguments": [],
            "Hypervisor": True,
            "TPMDevice": tpm,
            "UEFIBoot": uefi,
        },
        "Sharing": {
            "ClipboardSharing": clipboard,
            "DirectoryShareMode": share_mode,
            "DirectoryShareReadOnly": True,
        },
        "System": {
            "Architecture": "aarch64",
            "CPUCount": 6,
            "MemorySize": 6144,
        },
    }
    with (path / "config.plist").open("wb") as handle:
        plistlib.dump(cfg, handle)


class GoldenGuestManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="ggm-test-"))
        self.primary = self.tmp / "Windows11-ARM64.utm"
        self.golden = self.tmp / "golden-win11-arm64-v1.utm"
        make_fake_bundle(
            self.primary,
            name="Windows11-ARM64",
            vm_uuid="11111111-1111-1111-1111-111111111111",
            display_hw="virtio-ramfb",
            share_mode="WebDAV",
            clipboard=True,
        )
        make_fake_bundle(
            self.golden,
            name="golden-win11-arm64-v1",
            vm_uuid="22222222-2222-2222-2222-222222222222",
            display_hw="virtio-ramfb-gl",
            share_mode="None",
            clipboard=False,
        )
        ggm.set_bundle_readonly(self.golden, readonly=True)

    def tearDown(self) -> None:
        if self.golden.exists():
            ggm.set_bundle_readonly(self.golden, readonly=False)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_verify_golden_emits_redacted_manifest(self) -> None:
        guest_report = self.tmp / "guest.json"
        guest_report.write_text(
            json.dumps(
                {
                    "security_invariants": {
                        "secure_boot_enabled": True,
                        "test_signing_disabled": True,
                        "tpm_enabled": True,
                        "qga_service_running": True,
                        "prism_signatures_valid": True,
                    },
                    "graphics_driver": {
                        "driver_version": "100.6.101.58000",
                        "adapter_name": "Red Hat VirtIO GPU 3D controller",
                        "whql_ready": True,
                        "all_components_present": True,
                    },
                    "optimizer": {"rollback_snapshot_present": True},
                    "commercial_residue": {"zero_commercial_residue": True},
                }
            ),
            encoding="utf-8",
        )
        smoke_report = self.tmp / "smoke.json"
        smoke_report.write_text(
            json.dumps(
                {
                    "cold_boot_qga_seconds": 13.5,
                    "idle_host_rss_mib": 3800.0,
                    "d3d11_probe_fps": 128.4,
                    "feature_level": "11_1",
                    "max_channel_error_lsb": 0,
                    "byte_exact_match": True,
                }
            ),
            encoding="utf-8",
        )
        out_manifest = self.tmp / "golden-guest-manifest.json"
        manifest = ggm.verify_golden(
            golden=self.golden,
            primary=self.primary,
            guest_report_path=guest_report,
            smoke_report_path=smoke_report,
            output_path=out_manifest,
        )
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["status"], "sealed_readonly")
        self.assertTrue(manifest["fingerprints"]["sealed_readonly"])
        self.assertTrue(manifest["graphics_driver"]["whql_ready"])
        self.assertEqual(manifest["smoke_metrics"]["max_channel_error_lsb"], 0)
        text = out_manifest.read_text(encoding="utf-8")
        user_name = os.environ.get("USER", "")
        if user_name:
            self.assertNotIn(user_name, text)

    def test_verify_golden_rejects_unsecured_qemu_config(self) -> None:
        bad = self.tmp / "bad-golden.utm"
        make_fake_bundle(
            bad,
            name="bad",
            vm_uuid="33333333-3333-3333-3333-333333333333",
            display_hw="virtio-ramfb",
            share_mode="WebDAV",
        )
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.verify_golden(golden=bad, primary=self.primary)

    def test_spawn_and_destroy_ephemeral_lifecycle(self) -> None:
        manifest_path = self.tmp / "manifest.json"
        ggm.verify_golden(
            golden=self.golden,
            primary=self.primary,
            output_path=manifest_path,
        )
        spawn_res = ggm.spawn_ephemeral(
            golden=self.golden,
            dest_dir=self.tmp,
            name="ephemeral-smoke-01",
            primary=self.primary,
            register_utm=False,
            skip_apfs_check=True,
        )
        eph_path = Path(spawn_res["ephemeral_path"])
        self.assertTrue(eph_path.is_dir())
        self.assertNotEqual(spawn_res["clone_uuid"], "22222222-2222-2222-2222-222222222222")
        self.assertNotEqual(spawn_res["mac_address"], "AA:BB:CC:DD:EE:01")
        self.assertTrue((eph_path / ggm.EPHEMERAL_META_FILENAME).is_file())
        self.assertTrue(ggm.is_bundle_readonly(self.golden))

        destroy_res = ggm.destroy_ephemeral(
            ephemeral_path=eph_path,
            golden=self.golden,
            primary=self.primary,
            baseline_manifest_path=manifest_path,
            utmctl=self.tmp / "missing-utmctl",
        )
        self.assertTrue(destroy_res["ephemeral_deleted"])
        self.assertTrue(destroy_res["golden_zero_drift"])
        self.assertTrue(destroy_res["primary_zero_drift"])
        self.assertFalse(eph_path.exists())

    def test_safety_blocks_primary_golden_and_untagged_bundles(self) -> None:
        with self.assertRaises(ggm.SafetyError):
            ggm.destroy_ephemeral(
                ephemeral_path=self.primary,
                golden=self.golden,
                primary=self.primary,
            )
        with self.assertRaises(ggm.SafetyError):
            ggm.destroy_ephemeral(
                ephemeral_path=self.golden,
                golden=self.golden,
                primary=self.primary,
            )
        untagged = self.tmp / "untagged.utm"
        make_fake_bundle(
            untagged,
            name="untagged",
            vm_uuid="44444444-4444-4444-4444-444444444444",
        )
        with self.assertRaises(ggm.SafetyError):
            ggm.destroy_ephemeral(
                ephemeral_path=untagged,
                golden=self.golden,
                primary=self.primary,
            )

    def test_spawn_requires_readonly_golden(self) -> None:
        ggm.set_bundle_readonly(self.golden, readonly=False)
        with self.assertRaises(ggm.SafetyError):
            ggm.spawn_ephemeral(
                golden=self.golden,
                dest_dir=self.tmp,
                name="ephemeral-should-fail",
                primary=self.primary,
                skip_apfs_check=True,
            )

    def test_prepare_golden_blocks_held_lease_and_allows_released(self) -> None:
        lease_path = self.tmp / "vm-lease.json"
        lease_path.write_text(json.dumps({"status": "held"}), encoding="utf-8")
        dest = self.tmp / "staged-golden.utm"
        with mock.patch("golden_guest_manager.check_lease_and_processes") as mock_lease:
            mock_lease.return_value = {"lease_status": "held", "active_qemu_workers": [], "ready": False}
            with self.assertRaises(ggm.SafetyError):
                ggm.prepare_golden_from_primary(
                    primary=self.primary,
                    golden_dest=dest,
                    lease_path=lease_path,
                    skip_apfs_check=True,
                )

        lease_path.write_text(
            json.dumps({"status": "released", "released_at": "2026-11-24T07:19:32Z"}),
            encoding="utf-8",
        )
        with mock.patch("golden_guest_manager.check_lease_and_processes") as mock_lease:
            mock_lease.return_value = {"lease_status": "released", "active_qemu_workers": [], "ready": True}
            res = ggm.prepare_golden_from_primary(
                primary=self.primary,
                golden_dest=dest,
                lease_path=lease_path,
                skip_apfs_check=True,
            )
            self.assertTrue(res["primary_untouched"])
            cfg = ggm.read_config_plist(dest)
            self.assertEqual(cfg["Display"][0]["Hardware"], "virtio-ramfb-gl")
            self.assertEqual(cfg["Sharing"]["DirectoryShareMode"], "None")
            self.assertFalse(cfg["Sharing"]["ClipboardSharing"])

    def test_spawn_ephemeral_trim_hardware_and_dx_driver_override(self) -> None:
        ggm.set_bundle_readonly(self.golden, readonly=False)
        cfg = ggm.read_config_plist(self.golden)
        cfg["Drive"].append({"Identifier": "CDROM-1", "ImageType": "CD", "Interface": "USB"})
        ggm.write_config_plist(self.golden, cfg)
        ggm.set_bundle_readonly(self.golden, readonly=True)

        spawned = ggm.spawn_ephemeral(
            golden=self.golden,
            dest_dir=self.tmp,
            name="ephemeral-trimmed-dxmt",
            primary=self.primary,
            skip_apfs_check=True,
            trim_hardware=True,
            dx_driver="DXMT",
            fps_limit=120,
        )
        self.assertTrue(spawned["golden_untouched"])
        trim = spawned["trim_summary"]
        self.assertTrue(trim["trim_hardware_applied"])
        self.assertEqual(trim["removed_empty_cdrom_slots"], 1)
        self.assertTrue(trim["dynamic_resolution_locked_false"])
        self.assertTrue(trim["usb_sharing_disabled"])
        self.assertEqual(trim["maximum_usb_shares"], 0)
        self.assertEqual(trim["directx_driver"], 2)
        self.assertEqual(trim["renderer_fps_limit"], 120)

        cloned_cfg = ggm.read_config_plist(Path(spawned["ephemeral_path"]))
        self.assertEqual(len(cloned_cfg["Drive"]), 1)
        self.assertFalse(cloned_cfg["Display"][0]["DynamicResolution"])
        self.assertEqual(cloned_cfg["QEMU"]["DirectXDriver"], 2)

    def test_trim_rejects_invalid_dx_driver_or_fps_limit(self) -> None:
        cfg = ggm.read_config_plist(self.golden)
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, trim_hardware=True, dx_driver="InvalidBackend")
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, trim_hardware=True, fps_limit=0)
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, trim_hardware=True, ram_mb=4096)
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, trim_hardware=True, vcpu=0)

    def test_sound_retained_by_default_and_stripped_only_with_no_sound(self) -> None:
        spawned_with_sound = ggm.spawn_ephemeral(
            golden=self.golden,
            dest_dir=self.tmp,
            name="ephemeral-sound-default",
            primary=self.primary,
            skip_apfs_check=True,
            trim_hardware=True,
            ram_mb=8192,
            vcpu=4,
            disable_balloon=True,
            pure_relative_mouse=True,
        )
        t = spawned_with_sound["trim_summary"]
        self.assertTrue(t["sound_enabled"])
        self.assertEqual(t["sound_devices"], ["intel-hda"])
        self.assertEqual(t["memory_mib"], 8192)
        self.assertEqual(t["cpu_count"], 4)
        self.assertFalse(t["balloon_device"])
        self.assertTrue(t["pure_relative_mouse"])

        cfg_sound = ggm.read_config_plist(Path(spawned_with_sound["ephemeral_path"]))
        self.assertEqual(cfg_sound["Sound"], [{"Hardware": "intel-hda"}])
        self.assertEqual(cfg_sound["System"]["MemorySize"], 8192)
        self.assertEqual(cfg_sound["System"]["CPUCount"], 4)
        self.assertFalse(cfg_sound["QEMU"]["BalloonDevice"])
        self.assertTrue(cfg_sound["Input"]["PureRelativeMouse"])

        spawned_no_sound = ggm.spawn_ephemeral(
            golden=self.golden,
            dest_dir=self.tmp,
            name="ephemeral-no-sound",
            primary=self.primary,
            skip_apfs_check=True,
            trim_hardware=True,
            no_sound=True,
        )
        self.assertFalse(spawned_no_sound["trim_summary"]["sound_enabled"])
        self.assertEqual(ggm.read_config_plist(Path(spawned_no_sound["ephemeral_path"]))["Sound"], [])

    def test_create_launch_and_reset_playable_vm(self) -> None:
        created = ggm.create_playable(
            golden=self.golden,
            dest_dir=self.tmp,
            name="playable-daily-01",
            primary=self.primary,
            skip_apfs_check=True,
            ram_mb=8192,
            vcpu=4,
            disable_balloon=True,
            pure_relative_mouse=True,
        )
        p_path = Path(created["playable_path"])
        self.assertTrue(p_path.is_dir())
        self.assertFalse(created["was_reset"])
        self.assertTrue(created["golden_untouched"])
        self.assertTrue((p_path / ggm.PLAYABLE_META_FILENAME).is_file())
        self.assertEqual(created["trim_summary"]["sound_devices"], ["intel-hda"])
        self.assertEqual(created["trim_summary"]["memory_mib"], 8192)
        self.assertEqual(created["trim_summary"]["cpu_count"], 4)
        self.assertFalse(created["trim_summary"]["balloon_device"])

        # Without --reset, recreating fails safely
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.create_playable(
                golden=self.golden,
                dest_dir=self.tmp,
                name="playable-daily-01",
                primary=self.primary,
                skip_apfs_check=True,
            )

        # Dry-run launch validates marker & UUID
        launched = ggm.launch_playable(
            p_path,
            golden=self.golden,
            primary=self.primary,
            dry_run=True,
        )
        self.assertEqual(launched["vm_uuid"], created["vm_uuid"])
        self.assertTrue(launched["dry_run"])

        # Reset recreates fresh UUID while preserving golden zero drift
        reset_res = ggm.create_playable(
            golden=self.golden,
            dest_dir=self.tmp,
            name="playable-daily-01",
            primary=self.primary,
            reset=True,
            utmctl=self.tmp / "missing-utmctl",
            skip_apfs_check=True,
        )
        self.assertTrue(reset_res["was_reset"])
        self.assertNotEqual(reset_res["vm_uuid"], created["vm_uuid"])
        self.assertTrue(ggm.is_bundle_readonly(self.golden))

        # Safety: launch/reset refuses primary or untagged bundles
        with self.assertRaises(ggm.SafetyError):
            ggm.launch_playable(self.primary, golden=self.golden, primary=self.primary, dry_run=True)
        with self.assertRaises(ggm.SafetyError):
            ggm.launch_playable(self.golden, golden=self.golden, primary=self.primary, dry_run=True)

    def test_p12a_playable_defaults_10gib_virtio_iothread_and_vmnet_shared(self) -> None:
        self.assertEqual(ggm.DEFAULT_PLAYABLE_RAM_MB, 10240)
        with mock.patch("golden_guest_manager.detect_apple_silicon_p_cores", return_value=4), \
             mock.patch("os.cpu_count", return_value=10):
            self.assertEqual(ggm.detect_recommended_vcpu(), 8)
        with mock.patch("golden_guest_manager.detect_apple_silicon_p_cores", return_value=4), \
             mock.patch("os.cpu_count", return_value=8):
            self.assertEqual(ggm.detect_recommended_vcpu(), 6)
        created = ggm.create_playable(
            golden=self.golden,
            dest_dir=self.tmp,
            name="playable-p12a-defaults",
            primary=self.primary,
            skip_apfs_check=True,
        )
        t = created["trim_summary"]
        self.assertEqual(t["memory_mib"], 10240)
        self.assertFalse(t["balloon_device"])
        self.assertEqual(t["network_mode"], "vmnet-shared")
        self.assertEqual(t["net_rx_queue_size"], 1024)
        self.assertEqual(t["disk_interfaces"], ["VirtIO"])
        self.assertTrue(t["virtio_blk_iothread"])
        self.assertEqual(t["virtio_blk_num_queues"], 4)
        self.assertTrue(t["discard_unmap_expected"])

        cfg = ggm.read_config_plist(Path(created["playable_path"]))
        self.assertEqual(cfg["System"]["MemorySize"], 10240)
        self.assertEqual(cfg["Drive"][0]["Interface"], "VirtIO")
        self.assertEqual(cfg["Network"][0]["Mode"], "Shared")
        add = cfg["QEMU"]["AdditionalArguments"]
        self.assertIn("iothread,id=iothread0", add)
        self.assertIn("virtio-blk-pci.iothread=iothread0", add)
        self.assertIn("virtio-blk-pci.num-queues=4", add)
        self.assertIn("virtio-net-pci.ioeventfd=on", add)
        self.assertIn("virtio-net-pci.rx_queue_size=1024", add)

    def test_p12a_socket_stream_and_socket_vmnet_bypass_utm_entitlement_check(self) -> None:
        spawned_tcp = ggm.spawn_ephemeral(
            golden=self.golden,
            dest_dir=self.tmp,
            name="ephemeral-p12a-stream",
            primary=self.primary,
            skip_apfs_check=True,
            trim_hardware=True,
            network_mode="socket-stream",
            socket_endpoint="127.0.0.1:18443",
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=6,
        )
        cfg = ggm.read_config_plist(Path(spawned_tcp["ephemeral_path"]))
        self.assertEqual(cfg["Network"], [])
        add = cfg["QEMU"]["AdditionalArguments"]
        self.assertIn("stream,id=net0,server=off,addr.type=inet,addr.host=127.0.0.1,addr.port=18443", add)
        self.assertTrue(any(a.startswith("virtio-net-pci,netdev=net0,mac=") and "rx_queue_size=1024" in a for a in add))
        self.assertIn("virtio-blk-pci.num-queues=6", add)

        spawned_unix = ggm.spawn_ephemeral(
            golden=self.golden,
            dest_dir=self.tmp,
            name="ephemeral-p12a-sockvmnet",
            primary=self.primary,
            skip_apfs_check=True,
            trim_hardware=True,
            network_mode="socket-vmnet",
            socket_endpoint="/var/run/socket_vmnet",
        )
        cfg_u = ggm.read_config_plist(Path(spawned_unix["ephemeral_path"]))
        self.assertEqual(cfg_u["Network"], [])
        self.assertIn("stream,id=net0,server=off,addr.type=unix,path=/var/run/socket_vmnet", cfg_u["QEMU"]["AdditionalArguments"])

    def test_p12a_rejects_invalid_network_io_and_forbidden_qemu_args(self) -> None:
        cfg = ggm.read_config_plist(self.golden)
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, network_mode="socket-vmnet")
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, network_mode="socket-stream", socket_endpoint="127.0.0.1:99999")
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, disk_interface="ide")
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, io_queues=16)
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(cfg, net_rx_queue_size=4096)
        bad_cfg = ggm.read_config_plist(self.golden)
        bad_cfg["QEMU"]["AdditionalArguments"] = ["-cpu", "host,kvm=off"]
        with self.assertRaises(ggm.SafetyError):
            ggm.trim_ephemeral_utm_config(bad_cfg)


if __name__ == "__main__":
    unittest.main()
