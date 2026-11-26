"""Evidence boundaries for commercial rendering diagnostics. @DNPMBHC."""
import json
import unittest

from bench_real3d_wine_diagnostics import bind_launcher_architectures, summarize_log


class WineDiagnosticsTests(unittest.TestCase):
    def test_private_lines_are_not_exported_and_debug_prefix_is_not_a_pid(self):
        secret = "private-token-value"
        log = (
            f"Authorization: Bearer {secret}\n"
            f'0024:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\d3d11.dll" '
            f"at 00007fff12340000: builtin {secret}\n"
            f"https://service.invalid/?access_token={secret}\n"
        )
        report = summarize_log(log)
        self.assertNotIn(secret, json.dumps(report))
        self.assertNotIn("00007fff12340000", json.dumps(report))
        self.assertEqual(report["graphics_module_loads"][0]["library"], "d3d11.dll")
        self.assertFalse(report["wine_debug_prefix_pid_binding"])
        self.assertFalse(report["loader_tag_establishes_backend_byte_identity"])

    def test_gpu_child_exit_and_first_chance_exception_are_separate(self):
        report = summarize_log(
            "GPU process exited unexpectedly: exit_code=6\n"
            "trace:seh:dispatch_exception code=c0000005\n"
            "Unhandled exception\n"
        )
        self.assertEqual(report["chromium_gpu_process_exit_codes"], [6])
        self.assertEqual(report["exception_code_counts"], {"c0000005": 1})
        self.assertEqual(report["unhandled_exception_markers"], 1)
        self.assertEqual(report["disable_gpu_argument_honored"], "not_established_by_log_metadata")

    def test_architecture_binding_rejects_missing_invalid_and_conflicting_headers(self):
        digest = "a" * 64
        expected = {"launcher-001": digest}
        for files in ([], [{"sha256": digest, "pe_valid": False}], [
            {"sha256": digest, "pe_valid": True, "pe_machine": "0x014c"},
            {"sha256": digest, "pe_valid": True, "pe_machine": "0x8664"},
        ]):
            report = bind_launcher_architectures(expected, files)[0]
            self.assertFalse(report["pe_binding_complete"])
            self.assertIsNone(report["pe_machine"])

    def test_exact_sha_binding_does_not_claim_runtime_identity(self):
        report = bind_launcher_architectures({"launcher-001": "a" * 64}, [
            {"sha256": "a" * 64, "pe_valid": True, "pe_machine": "0x8664"},
            {"sha256": "b" * 64, "pe_valid": True, "pe_machine": "0x014c"},
        ])[0]
        self.assertTrue(report["pe_binding_complete"])
        self.assertEqual(report["pe_machine"], "0x8664")
        self.assertFalse(report["actual_runtime_process_machine_verified"])


if __name__ == "__main__":
    unittest.main()
