#!/usr/bin/env python3
"""Unprivileged helper contract checks. Owner: @DNPMBHC."""
from pathlib import Path
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class BridgePackagingContractTests(unittest.TestCase):
    def test_bundled_daemon_uses_fixed_relative_program_and_private_socket(self) -> None:
        with (HERE / "SMAppService.plist").open("rb") as handle:
            value = plistlib.load(handle)
        self.assertEqual(value["Label"], "com.malt.vmnet-bridge")
        self.assertEqual(value["BundleProgram"], "Contents/Library/HelperTools/malt-vmnet-bridge")
        self.assertEqual(value["UserName"], "root")
        self.assertEqual(value["ProgramArguments"], [
            "malt-vmnet-bridge", "--socket", "/var/run/malt-vmnet-bridge.sock", "--mode", "0600"
        ])
        self.assertNotIn("Program", value)

    def test_maintenance_script_syntax_and_fixed_socket_rejection(self) -> None:
        script = HERE / "install_vmnet_bridge.sh"
        checked = subprocess.run(["bash", "-n", str(script)], capture_output=True)
        self.assertEqual(checked.returncode, 0)
        rejected = subprocess.run(["bash", str(script), "--status", "--socket", "/tmp/untrusted.sock"], capture_output=True)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn(b"fixed system socket", rejected.stderr)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("clang"), "requires macOS SDK")
class BridgeUnprivilegedRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="network-helper-")
        cls.binary = Path(cls.temporary.name) / "network-helper"
        built = subprocess.run([
            "clang", "-O2", "-Wall", "-Wextra", "-Werror", str(HERE / "malt_vmnet_bridge.c"),
            "-framework", "vmnet", "-framework", "CoreFoundation", "-o", str(cls.binary)
        ], capture_output=True, text=True)
        if built.returncode != 0:
            raise AssertionError("Native bridge compilation failed")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def run_helper(self, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.binary), *arguments], capture_output=True, text=True, timeout=10)

    def test_self_check_links_vmnet_without_network_or_privilege(self) -> None:
        result = self.run_helper("--self-check")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(json.loads(result.stdout)["vmnet_symbols_linked"])

    def test_rejects_writable_socket_mode(self) -> None:
        self.assertEqual(self.run_helper("--mode", "0666").returncode, 2)

    def test_rejects_arbitrary_socket_path_before_privilege(self) -> None:
        self.assertEqual(self.run_helper("--socket", "/tmp/untrusted.sock").returncode, 2)

    @unittest.skipIf(os.geteuid() == 0, "never start a privileged helper during tests")
    def test_nonroot_cannot_start_daemon(self) -> None:
        result = self.run_helper()
        self.assertEqual(result.returncode, 77)
        self.assertIn("register and approve", result.stderr)


if __name__ == "__main__":
    unittest.main()
