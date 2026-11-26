#!/usr/bin/env python3
"""Unit tests for Golden Guest v1 manager. Owner: @DNPMBHC."""
from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import socket
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

    def test_p13a_warm_standby_pause_and_resume_launch_guards(self) -> None:
        created = ggm.create_playable(
            golden=self.golden,
            dest_dir=self.tmp,
            name="playable-p13a-standby",
            primary=self.primary,
            skip_apfs_check=True,
        )
        playable = Path(created["playable_path"])

        # Never allow pause/resume on golden or primary
        with self.assertRaises(ggm.SafetyError):
            ggm.pause_vm(self.primary, golden=self.golden, primary=self.primary, dry_run=True)
        with self.assertRaises(ggm.SafetyError):
            ggm.resume_launch(self.golden, golden=self.golden, primary=self.primary, dry_run=True)
        with self.assertRaises(ggm.SafetyError):
            ggm.qmp_send_command(self.tmp / "nonexistent.sock", "human-monitor-command")

        dry_warm = ggm.warm_standby(playable, golden=self.golden, primary=self.primary, dry_run=True)
        self.assertEqual(dry_warm["action"], "warm-standby")
        self.assertTrue(dry_warm["dry_run"])

        # Mocked utmctl warm-standby -> pause -> resume-launch lifecycle
        statuses = iter(["stopped", "started", "paused", "paused", "started"])

        def fake_status(_uuid: str, _utmctl: Path = ggm.DEFAULT_UTMCTL) -> str:
            return next(statuses, "started")

        ok_proc = mock.Mock(returncode=0, stdout="QGA_OK\n", stderr="")
        with (
            mock.patch.object(ggm, "utmctl_status", side_effect=fake_status),
            mock.patch.object(ggm.subprocess, "run", return_value=ok_proc),
            mock.patch.object(ggm, "sample_qemu_standby_metrics", return_value={
                "qemu_worker_count": 1,
                "qemu_cpu_pct": 0.0,
                "qemu_rss_mib": 1200.0,
                "macos_compressor_mib": 640.0,
            }),
            mock.patch.object(ggm.time, "sleep", return_value=None),
        ):
            warm = ggm.warm_standby(playable, golden=self.golden, primary=self.primary)
            self.assertTrue(warm["standby_ready"])
            self.assertEqual(warm["status"], "paused")
            self.assertEqual(warm["standby_metrics"]["qemu_cpu_pct"], 0.0)

            resumed = ggm.resume_launch(playable, golden=self.golden, primary=self.primary)
            self.assertTrue(resumed["resumed"])
            self.assertEqual(resumed["launch_mode"], "warm_resume")
            self.assertEqual(resumed["state_before"], "paused")

    def test_p15a_deemulation_virtio_mouse_usb_redir_removal_and_fps120_defaults(self) -> None:
        created = ggm.create_playable(
            golden=self.golden,
            dest_dir=self.tmp,
            name="playable-p15a-defaults",
            primary=self.primary,
            skip_apfs_check=True,
        )
        t = created["trim_summary"]
        self.assertTrue(t["virtio_mouse"])
        self.assertTrue(t["pure_relative_mouse"])
        self.assertTrue(t["usb_redir_disabled"])
        self.assertEqual(t["maximum_usb_share"], 0)
        self.assertEqual(t["renderer_fps_limit"], 120)
        self.assertTrue(t["triple_buffering_enabled"])
        self.assertEqual(t["metal_drawable_count"], 3)
        self.assertTrue(t["iosurface_direct_present"])
        self.assertEqual(t["sound_devices"], ["intel-hda"])

        cfg = ggm.read_config_plist(Path(created["playable_path"]))
        self.assertEqual(cfg["Input"]["MaximumUsbShare"], 0)
        self.assertNotIn("MaximumUsbShares", cfg["Input"])
        self.assertTrue(cfg["Input"]["DisableUsbRedir"])
        self.assertTrue(cfg["Input"]["VirtioMouse"])
        self.assertTrue(cfg["Input"]["PureRelativeMouse"])
        self.assertEqual(cfg["QEMU"]["QEMURendererFPSLimit"], 120)
        self.assertEqual(cfg["QEMU"]["RendererFPSLimit"], 120)
        self.assertTrue(cfg["Display"][0]["IOSurfaceDirectPresent"])

        # Fallback to emulated usb-mouse works cleanly
        fallback = ggm.create_playable(
            golden=self.golden,
            dest_dir=self.tmp,
            name="playable-p15a-usb-fallback",
            primary=self.primary,
            skip_apfs_check=True,
            virtio_mouse=False,
        )
        self.assertFalse(fallback["trim_summary"]["virtio_mouse"])
        cfg_fb = ggm.read_config_plist(Path(fallback["playable_path"]))
        self.assertFalse(cfg_fb["Input"].get("VirtioMouse", False))

        # Invalid sound hardware rejected
        bad_cfg = ggm.read_config_plist(self.golden)
        with self.assertRaises(ggm.GoldenGuestError):
            ggm.trim_ephemeral_utm_config(bad_cfg, sound_hardware="sb16-invalid")

    def test_p15a_network_three_tier_auto_resolution_with_malt_vmnet_bridge(self) -> None:
        # Tier 1: entitled UTM -> vmnet-shared
        with mock.patch.object(
            ggm,
            "detect_host_network_capabilities",
            return_value={
                "official_utm_vmnet_entitled": True,
                "malt_vmnet_bridge_socket_active": False,
                "active_vmnet_daemon_socket": None,
            },
        ):
            r1 = ggm.resolve_effective_network_config(prefer_adhoc=False)
            self.assertEqual(r1["network_mode"], "vmnet-shared")

        # Tier 2: ad-hoc build + active malt-vmnet-bridge daemon -> socket-vmnet (kernel vmnet)
        with mock.patch.object(
            ggm,
            "detect_host_network_capabilities",
            return_value={
                "official_utm_vmnet_entitled": True,
                "malt_vmnet_bridge_socket_active": True,
                "active_vmnet_daemon_socket": "/var/run/malt-vmnet-bridge.sock",
            },
        ):
            r2 = ggm.resolve_effective_network_config(prefer_adhoc=True)
            self.assertEqual(r2["network_mode"], "socket-vmnet")
            self.assertEqual(r2["socket_endpoint"], "/var/run/malt-vmnet-bridge.sock")
            self.assertIn("malt-vmnet-bridge", r2["reason"])

        # Tier 3: ad-hoc build without daemon -> seamless fallback to full TCP+UDP+ICMP socket-stream
        with mock.patch.object(
            ggm,
            "detect_host_network_capabilities",
            return_value={
                "official_utm_vmnet_entitled": False,
                "malt_vmnet_bridge_socket_active": False,
                "active_vmnet_daemon_socket": None,
            },
        ):
            r3 = ggm.resolve_effective_network_config(
                prefer_adhoc=True,
                fallback_stream_endpoint="127.0.0.1:18499",
            )
            self.assertEqual(r3["network_mode"], "socket-stream")
            self.assertEqual(r3["socket_endpoint"], "127.0.0.1:18499")


