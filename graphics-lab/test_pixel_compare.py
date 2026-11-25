import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import pixel_compare


class PixelCompareTests(unittest.TestCase):
    def test_exact_rgba_preserves_frame_hashes(self):
        rgba = bytes([0, 32, 255, 255, 10, 20, 30, 0])
        result = pixel_compare.compare_rgba(rgba, rgba, 2, 1)
        self.assertTrue(result["passed"])
        self.assertEqual(result["max_channel_error"], 0)
        self.assertEqual(result["over_threshold_pixels"], 0)
        self.assertEqual(result["over_threshold_channels"], 0)
        self.assertIsNone(result["first_failure"])
        expected = hashlib.sha256(rgba).hexdigest()
        self.assertEqual(result["reference_sha256"], expected)
        self.assertEqual(result["actual_sha256"], expected)

    def test_one_lsb_on_each_channel_is_accepted(self):
        reference = bytes([0, 255, 127, 255, 128, 0, 255, 1])
        actual = bytes([1, 254, 126, 254, 129, 1, 254, 0])
        result = pixel_compare.compare_rgba(reference, actual, 2, 1)
        self.assertTrue(result["passed"])
        self.assertEqual(result["max_channel_error"], 1)
        self.assertEqual(result["over_threshold_pixels"], 0)
        self.assertEqual(result["over_threshold_channels"], 0)
        self.assertNotEqual(result["reference_sha256"], result["actual_sha256"])

    def test_alpha_is_compared_and_failure_coordinates_are_top_left(self):
        reference = bytes([20, 40, 60, 255] * 6)
        actual = bytearray(reference)
        actual[(1 * 3 + 2) * 4 + 3] = 253
        result = pixel_compare.compare_rgba(reference, bytes(actual), 3, 2)
        self.assertFalse(result["passed"])
        self.assertEqual(result["max_channel_error"], 2)
        self.assertEqual(result["over_threshold_pixels"], 1)
        self.assertEqual(result["over_threshold_channels"], 1)
        self.assertEqual(result["first_failure"], {
            "x": 2, "y": 1, "channel": "A", "reference": 255,
            "actual": 253, "error": 2,
        })

    def test_pixel_count_does_not_double_count_multiple_bad_channels(self):
        reference = bytes([100] * 12)
        actual = bytes([100, 100, 100, 100, 102, 98, 100, 100, 100, 100, 104, 100])
        result = pixel_compare.compare_rgba(reference, actual, 3, 1)
        self.assertFalse(result["passed"])
        self.assertEqual(result["over_threshold_channels"], 3)
        self.assertEqual(result["over_threshold_pixels"], 2)
        self.assertEqual(result["max_channel_error"], 4)
        self.assertEqual(result["first_failure"]["x"], 1)
        self.assertEqual(result["first_failure"]["channel"], "R")

    def test_zero_tolerance_requires_exact_frame(self):
        result = pixel_compare.compare_rgba(bytes([0, 0, 0, 255]), bytes([1, 0, 0, 255]), 1, 1, 0)
        self.assertFalse(result["passed"])
        self.assertEqual(result["over_threshold_channels"], 1)

    def test_rejects_invalid_dimensions_lengths_and_tolerance(self):
        rgba = bytes(4)
        cases = [
            (rgba, rgba, 0, 1, 1), (rgba, rgba, 1, -1, 1),
            (rgba, rgba, True, 1, 1), (rgba, rgba, 1, 1.0, 1),
            (rgba[:-1], rgba, 1, 1, 1), (rgba, rgba + b"x", 1, 1, 1),
            (rgba, rgba, 1, 1, -1), (rgba, rgba, 1, 1, 256),
            (rgba, rgba, 1, 1, 1.0), (rgba, rgba, 1, 1, True),
        ]
        for args in cases:
            with self.subTest(args=args):
                with self.assertRaises(ValueError):
                    pixel_compare.compare_rgba(*args)

    def test_cli_exit_codes_and_json_are_consistent(self):
        script = Path(pixel_compare.__file__).resolve()
        scratch_root = Path(__file__).resolve().parent / "build" / "test-scratch"
        scratch_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch_root) as scratch:
            directory = Path(scratch)
            reference = directory / "reference.rgba"
            actual = directory / "actual.rgba"
            report = directory / "comparison.json"
            reference.write_bytes(bytes([10, 20, 30, 255]))
            args = [sys.executable, str(script), "--reference", str(reference),
                    "--actual", str(actual), "--width", "1", "--height", "1",
                    "--output-json", str(report)]
            for image, code, passed in [(bytes([11, 19, 31, 254]), 0, True),
                                        (bytes([12, 20, 30, 255]), 1, False)]:
                actual.write_bytes(image)
                proc = subprocess.run(args, capture_output=True, text=True, env=os.environ.copy())
                self.assertEqual(proc.returncode, code, "pixel comparison CLI returned wrong status")
                self.assertEqual(json.loads(report.read_text())["passed"], passed)
            actual.write_bytes(b"short")
            proc = subprocess.run(args, capture_output=True, text=True, env=os.environ.copy())
            self.assertEqual(proc.returncode, 2, "pixel comparison CLI must reject truncated or oversized input")


if __name__ == "__main__":
    unittest.main()
