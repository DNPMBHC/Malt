import copy
import unittest

import run_guest_acceptance as acceptance


MODES = ("direct-present", "pixel-readback", "command-only")
MISSING = object()


def valid_acceptance():
    cpp, probe, swift = "a" * 64, "b" * 64, "c" * 64
    digests = {"d3d11_probe_cpp": cpp, "d3d11_probe_exe": probe, "metal_host_swift": swift}
    adapter = {"adapter_description": "adapter-a", "vendor_id": 0x1414,
               "device_id": 0x8C, "adapter_flags": 2, "adapter_software_flag": True,
               "selected_feature_level": "11_0", "windows_session_id": 2,
               "requested_driver_type": "hardware"}
    files = {name: {"file": "acceptance-inputs/" + name, "sha256": digest}
             for name, digest in (("d3d11_probe.cpp", cpp), ("build/d3d11_probe.exe", probe),
                                  ("metal_host.swift", swift))}
    m0 = {"guest_collected": True, "runs": [{"environment": "windows-guest",
          "fingerprint": copy.deepcopy(adapter), "probe_source_sha256": cpp,
          "probe_binary_sha256": probe}],
          "input_artifacts": {"d3d11_probe.cpp": {"sha256": cpp}, "d3d11_probe.exe": {"sha256": probe}}}
    cases = []
    for pattern, sequence in (("legacy", 0), ("seeded", 0), ("seeded", 30), ("seeded", 31)):
        reference = dict(adapter, requested_driver_type="warp")
        cases.append({"pattern": pattern, "frame_sequence": sequence,
                      "reference": "actual Guest D3D11 software rendering",
                      "actual": "actual Apple M4 Metal render target",
                      "reference_adapter": reference, "replay_adapter": copy.deepcopy(adapter),
                      "source_digests": copy.deepcopy(digests),
                      "comparison": {"passed": True, "max_channel_error": 0, "compared_pixels": 1280 * 720}})
    pixels = {"passed": True, "complete": True, "performance_measurement": False,
              "windows_session_id": 2, "probe_binary_sha256": probe,
              "source_digests": copy.deepcopy(digests), "cases": cases}
    runs = [{"mode": mode, "round": round_index, "fingerprint": copy.deepcopy(adapter),
             "completion": {"measured_frames": 300}, "performance_measurement": True,
             "source_digests": copy.deepcopy(digests)}
            for mode in MODES for round_index in (1, 2, 3)]
    performance = {"complete": True, "performance_measurement": True, "windows_session_id": 2,
                   "probe_binary_sha256": probe, "runs": runs,
                   "workload": {"width": 1280, "height": 720, "commands": 16,
                                "resource_bytes": 65536, "frames": 300, "warmup": 60,
                                "rounds": 3, "command_every": 30, "resource_every": 30,
                                "resource_pattern": "legacy"},
                   "comparison": {mode: {"rounds": 3, "measured_frames": 900,
                                         "frame_interval_ms": {"sample_count": 897}}
                                  for mode in MODES}}
    return {"m0": m0, "pixels": pixels, "performance": performance, "files": files, "session": 2}


