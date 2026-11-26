#!/usr/bin/env python3
"""Safety boundary tests without VM or external-volume actions. Owner: @DNPMBHC."""
import importlib.util
import json
import plistlib
import subprocess
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("clone_tools", Path(__file__).with_name("guest_clone_control.py"))
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)


class CloneBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="guest-shell-clone-tests-")
        self.root = Path(self.directory.name).resolve()
        (self.root / "Data").mkdir()
        self.disk = self.root / "Data/disk.qcow2"
        header = bytearray(104)
        header[:8] = b"QFI\xfb" + struct.pack(">I", 3)
        self.disk.write_bytes(header)
        self.config = {"Drive": [{"ImageName": "disk.qcow2", "ReadOnly": False}]}

    def tearDown(self):
        self.directory.cleanup()

    def test_contained_disk_without_backing_chain(self):
        self.assertEqual(clone.validate_disks(self.root, self.config), [self.disk])

    def test_relative_escape_rejected(self):
        self.config["Drive"][0]["ImageName"] = "../disk.qcow2"
        with self.assertRaisesRegex(RuntimeError, "drive_path_escape_rejected"):
            clone.validate_disks(self.root, self.config)

    def test_backing_chain_rejected(self):
        header = bytearray(self.disk.read_bytes())
        header[8:20] = struct.pack(">QI", 4096, 16)
        self.disk.write_bytes(header)
        with self.assertRaisesRegex(RuntimeError, "qcow_backing_chain_rejected"):
            clone.validate_disks(self.root, self.config)

    def test_dirty_corrupt_and_external_data_rejected(self):
        for flag in (1, 2, 4):
            with self.subTest(flag=flag):
                header = bytearray(self.disk.read_bytes())
                header[72:80] = struct.pack(">Q", flag)
                self.disk.write_bytes(header)
                with self.assertRaisesRegex(RuntimeError, "qcow_dirty_corrupt_or_external_data_rejected"):
                    clone.validate_disks(self.root, self.config)

    def test_disk_symlink_rejected(self):
        self.disk.rename(self.root / "disk.qcow2")
        self.disk.symlink_to(self.root / "disk.qcow2")
        with self.assertRaisesRegex(RuntimeError, "disk_not_contained"):
            clone.validate_disks(self.root, self.config)

    def test_held_lease_rejected_before_inventory_or_clone(self):
        (self.root / "vm-lease.json").write_text(json.dumps({"status": "held"}))
        with patch.object(clone, "A_EVIDENCE", self.root), patch.object(clone, "source_bundle") as source:
            with self.assertRaisesRegex(RuntimeError, "phase5a_lease_not_released"):
                clone.prepare()
            source.assert_not_called()

    def test_own_clone_returns_controller_canonical_uppercase_identifier(self):
        identifier = "abcdefab-1234-5678-9abc-abcdefabcdef"
        config = {"Information": {"UUID": identifier.upper()}}
        lease = {"owner": "@DNPMBHC", "clone_alias": "test-vm-p5c-0123456789ab.utm",
                 "clone_identifier": identifier, "created_at": "2026-11-24T04:00:00Z",
                 "primary_identifier_sha256": "0" * 64, "status": "held", "clone_registered": True}
        (self.root / "config.plist").write_bytes(plistlib.dumps(config))
        (self.root / "clone-owner.json").write_text(json.dumps(
            {"owner": "@DNPMBHC", "clone_identifier": identifier, "created_at": lease["created_at"]}))
        with patch.object(clone, "bundles", return_value=[self.root]), \
                patch.object(clone, "external_apfs", return_value={}):
            renamed = self.root / lease["clone_alias"]
            with patch.object(clone, "bundles", return_value=[renamed]):
                renamed.mkdir()
                (renamed / "config.plist").write_bytes((self.root / "config.plist").read_bytes())
                (renamed / "clone-owner.json").write_bytes((self.root / "clone-owner.json").read_bytes())
                _, actual = clone.own_clone(lease)
        self.assertEqual(actual, identifier.upper())

    def test_primary_name_cannot_enter_cleanup(self):
        with self.assertRaisesRegex(RuntimeError, "own_clone_lease_invalid"):
            clone.own_clone({"owner": "@DNPMBHC", "clone_alias": "vm-a.utm"})

    def test_primary_readonly_handle_is_allowed_but_writable_and_qemu_handles_are_rejected(self):
        (self.root / "config.plist").write_bytes(plistlib.dumps(
            {"Information": {"UUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}}))
        for output, allowed in [(b"p10\ncFinder\nf4\nar\n", True),
                                (b"p11\ncFinder\nf4\nau\n", False),
                                (b"p12\ncqemu-system-aarch64\nf4\nar\n", False)]:
            response = subprocess.CompletedProcess([], 0, output, b"")
            with self.subTest(allowed=allowed), patch.object(clone, "controller", return_value=Path("/tmp/test-controller")), \
                    patch.object(clone, "command", side_effect=[b"", b""]), \
                    patch.object(clone.subprocess, "run", return_value=response):
                if allowed:
                    self.assertEqual(clone.assert_no_source_control_process(self.root),
                                     "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
                else:
                    with self.assertRaisesRegex(RuntimeError, "primary_writable_or_qemu_handle_detected"):
                        clone.assert_no_source_control_process(self.root)

    def test_cleanup_requests_guest_shutdown_before_deleting_only_owned_clone(self):
        identifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        owned = self.root / "owned.utm"
        owned.mkdir()
        (owned / "config.plist").write_bytes(plistlib.dumps({"Information": {"UUID": identifier}}))
        lease_path = self.root / "vm-lease.json"
        lease_path.write_text(json.dumps({"owner": "@DNPMBHC", "status": "held"}))
        baseline = {"files": [{"size_bytes": 1, "mtime_ns": 2, "sha256": "a"}]}
        (self.root / "own-source-before.json").write_text(json.dumps(baseline))
        calls = []
        requested = False
        deleted = False

        def command(arguments, timeout=30):
            nonlocal deleted
            calls.append(arguments)
            if arguments[1] == "list": return b"" if deleted else identifier.encode()
            if arguments[1] == "status": return b"stopped" if requested else b"started"
            if arguments[1] == "delete": deleted = True
            return b""

        def request(arguments, **kwargs):
            nonlocal requested
            calls.append(arguments)
            self.assertEqual(arguments, ["/tmp/test-controller", "stop", "--hide", identifier, "--request"])
            requested = True
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with patch.object(clone, "LEASE", lease_path), patch.object(clone, "EVIDENCE", self.root), \
                patch.object(clone, "own_clone", return_value=(owned, identifier)), \
                patch.object(clone, "controller", return_value=Path("/tmp/test-controller")), \
                patch.object(clone, "command", side_effect=command), \
                patch.object(clone.subprocess, "run", side_effect=request), \
                patch.object(clone, "source_bundle", return_value=(self.root, baseline)), \
                patch.object(clone, "fingerprint", return_value=baseline):
            result = clone.cleanup()
        self.assertTrue(result["clone_deleted"])
        self.assertFalse(owned.exists())
        self.assertTrue(self.disk.exists())
        self.assertLess(next(i for i, call in enumerate(calls) if "--request" in call),
                        next(i for i, call in enumerate(calls) if "delete" in call))
        self.assertNotIn("--force", [value for call in calls for value in call])


if __name__ == "__main__":
    unittest.main()
