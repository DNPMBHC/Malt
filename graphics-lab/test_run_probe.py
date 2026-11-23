import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class RunProbeTests(unittest.TestCase):
    def test_records_process_start_to_ready_without_saving_command(self):
        script = Path(__file__).with_name("run_probe.py")
        with tempfile.TemporaryDirectory() as scratch:
            report = Path(scratch) / "timing.json"
            child_code = (
                "import sys,time; time.sleep(.03); "
                "print('probe_ready_ms=4.500', file=sys.stderr, flush=True)"
            )
            result = subprocess.run(
                [sys.executable, str(script), "--json", str(report), "--",
                 sys.executable, "-u", "-c", child_code],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(report.read_text(encoding="utf-8"))
            self.assertTrue(data["ready"])
            self.assertEqual(data["probe_internal_initialization_ms"], 4.5)
            self.assertGreaterEqual(data["process_start_to_d3d_ready_ms"], 25)
            self.assertNotIn("command", data)


if __name__ == "__main__":
    unittest.main()