class AcceptanceManifestAuditTests(unittest.TestCase):
    def assert_rejected(self, path, value):
        state = valid_acceptance()
        target = state
        for key in path[:-1]:
            target = target[key]
        if value is MISSING:
            del target[path[-1]]
        else:
            target[path[-1]] = value
        with self.assertRaises((RuntimeError, KeyError, TypeError)):
            acceptance.validate_acceptance_manifests(**state)

    def test_complete_nine_run_four_case_acceptance_passes_without_mutating_inputs(self):
        state = valid_acceptance()
        before = copy.deepcopy(state)
        result = acceptance.validate_acceptance_manifests(**state)
        self.assertEqual(result, state["m0"]["runs"][0]["fingerprint"])
        self.assertEqual(state, before)

    def test_run_and_pixel_case_order_does_not_change_acceptance(self):
        state = valid_acceptance()
        state["performance"]["runs"].reverse()
        state["pixels"]["cases"].reverse()
        self.assertEqual(acceptance.validate_acceptance_manifests(**state),
                         state["m0"]["runs"][0]["fingerprint"])

    def test_missing_or_incomplete_stage_flags_are_rejected(self):
        for path in (("m0", "guest_collected"), ("pixels", "passed"),
                     ("pixels", "complete"), ("performance", "complete")):
            for value in (MISSING, False):
                with self.subTest(path=path, missing=value is MISSING):
                    self.assert_rejected(path, value)

    def test_correctness_and_performance_scopes_cannot_be_contradictory(self):
        for path, values in ((("pixels", "performance_measurement"), (MISSING, True, 0)),
                             (("performance", "performance_measurement"), (MISSING, False, 1))):
            for value in values:
                with self.subTest(path=path, value=value is MISSING if value is MISSING else value):
                    self.assert_rejected(path, value)

    def test_exactly_one_actual_guest_fingerprint_is_required(self):
        guest = valid_acceptance()["m0"]["runs"][0]
        for runs in ([], [dict(guest, environment="host-wine")], [guest, copy.deepcopy(guest)]):
            with self.subTest(run_count=len(runs)):
                self.assert_rejected(("m0", "runs"), runs)

    def test_stage_session_and_hardware_request_must_match(self):
        changes = ((("m0", "runs", 0, "fingerprint", "windows_session_id"), 3),
                   (("m0", "runs", 0, "fingerprint", "requested_driver_type"), "warp"),
                   (("pixels", "windows_session_id"), 3),
                   (("performance", "windows_session_id"), 3),
                   (("session",), 3))
        for path, value in changes:
            with self.subTest(path=path):
                self.assert_rejected(path, value)

    def test_probe_execution_and_m0_archive_digests_must_match_frozen_inputs(self):
        paths = (("m0", "runs", 0, "probe_source_sha256"),
                 ("m0", "runs", 0, "probe_binary_sha256"),
                 ("pixels", "probe_binary_sha256"), ("performance", "probe_binary_sha256"),
                 ("m0", "input_artifacts", "d3d11_probe.cpp", "sha256"),
                 ("m0", "input_artifacts", "d3d11_probe.exe", "sha256"))
        for path in paths:
            with self.subTest(path=path):
                self.assert_rejected(path, "d" * 64)

    def test_cpp_probe_and_metal_digests_are_bound_across_render_stages(self):
        for path in (("pixels", "source_digests"),
                     ("pixels", "cases", 0, "source_digests"),
                     ("pixels", "cases", 3, "source_digests"),
                     ("performance", "runs", 0, "source_digests"),
                     ("performance", "runs", 8, "source_digests")):
            for key in ("d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift"):
                with self.subTest(path=path, key=key):
                    self.assert_rejected((*path, key), "d" * 64)

    def test_changed_frozen_cpp_probe_or_metal_digest_is_rejected(self):
        for name in ("d3d11_probe.cpp", "build/d3d11_probe.exe", "metal_host.swift"):
            with self.subTest(input=name):
                self.assert_rejected(("files", name, "sha256"), "d" * 64)

    def test_missing_required_nested_evidence_is_rejected(self):
        paths = (("m0", "runs", 0, "fingerprint"),
                 ("m0", "input_artifacts", "d3d11_probe.exe"),
                 ("files", "metal_host.swift"), ("pixels", "cases"),
                 ("performance", "runs", 8, "completion"),
                 ("performance", "comparison", "command-only"))
        for path in paths:
            with self.subTest(path=path):
                self.assert_rejected(path, MISSING)

    def test_formal_workload_requires_every_exact_value_and_scalar_type(self):
        workload = valid_acceptance()["performance"]["workload"]
        for key, correct in workload.items():
            incorrect = correct + 1 if type(correct) is int else "seeded"
            for value in (MISSING, incorrect, str(correct) if type(correct) is int else 1):
                with self.subTest(field=key, missing=value is MISSING):
                    self.assert_rejected(("performance", "workload", key), value)

    def test_all_nine_unique_mode_round_pairs_are_required(self):
        valid_runs = valid_acceptance()["performance"]["runs"]
        duplicate = copy.deepcopy(valid_runs)
        duplicate[-1] = copy.deepcopy(duplicate[0])
        for runs in (valid_runs[:-1], valid_runs + [copy.deepcopy(valid_runs[0])], duplicate):
            with self.subTest(run_count=len(runs)):
                self.assert_rejected(("performance", "runs"), runs)
        for key, value in (("mode", "unknown-mode"), ("round", 0)):
            with self.subTest(field=key):
                self.assert_rejected(("performance", "runs", 8, key), value)

    def test_each_run_requires_matching_adapter_300_frames_and_performance_scope(self):
        for index in (0, 8):
            changes = ((("fingerprint", "vendor_id"), 1),
                       (("fingerprint", "windows_session_id"), 3),
                       (("completion", "measured_frames"), 299),
                       (("performance_measurement",), False))
            for suffix, value in changes:
                with self.subTest(run=index, field=suffix):
                    self.assert_rejected(("performance", "runs", index, *suffix), value)

    def test_each_mode_requires_three_rounds_900_frames_and_897_intervals(self):
        for mode in MODES:
            for suffix, value in ((("rounds",), 2), (("measured_frames",), 899),
                                  (("frame_interval_ms", "sample_count"), 896),
                                  (("frame_interval_ms", "sample_count"), 900)):
                with self.subTest(mode=mode, field=suffix):
                    self.assert_rejected(("performance", "comparison", mode, *suffix), value)

    def test_all_four_unique_pixel_resource_epoch_cases_are_required(self):
        valid_cases = valid_acceptance()["pixels"]["cases"]
        duplicate = copy.deepcopy(valid_cases)
        duplicate[-1] = copy.deepcopy(duplicate[0])
        for cases in (valid_cases[:-1], valid_cases + [copy.deepcopy(valid_cases[0])], duplicate):
            with self.subTest(case_count=len(cases)):
                self.assert_rejected(("pixels", "cases"), cases)
        self.assert_rejected(("pixels", "cases", 3, "frame_sequence"), 32)
        self.assert_rejected(("pixels", "cases", 3, "pattern"), "legacy")

    def test_each_pixel_case_requires_real_warp_reference_and_matching_replay_adapter(self):
        for index in (0, 3):
            changes = ((("reference_adapter", "requested_driver_type"), "hardware"),
                       (("reference_adapter", "adapter_software_flag"), False),
                       (("reference_adapter", "windows_session_id"), 3),
                       (("replay_adapter", "vendor_id"), 1),
                       (("replay_adapter", "windows_session_id"), 3))
            for suffix, value in changes:
                with self.subTest(case=index, field=suffix):
                    self.assert_rejected(("pixels", "cases", index, *suffix), value)

    def test_pixel_error_and_pixel_count_require_valid_integer_scalars(self):
        changes = [("max_channel_error", value)
                   for value in (float("nan"), float("inf"), -1, True, False, 1.0, "0")]
        changes += [("compared_pixels", value)
                    for value in (True, False, float(1280 * 720), "921600")]
        for key, value in changes:
            with self.subTest(field=key, value=value):
                self.assert_rejected(("pixels", "cases", 3, "comparison", key), value)

    def test_every_pixel_comparison_must_pass_for_all_pixels_within_one_lsb(self):
        for index in (0, 3):
            for key, value in (("passed", False), ("passed", 1), ("max_channel_error", 2),
                               ("compared_pixels", 1280 * 720 - 1)):
                with self.subTest(case=index, field=key, value=value):
                    self.assert_rejected(("pixels", "cases", index, "comparison", key), value)
        state = valid_acceptance()
        for case in state["pixels"]["cases"]:
            case["comparison"]["max_channel_error"] = 1
        self.assertEqual(acceptance.validate_acceptance_manifests(**state),
                         state["m0"]["runs"][0]["fingerprint"])


if __name__ == "__main__":
    unittest.main()
