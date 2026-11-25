import json
import tempfile
import unittest
from pathlib import Path

import bench_real3d_wine_launcher as launcher


class WineLauncherHelperTests(unittest.TestCase):
    def test_windows_path_maps_owned_drives(self):
        runtime = Path("/owned/runtime")
        self.assertEqual(launcher.to_windows_path(runtime, runtime / "data/a/b.exe"), "R:\\a\\b.exe")
        self.assertEqual(launcher.to_windows_path(runtime, runtime / "prefix/drive_c/x/y.exe"),
                         "C:\\x\\y.exe")

    def test_only_sandbox_variants_are_flagged(self):
        flagged = {name for name in launcher.VARIANTS if name in launcher.SANDBOX_REDUCING}
        self.assertEqual(flagged, {"gpu-sandbox-off", "no-sandbox"})
        self.assertEqual(launcher.VARIANTS["baseline"], [])
        for name, flags in launcher.VARIANTS.items():
            if name not in launcher.SANDBOX_REDUCING:
                self.assertFalse(any("sandbox" in flag for flag in flags))

    def test_summary_counts_categories_without_raw_text(self):
        text = "\n".join(["[1:2:ERROR:gpu_process_host.cc] GPU process exited unexpectedly",
                          "wine: Unhandled page fault on read access",
                          "secret-user-line"])
        summary = launcher.summarize(text)
        self.assertEqual(summary["phrase_counts"]["gpu_process_crash"], 1)
        self.assertEqual(summary["phrase_counts"]["unhandled_exception"], 1)
        self.assertFalse(summary["raw_content_exported"])
        self.assertNotIn("secret-user-line", json.dumps(summary))

    def test_owned_rejects_foreign_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ownership.json").write_text(json.dumps({"phase": "p5-a"}))
            with self.assertRaises(RuntimeError):
                launcher.owned(root)
            (root / "ownership.json").write_text(json.dumps({"phase": "p5-a-wine"}))
            self.assertEqual(launcher.owned(root), root)


if __name__ == "__main__":
    unittest.main()
