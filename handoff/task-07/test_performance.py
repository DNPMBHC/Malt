import copy
import json
import math
import pathlib
import subprocess
import sys
import tempfile
import unittest

from performance import SampleError, compare_samples, summarize, validate_sample


def sample():
    runs = []
    for index, startup in enumerate(("cold", "cold", "cold", "hot", "hot", "hot")):
        runs.append({
            "startup": startup, "startupMs": 100 + index,
            "frameTimesMs": [10 + index, 11 + index, 12 + index, 14 + index],
            "inputLatencyMs": 8 + index, "cpuPercent": 40 + index,
            "gpuPercent": 55 + index, "memoryMiB": 1024 + index,
            "powerW": 20 + index, "thermalState": "nominal", "missing": {}})
    return {"schema": "performance-sample-v1",
            "metadata": {
                "host": {"machineId": "host-a", "chip": "chip-a", "os": "os-a",
                         "sdk": "sdk-a", "architecture": "arm64"},
                "guest": {"os": "guest-os-a", "architecture": "arm64"},
                "vm": "vm-a", "backend": "backend-a", "driver": "driver-a",
                "gameVersionRegion": {"version": "version-a", "region": "region-a"},
                "resolution": {"width": 1920, "height": 1080},
                "quality": "high", "scene": "scene-a"}, "runs": runs}