class NativeNetworkPermissionProbeTests(unittest.TestCase):
    def test_socket_probe_rejects_regular_file_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory(prefix="network-", dir="/tmp") as temp:
            target = Path(temp) / "endpoint"
            target.write_bytes(b"not a socket")
            target.chmod(0o600)
            alias = Path(temp) / "alias"
            alias.symlink_to(target)
            self.assertFalse(ggm.secure_vmnet_socket(target))
            self.assertFalse(ggm.secure_vmnet_socket(alias))

    def test_socket_probe_requires_console_owner_and_private_mode(self) -> None:
        with tempfile.TemporaryDirectory(prefix="network-", dir="/tmp") as temp:
            target = Path(temp) / "endpoint.sock"
            endpoint = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                endpoint.bind(str(target))
                target.chmod(0o600)
                self.assertEqual(ggm.secure_vmnet_socket(target), os.getuid() >= 501)
                self.assertFalse(ggm.secure_vmnet_socket(target, current_uid=os.getuid() + 1))
                target.chmod(0o666)
                self.assertFalse(ggm.secure_vmnet_socket(target))
            finally:
                endpoint.close()

    def test_entitlement_probe_reads_boolean_value_and_rejects_error_messages(self) -> None:
        key = "com.apple.vm.networking"
        enabled = plistlib.dumps({key: True}).decode()
        disabled = plistlib.dumps({key: False}).decode()
        self.assertTrue(ggm._entitlement_enabled(enabled, key))
        self.assertFalse(ggm._entitlement_enabled(disabled, key))
        self.assertFalse(ggm._entitlement_enabled("denied " + key, key))
        self.assertFalse(ggm._entitlement_enabled("<plist><dict>broken</plist>", key))

    def test_embedded_paths_move_state_to_user_support(self) -> None:
        scripts = Path("/Applications/demo-app.app/Contents/Resources/RuntimeScripts")
        home = Path("/home/user")
        paths = ggm.embedded_runtime_paths(scripts, home=home)
        self.assertIsNotNone(paths)
        assert paths is not None
        self.assertEqual(paths["profile"], scripts / "profiles/guest-profile.json")
        self.assertTrue(paths["lease"].is_relative_to(home / "Library/Application Support"))
        self.assertFalse(paths["lease"].is_relative_to(scripts))
        self.assertIsNone(ggm.embedded_runtime_paths(Path("/workspace/my-project/graphics-lab"), home=home))

    def test_relocated_module_has_no_handoff_or_workspace_defaults(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-relocation-") as temp:
            scripts = Path(temp) / "demo-app.app/Contents/Resources/RuntimeScripts"
            scripts.mkdir(parents=True)
            relocated = scripts / "golden_guest_manager.py"
            shutil.copyfile(ggm.__file__, relocated)
            values = runpy.run_path(str(relocated), run_name="relocated_runtime")
            self.assertEqual(values["DEFAULT_PROFILE_PATH"], scripts.resolve() / "profiles/guest-profile.json")
            self.assertNotIn("handoff", str(values["DEFAULT_LEASE_PATH"]))
            self.assertNotIn(str(scripts), str(values["DEFAULT_LEASE_PATH"]))
            with self.assertRaisesRegex(RuntimeError, "Guest environment is not configured"):
                values["load_profile"]()


class PlayableNetworkConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="network-config-")
        self.root = Path(self.directory.name)
        self.playable = self.root / "playable-demo.utm"
        self.vm_uuid = "33333333-3333-3333-3333-333333333333"
        make_fake_bundle(self.playable, name="playable-demo", vm_uuid=self.vm_uuid)
        (self.playable / ggm.PLAYABLE_META_FILENAME).write_text(json.dumps({
            "role": "playable_working_vm", "vm_uuid": self.vm_uuid,
            "mac_address": "AA:BB:CC:DD:EE:01"
        }))
        self.original = ggm.read_config_plist(self.playable)
        self.state_patch = mock.patch.object(ggm, "utmctl_status", return_value="stopped")
        self.socket_patch = mock.patch.object(ggm, "secure_vmnet_socket", return_value=True)
        self.state = self.state_patch.start()
        self.socket_patch.start()

    def tearDown(self) -> None:
        self.socket_patch.stop()
        self.state_patch.stop()
        self.directory.cleanup()

    def test_enable_verifies_stream_and_preserves_nonnetwork_configuration(self) -> None:
        result = ggm.configure_playable_network(self.playable)
        self.assertTrue(result["config_verified"])
        self.assertEqual(result["network_mode"], "socket-vmnet")
        config = ggm.read_config_plist(self.playable)
        self.assertEqual(config["Network"], [])
        arguments = config["QEMU"]["AdditionalArguments"]
        self.assertIn("stream,id=net0,server=off,addr.type=unix,path=/var/run/malt-vmnet-bridge.sock", arguments)
        self.assertEqual(config["System"], self.original["System"])
        self.assertEqual(config["Drive"], self.original["Drive"])
        self.assertEqual(config["Sharing"], self.original["Sharing"])
        self.assertEqual((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).stat().st_mode & 0o777, 0o600)

    def test_restore_preserves_later_nonnetwork_edits(self) -> None:
        ggm.configure_playable_network(self.playable)
        config = ggm.read_config_plist(self.playable)
        config["System"]["MemorySize"] = 8192
        ggm.write_config_plist(self.playable, config)
        result = ggm.configure_playable_network(self.playable, restore=True)
        self.assertTrue(result["config_verified"])
        self.assertTrue(result["restored"])
        config = ggm.read_config_plist(self.playable)
        self.assertEqual(config["Network"], self.original["Network"])
        self.assertEqual(config["QEMU"]["AdditionalArguments"], self.original["QEMU"]["AdditionalArguments"])
        self.assertEqual(config["System"]["MemorySize"], 8192)
        self.assertFalse((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).exists())

    def test_running_paused_and_unknown_states_are_refused_without_writes(self) -> None:
        before = (self.playable / "config.plist").read_bytes()
        for state in ("started", "paused", "unregistered", "utmctl-unavailable", "unknown"):
            self.state.return_value = state
            with self.assertRaisesRegex(ggm.SafetyError, "Stop this playable"):
                ggm.configure_playable_network(self.playable)
            self.assertEqual((self.playable / "config.plist").read_bytes(), before)
            self.assertFalse((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).exists())

    def test_unapproved_service_is_refused(self) -> None:
        with mock.patch.object(ggm, "secure_vmnet_socket", return_value=False):
            with self.assertRaisesRegex(ggm.GoldenGuestError, "not approved"):
                ggm.configure_playable_network(self.playable)
        self.assertEqual(ggm.read_config_plist(self.playable), self.original)

    def test_protected_template_and_backup_names_are_refused_even_with_marker(self) -> None:
        for name in ("golden-demo.utm", "vm-a.utm", "vm-a-backup.utm"):
            target = self.root / name
            shutil.copytree(self.playable, target)
            with self.assertRaises(ggm.SafetyError):
                ggm.configure_playable_network(target)

    def test_unmanaged_or_ephemeral_instance_is_refused(self) -> None:
        marker = self.playable / ggm.PLAYABLE_META_FILENAME
        marker.unlink()
        with self.assertRaises(ggm.SafetyError):
            ggm.configure_playable_network(self.playable)
        (self.playable / ggm.EPHEMERAL_META_FILENAME).write_text(json.dumps({
            "role": "ephemeral_golden_clone", "clone_uuid": self.vm_uuid
        }))
        with self.assertRaisesRegex(ggm.SafetyError, "persistent playable"):
            ggm.configure_playable_network(self.playable)

    def test_enable_is_idempotent_and_keeps_first_backup(self) -> None:
        ggm.configure_playable_network(self.playable)
        backup = (self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).read_bytes()
        result = ggm.configure_playable_network(self.playable)
        self.assertTrue(result["config_verified"])
        self.assertFalse(result["changed"])
        self.assertEqual((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).read_bytes(), backup)

    def test_restore_refuses_later_network_edits(self) -> None:
        ggm.configure_playable_network(self.playable)
        config = ggm.read_config_plist(self.playable)
        config["QEMU"]["AdditionalArguments"].extend(["-name", "changed"])
        ggm.write_config_plist(self.playable, config)
        with self.assertRaisesRegex(ggm.SafetyError, "newer settings"):
            ggm.configure_playable_network(self.playable, restore=True)
        self.assertTrue((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).exists())

    def test_dry_run_does_not_write_config_or_backup(self) -> None:
        before = (self.playable / "config.plist").read_bytes()
        result = ggm.configure_playable_network(self.playable, dry_run=True)
        self.assertFalse(result["configured"])
        self.assertFalse(result["config_verified"])
        self.assertEqual((self.playable / "config.plist").read_bytes(), before)
        self.assertFalse((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).exists())

    def test_instance_starting_during_operation_is_refused(self) -> None:
        self.state.side_effect = ["stopped", "started"]
        with self.assertRaisesRegex(ggm.SafetyError, "changed during"):
            ggm.configure_playable_network(self.playable)
        self.assertEqual(ggm.read_config_plist(self.playable), self.original)
        self.assertFalse((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).exists())

    def test_uuid_mismatch_is_refused(self) -> None:
        config = ggm.read_config_plist(self.playable)
        config["Information"]["UUID"] = "different-instance"
        ggm.write_config_plist(self.playable, config)
        with self.assertRaisesRegex(ggm.SafetyError, "UUID"):
            ggm.configure_playable_network(self.playable)

    def test_symlink_config_is_refused(self) -> None:
        target = self.root / "target.plist"
        config = self.playable / "config.plist"
        config.rename(target)
        config.symlink_to(target)
        with self.assertRaisesRegex(ggm.SafetyError, "Symbolic links"):
            ggm.configure_playable_network(self.playable)

    def test_restore_without_backup_is_refused(self) -> None:
        with self.assertRaisesRegex(ggm.GoldenGuestError, "No saved network"):
            ggm.configure_playable_network(self.playable, restore=True)


    def test_restore_removes_qemu_dictionary_if_originally_absent(self) -> None:
        config = ggm.read_config_plist(self.playable)
        config.pop("QEMU")
        ggm.write_config_plist(self.playable, config)
        ggm.configure_playable_network(self.playable)
        ggm.configure_playable_network(self.playable, restore=True)
        self.assertNotIn("QEMU", ggm.read_config_plist(self.playable))

    def test_cli_failure_is_structured_and_has_no_local_path_or_traceback(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = ggm.main(["configure-network", "--playable", str(self.root / "missing.utm")])
        self.assertEqual(code, 1)
        payload = json.loads(output.getvalue())
        self.assertFalse(payload["configured"])
        self.assertFalse(payload["config_verified"])
        self.assertNotIn(str(self.root), output.getvalue())
        self.assertNotIn("Traceback", output.getvalue())


    def _assert_saved_state_refused_without_writes(self, restore=False):
        config = self.playable / "config.plist"
        backup = self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME
        original = config.read_bytes()
        saved_backup = backup.read_bytes() if backup.exists() else None
        with self.assertRaisesRegex(ggm.SafetyError, "saved.state|suspended"):
            ggm.configure_playable_network(self.playable, restore=restore)
        self.assertEqual(config.read_bytes(), original)
        self.assertEqual(backup.read_bytes() if backup.exists() else None, saved_backup)

    def test_managed_then_suspended_refuses_apply_and_restore_even_when_control_reports_stopped(self):
        for restore in (False, True):
            with self.subTest(restore=restore):
                if restore:
                    ggm.configure_playable_network(self.playable)
                state = self.playable / "snapshots.plist"
                state.write_bytes(plistlib.dumps({"SuspendIdentifier": "saved-session"}))
                self._assert_saved_state_refused_without_writes(restore=restore)
                state.unlink()

    def test_saved_state_appearing_during_final_status_check_never_writes_apply_or_restore(self):
        for restore in (False, True):
            with self.subTest(restore=restore):
                self.state.side_effect = None
                if restore:
                    ggm.configure_playable_network(self.playable)
                state = self.playable / "snapshots.plist"
                calls = 0
                def status(*_args):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        state.write_bytes(plistlib.dumps({"SuspendIdentifier": "saved-session"}))
                    return "stopped"
                self.state.side_effect = status
                self._assert_saved_state_refused_without_writes(restore=restore)
                self.assertEqual(calls, 2)
                state.unlink()

    def test_legacy_suspended_empty_identifier_and_saved_files_are_rejected(self):
        for filename, data in (("view.plist", plistlib.dumps({"Suspended": True})),
                               ("snapshots.plist", plistlib.dumps({"SuspendIdentifier": ""})),
                               ("session.vmss", b"saved"), ("Data/suspend.bin", b"saved")):
            with self.subTest(filename=filename):
                state = self.playable / filename
                state.write_bytes(data)
                self._assert_saved_state_refused_without_writes()
                state.unlink()

    def test_untrusted_or_invalid_saved_state_metadata_is_refused(self):
        state = self.playable / "snapshots.plist"
        for data in (b"invalid", plistlib.dumps([])):
            state.write_bytes(data)
            self._assert_saved_state_refused_without_writes()
            state.unlink()
        external = self.root / "external-state.plist"
        external.write_bytes(plistlib.dumps({}))
        state.symlink_to(external)
        self._assert_saved_state_refused_without_writes()
        state.unlink()
        state.write_bytes(plistlib.dumps({}))
        state.chmod(0o666)
        self._assert_saved_state_refused_without_writes()

    def test_historical_snapshot_and_not_suspended_legacy_state_allow_network_change(self):
        (self.playable / "snapshots.plist").write_bytes(plistlib.dumps({"Snapshots": [{"HasState": True}]}))
        (self.playable / "view.plist").write_bytes(plistlib.dumps({"Suspended": False}))
        self.assertTrue(ggm.configure_playable_network(self.playable)["configured"])
        self.assertTrue(ggm.configure_playable_network(self.playable, restore=True)["restored"])

    def test_cli_stopped_but_saved_state_is_structured_refusal_without_writes(self):
        state = self.playable / "snapshots.plist"
        state.write_bytes(plistlib.dumps({"SuspendIdentifier": "saved-session"}))
        before = (self.playable / "config.plist").read_bytes()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = ggm.main(["configure-network", "--playable", str(self.playable)])
        self.assertEqual(status, 1)
        self.assertFalse(json.loads(output.getvalue())["configured"])
        self.assertEqual((self.playable / "config.plist").read_bytes(), before)
        self.assertFalse((self.playable / ggm.NATIVE_NETWORK_BACKUP_FILENAME).exists())
        self.assertNotIn(str(self.root), output.getvalue())


class PlayableImportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="playable-import-")
        self.root = Path(self.directory.name).resolve()
        self.playable = self.root / "playable-demo.utm"
        self.vm_uuid = "33333333-3333-3333-3333-333333333333"
        make_fake_bundle(self.playable, name="playable-demo", vm_uuid=self.vm_uuid)
        self.marker = self.playable / ggm.PLAYABLE_META_FILENAME
        self.process = mock.patch.object(ggm.subprocess, "run", return_value=ggm.subprocess.CompletedProcess([], 0, "1 /sbin/launchd\n", ""))
        self.run = self.process.start()
        self.original = (self.playable / "config.plist").read_bytes()
        self.disk = (self.playable / "Data/disk-0.qcow2").read_bytes()

    def tearDown(self) -> None:
        self.process.stop()
        for p in self.playable.rglob("*"):
            if not p.is_symlink():
                p.chmod(p.stat().st_mode | 0o700)
        self.playable.chmod(0o700)
        self.directory.cleanup()

    def import_vm(self, **kwargs):
        return ggm.import_playable(self.playable, confirmed_stopped=True, **kwargs)

    def assert_refused(self, code, call=None):
        with self.assertRaises(ggm.PlayableImportError) as captured:
            (call or self.import_vm)()
        self.assertEqual(captured.exception.code, code)
        self.assertFalse(self.marker.exists())
        self.assertFalse(list(self.playable.glob(".playable-import-*")))

    def test_confirmation_is_required_without_process_or_file_side_effects(self):
        self.assert_refused("needs_confirmation", lambda: ggm.import_playable(self.playable))
        self.run.assert_not_called()
        self.assertEqual((self.playable / "config.plist").read_bytes(), self.original)

    def test_unregistered_stopped_vm_imports_private_metadata_without_engine_calls(self):
        result = self.import_vm()
        self.assertTrue(result["imported"])
        self.assertTrue(result["metadata_verified"])
        self.assertFalse(result["already_managed"])
        self.assertEqual(result["vm_uuid"], self.vm_uuid)
        self.assertEqual(self.marker.stat().st_mode & 0o777, 0o600)
        meta = json.loads(self.marker.read_text())
        self.assertEqual(meta["origin"], "explicit_stopped_import")
        self.assertEqual(meta["config_sha256_at_import"], ggm.sha256_bytes(self.original))
        self.assertNotIn(str(self.root), self.marker.read_text())
        self.assertEqual((self.playable / "config.plist").read_bytes(), self.original)
        self.assertEqual((self.playable / "Data/disk-0.qcow2").read_bytes(), self.disk)
        self.assertEqual(self.run.call_count, 2)
        for call in self.run.call_args_list:
            self.assertEqual(call.args[0], ["ps", "-axo", "pid=,comm="])

    def test_idempotent_import_preserves_original_metadata(self):
        self.import_vm()
        before = self.marker.read_bytes()
        self.assertTrue(self.import_vm()["already_managed"])
        self.assertEqual(self.marker.read_bytes(), before)

    def test_dry_run_performs_checks_without_creating_marker(self):
        result = self.import_vm(dry_run=True)
        self.assertFalse(result["imported"])
        self.assertFalse(result["metadata_verified"])
        self.assertFalse(self.marker.exists())

    def test_running_or_starting_workers_are_refused(self):
        for name in ("qemu-system-aarch64", "QEMULauncher", "QEMURenderServer", "swtpm.0"):
            with self.subTest(name=name):
                self.run.return_value.stdout = "10 /runtime/" + name + "\n"
                self.assert_refused("active_runtime")
        self.run.side_effect = [ggm.subprocess.CompletedProcess([], 0, "1 launchd\n", ""), ggm.subprocess.CompletedProcess([], 0, "10 qemu-system-aarch64\n", "")]
        self.assert_refused("active_runtime")

    def test_process_inspection_errors_fail_closed(self):
        for value in (ggm.subprocess.CompletedProcess([], 1, "1 launchd\n", "denied"), ggm.subprocess.CompletedProcess([], 0, "", ""), ggm.subprocess.CompletedProcess([], 0, "unparseable", "")):
            with self.subTest(value=value):
                self.run.return_value = value
                self.assert_refused("process_check_failed")
        for error in (OSError("unavailable"), ggm.subprocess.TimeoutExpired("ps", 15)):
            self.run.side_effect = error
            self.assert_refused("process_check_failed")

    def test_suspended_snapshots_refused_but_historical_snapshots_allowed(self):
        state = self.playable / "snapshots.plist"
        state.write_bytes(plistlib.dumps({"SuspendIdentifier": "saved-session"}))
        self.assert_refused("suspended_state")
        state.write_bytes(plistlib.dumps({"Snapshots": [{"HasState": True}]}))
        self.assertTrue(self.import_vm()["imported"])

    def test_runtime_state_and_lock_files_are_refused(self):
        for name, code in (("runtime.pid", "busy_lock"), ("runtime.lock", "busy_lock"), ("qmp.sock", "busy_lock"), ("suspend.bin", "suspended_state"), ("session.vmem", "suspended_state")):
            with self.subTest(name=name):
                state = self.playable / name
                state.write_bytes(b"state")
                self.assert_refused(code)
                state.unlink()

    def test_configuration_lock_is_nonblocking(self):
        with (self.playable / "config.plist").open("rb") as handle:
            ggm.fcntl.flock(handle, ggm.fcntl.LOCK_EX | ggm.fcntl.LOCK_NB)
            self.assert_refused("busy_lock")

    def test_uuid_backend_and_architecture_are_validated(self):
        for section, key, value in (("Information", "UUID", "invalid"), ("System", "Architecture", "x86_64"), ("System", "Architecture", []), (None, "QEMU", []), (None, "Backend", "Apple")):
            config = plistlib.loads(self.original)
            (config if section is None else config[section])[key] = value
            ggm.write_config_plist(self.playable, config)
            self.assert_refused("invalid_configuration")

    def test_fixed_system_alias_is_allowed_without_following_user_aliases(self):
        for name in ("var", "tmp"):
            canonical, alias = Path("/private") / name, Path("/") / name
            if alias.is_symlink() and alias.resolve() == canonical and self.playable.is_relative_to(canonical):
                selected = alias / self.playable.relative_to(canonical)
                result = ggm.import_playable(selected, confirmed_stopped=True)
                self.assertTrue(result["imported"])
                return
        self.skipTest("host does not use a fixed macOS temporary-directory alias")

    def test_relative_and_symbolic_bundle_paths_are_refused(self):
        self.assert_refused("unsafe_path", lambda: ggm.import_playable(Path("playable-demo.utm"), confirmed_stopped=True))
        alias = self.root / "alias.utm"
        alias.symlink_to(self.playable)
        self.assert_refused("unsafe_path", lambda: ggm.import_playable(alias, confirmed_stopped=True))
        alias.unlink()
        alias.symlink_to(self.playable, target_is_directory=True)
        self.assert_refused("unsafe_path", lambda: ggm.import_playable(alias / "../playable-demo.utm", confirmed_stopped=True))

    def test_missing_escaping_readonly_and_symlinked_disks_are_refused(self):
        for image in ("../disk.qcow2", "/disk.qcow2", "missing.qcow2"):
            config = plistlib.loads(self.original)
            config["Drive"][0]["ImageName"] = image
            ggm.write_config_plist(self.playable, config)
            self.assert_refused("unsafe_path")
        (self.playable / "config.plist").write_bytes(self.original)
        disk = self.playable / "Data/disk-0.qcow2"
        disk.chmod(0o400)
        self.assert_refused("invalid_configuration")
        disk.chmod(0o600)
        external = self.root / "external.qcow2"
        disk.rename(external)
        disk.symlink_to(external)
        self.assert_refused("unsafe_path")

    def test_readonly_config_and_symlinked_config_are_refused(self):
        config = self.playable / "config.plist"
        config.chmod(0o400)
        self.assert_refused("invalid_configuration")
        config.chmod(0o600)
        external = self.root / "external.plist"
        config.rename(external)
        config.symlink_to(external)
        self.assert_refused("invalid_configuration")

    def test_templates_cold_backups_and_explicit_protected_identity_are_refused(self):
        for name in ("golden-demo", "template-demo", "backup-demo", "vm-a"):
            config = plistlib.loads(self.original)
            config["Information"]["Name"] = name
            ggm.write_config_plist(self.playable, config)
            self.assert_refused("protected_instance")
        (self.playable / "config.plist").write_bytes(self.original)
        for keyword in ("golden", "primary"):
            self.assert_refused("protected_instance", lambda: self.import_vm(**{keyword: self.playable}))
        other = self.root / "protected.utm"
        make_fake_bundle(other, name="protected", vm_uuid=self.vm_uuid)
        self.assert_refused("protected_instance", lambda: self.import_vm(primary=other))

    def test_unknown_conflicting_public_and_ephemeral_markers_are_preserved(self):
        for value in ({}, {"schema_version": 1, "role": "other", "vm_uuid": self.vm_uuid}, {"schema_version": 1, "role": "playable_working_vm", "vm_uuid": "different"}):
            self.marker.write_text(json.dumps(value))
            self.marker.chmod(0o600)
            before = self.marker.read_bytes()
            with self.assertRaises(ggm.PlayableImportError) as captured:
                self.import_vm()
            self.assertEqual(captured.exception.code, "conflicting_metadata")
            self.assertEqual(self.marker.read_bytes(), before)
            self.marker.unlink()
        self.marker.write_text("{}")
        self.marker.chmod(0o644)
        with self.assertRaises(ggm.PlayableImportError) as captured:
            self.import_vm()
        self.assertEqual(captured.exception.code, "conflicting_metadata")
        self.marker.unlink()
        (self.playable / ggm.EPHEMERAL_META_FILENAME).write_text("{}")
        self.assert_refused("conflicting_metadata")

    def test_config_changed_during_final_process_check_is_refused(self):
        calls = 0
        def inspect():
            nonlocal calls
            calls += 1
            if calls == 2:
                config = plistlib.loads(self.original)
                config["System"]["MemorySize"] = 8192
                ggm.write_config_plist(self.playable, config)
        with mock.patch.object(ggm, "_import_check_processes", side_effect=inspect):
            self.assert_refused("config_changed")

    def test_racing_unknown_marker_is_never_overwritten_and_temporary_is_removed(self):
        original_link = os.link
        def race(*args, **kwargs):
            self.marker.write_text("unknown concurrent owner")
            return original_link(*args, **kwargs)
        with mock.patch.object(ggm.os, "link", side_effect=race):
            with self.assertRaises(ggm.PlayableImportError) as captured:
                self.import_vm()
        self.assertEqual(captured.exception.code, "conflicting_metadata")
        self.assertEqual(self.marker.read_text(), "unknown concurrent owner")
        self.assertFalse(list(self.playable.glob(".playable-import-*")))

    def test_temporary_name_collision_never_removes_an_unknown_file(self):
        temporary = self.playable / ".playable-import-collision"
        temporary.write_text("unknown existing file")
        with mock.patch.object(ggm.secrets, "token_hex", return_value="collision"):
            with self.assertRaises(FileExistsError):
                self.import_vm()
        self.assertEqual(temporary.read_text(), "unknown existing file")
        self.assertFalse(self.marker.exists())

    def test_symlink_metadata_and_hardlinked_config_are_refused(self):
        external = self.root / "external.json"
        external.write_text("{}")
        self.marker.symlink_to(external)
        with self.assertRaises(ggm.PlayableImportError) as captured:
            self.import_vm()
        self.assertEqual(captured.exception.code, "unsafe_path")
        self.assertEqual(external.read_text(), "{}")
        self.marker.unlink()
        ggm.os.link(self.playable / "config.plist", self.root / "alias.plist")
        self.assert_refused("invalid_configuration")

    def test_cli_errors_are_structured_and_never_echo_private_paths(self):
        for arguments, code in (([], "needs_confirmation"), (["--confirmed-stopped"], "unsafe_path")):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = ggm.main(["import-playable", "--playable", str(self.root / "missing.utm")] + arguments)
            self.assertEqual(status, 1)
            self.assertEqual(json.loads(output.getvalue())["error_code"], code)
            self.assertNotIn(str(self.root), output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())


if __name__ == "__main__":
    unittest.main()