class PerformanceTests(unittest.TestCase):
    def test_per_run_and_repeat_variation(self):
        metrics = summarize(sample())
        self.assertEqual(metrics["runs"], 6)
        first = metrics["perRun"][0]
        self.assertEqual(first["startupMs"]["value"], 100)
        self.assertEqual(first["frameTimeMs"], {"samples": 4, "p50": 11.5, "p95": 13.7, "p99": 13.94})
        cold = metrics["startup"]["cold"]
        self.assertEqual(cold["frameTimeMs"]["p50"]["median"], 12.5)
        self.assertEqual((cold["startupMs"]["min"], cold["startupMs"]["max"]), (100, 102))
        self.assertAlmostEqual(cold["startupMs"]["stddev"], 0.816497)
        self.assertNotIn("overall", metrics)

    def test_partial_missing_keeps_per_run_null_and_coverage(self):
        value = sample()
        value["runs"][0]["powerW"] = None
        value["runs"][0]["missing"] = {"powerW": "sensor_unavailable"}
        metrics = summarize(value)
        self.assertEqual(metrics["perRun"][0]["powerW"], {"value": None, "reason": "sensor_unavailable"})
        power = metrics["startup"]["cold"]["powerW"]
        self.assertEqual(power["median"], 21.5)
        self.assertEqual((power["samples"], power["missing"]), (2, 1))
        self.assertEqual(power["reason"], "partial_missing")
        compared = compare_samples(sample(), value)
        self.assertEqual(compared["metrics"]["delta"]["cold"]["powerW"], {"value": None, "reason": "incomplete_measurement"})

    def test_all_missing_and_thermal_reasons(self):
        value = sample()
        for run in value["runs"]:
            run["startupMs"] = run["thermalState"] = None
            run["missing"] = {"startupMs": "not_collected", "thermalState": "sensor_unavailable"}
        metrics = summarize(value)
        self.assertIsNone(metrics["startup"]["hot"]["startupMs"]["median"])
        self.assertEqual(metrics["startup"]["hot"]["thermalState"]["reason"], "not_collected")
        self.assertEqual(metrics["perRun"][0]["thermalState"]["reason"], "sensor_unavailable")

    def test_missing_rules_reject_blank_absent_and_inconsistent_reasons(self):
        for reason in (None, "", "  ", 1):
            with self.subTest(reason=reason):
                value = sample()
                value["runs"][0]["thermalState"] = None
                value["runs"][0]["missing"] = {"thermalState": reason}
                with self.assertRaises(SampleError):
                    validate_sample(value)
        value = sample()
        value["runs"][0]["missing"] = {"powerW": "not_collected"}
        with self.assertRaises(SampleError):
            validate_sample(value)

    def test_nonfinite_negative_zero_frame_and_empty_frames_rejected(self):
        for metric in ("startupMs", "inputLatencyMs", "cpuPercent", "gpuPercent", "memoryMiB", "powerW"):
            for bad in (math.nan, math.inf, -math.inf, -1, True):
                with self.subTest(metric=metric, bad=str(bad)):
                    value = sample()
                    value["runs"][0][metric] = bad
                    with self.assertRaises(SampleError):
                        validate_sample(value)
        for frames in ([], [0], [-1], [math.nan], [math.inf], [None]):
            with self.subTest(frames=str(frames)):
                value = sample()
                value["runs"][0]["frameTimesMs"] = frames
                with self.assertRaises(SampleError):
                    validate_sample(value)

    def test_metadata_requires_nonempty_host_and_guest_fields(self):
        for section, keys in (("host", ("machineId", "chip", "os", "sdk", "architecture")), ("guest", ("os", "architecture"))):
            for key in keys:
                with self.subTest(section=section, key=key):
                    value = sample()
                    del value["metadata"][section][key]
                    with self.assertRaises(SampleError):
                        validate_sample(value)
                    value = sample()
                    value["metadata"][section][key] = " "
                    with self.assertRaises(SampleError):
                        validate_sample(value)
        for replacement in ("", None, {}, []):
            value = sample()
            value["metadata"]["scene"] = replacement
            with self.assertRaises(SampleError):
                validate_sample(value)

    def test_every_metadata_section_must_match(self):
        baseline = sample()
        for key in baseline["metadata"]:
            with self.subTest(key=key):
                candidate = copy.deepcopy(baseline)
                if key == "resolution":
                    candidate["metadata"][key]["width"] += 1
                elif isinstance(candidate["metadata"][key], dict):
                    first_key = next(iter(candidate["metadata"][key]))
                    candidate["metadata"][key][first_key] = "changed"
                else:
                    candidate["metadata"][key] = "changed"
                with self.assertRaises(SampleError):
                    compare_samples(baseline, candidate)

    def test_repeats_apply_independently_to_cold_and_hot(self):
        for count in (0, 1, 2, 4):
            value = sample()
            value["runs"] = value["runs"][:count]
            with self.assertRaises(SampleError):
                validate_sample(value)
        value = sample()
        value["runs"] = value["runs"][:3]
        self.assertEqual(validate_sample(value)["runs"][0]["startup"], "cold")

    def test_comparison_keeps_cold_hot_separate_and_matching_counts(self):
        baseline, candidate = sample(), sample()
        for run in candidate["runs"][:3]:
            run["frameTimesMs"] = [1, 2, 3, 4]
            run["startupMs"] -= 10
        delta = compare_samples(baseline, candidate)["metrics"]["delta"]
        self.assertEqual(set(delta), {"cold", "hot"})
        self.assertLess(delta["cold"]["frameTimeMs"]["p50"]["value"], 0)
        self.assertEqual(delta["hot"]["frameTimeMs"]["p50"]["value"], 0)
        self.assertEqual(delta["cold"]["startupMs"]["value"], -10)
        candidate["runs"].append(copy.deepcopy(candidate["runs"][0]))
        with self.assertRaises(SampleError):
            compare_samples(baseline, candidate)

    def test_thermal_state_order_is_deterministic(self):
        value = sample()
        for run, thermal in zip(value["runs"][:3], ("critical", "nominal", "serious")):
            run["thermalState"] = thermal
        self.assertEqual(summarize(value)["startup"]["cold"]["thermalState"]["observed"], ["nominal", "serious", "critical"])

    def test_cli_does_not_echo_metadata_paths_or_free_reasons(self):
        executable = pathlib.Path(__file__).with_name("performance.py")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sensitive-marker.json"
            value = sample()
            value["metadata"]["host"]["machineId"] = "sensitive-marker"
            value["runs"][0]["powerW"] = None
            value["runs"][0]["missing"] = {"powerW": "sensitive-marker"}
            path.write_text(json.dumps(value), encoding="utf-8")
            for command in (("validate", str(path)), ("compare", str(path), str(path))):
                result = subprocess.run([sys.executable, str(executable), *command], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(set(json.loads(result.stdout)), {"schema", "metrics"})
                self.assertNotIn("sensitive-marker", result.stdout + result.stderr)
            output = summarize(value)
            self.assertEqual(output["perRun"][0]["powerW"]["reason"], "redacted_reason")
            path.write_text('{"schema":NaN}', encoding="utf-8")
            for command in (("validate", str(path)), ("validate", str(path)+"missing"), ("sensitive-marker",)):
                result = subprocess.run([sys.executable, str(executable), *command], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("sensitive-marker", result.stdout + result.stderr)
                self.assertEqual(set(json.loads(result.stderr)), {"schema", "metrics"})


if __name__ == "__main__":
    unittest.main()
