#!/usr/bin/env python3
"""Probe live VZ shared aperture boundaries in isolated native processes. Owner: @DNPMBHC."""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from datetime import datetime, timezone

import vz_gpu_bench_runner as runner


def run(candidates: list[int], output_name: str = "live-shared-memory-capacity-boundary.json") -> dict:
    binding = json.loads((runner.EVIDENCE / "build-binding.json").read_text())
    binary_digest = runner.sha256_file(runner.BINARY)
    if binary_digest != binding["binary_sha256"]:
        raise RuntimeError("Live capacity executable differs from verified build")
    cases = []
    for size in candidates:
        started = time.monotonic()
        row = {"requested_bytes": size}
        try:
            process = runner.capture([str(runner.BINARY), "--mode", "live-capacity-case",
                                      "--region-bytes", str(size)], timeout=45)
            row["process_exit"] = process.returncode
            if process.returncode == 0:
                row["native"] = json.loads(process.stdout)
            else:
                row["exception"] = runner.redact(process.stderr.split("*** First throw call stack:")[0],
                                                  runner.ROOT)[:1500]
        except RuntimeError as error:
            row["process_timeout"] = True
            row["error"] = runner.redact(str(error), runner.ROOT)
        row["elapsed_seconds"] = time.monotonic() - started
        native = row.get("native", {})
        row["fully_passed"] = all(native.get(key) for key in
                                  ("configurationValidated", "deviceCreated", "guestStarted", "guestStopped",
                                   "runningBeforeMap", "mappedAndUnmapped")) and not any(native.get(key) for key in
                                                              ("guestErrorDomain", "stopErrorDomain", "errorDomain"))
        row["running_at_final_state_sample"] = native.get("machineStateBeforeStop") == "VZVirtualMachineState(rawValue: 1)"
        row["guest_naturally_stopped_at_final_sample"] = native.get("guestStoppedNaturally", False)
        cases.append(row)
        print(json.dumps({"requested_bytes": size, "fully_passed": row["fully_passed"],
                          "process_exit": row.get("process_exit"), "error_domain": native.get("errorDomain"),
                          "error_code": native.get("errorCode"), "guest_error_domain": native.get("guestErrorDomain"),
                          "guest_error_code": native.get("guestErrorCode"),
                          "state_before_stop": native.get("machineStateBeforeStop"),
                          "stop_error_domain": native.get("stopErrorDomain"),
                          "stop_error_code": native.get("stopErrorCode")}), flush=True)
    accepted = [row["requested_bytes"] for row in cases if row["fully_passed"]]
    rejected = [row["requested_bytes"] for row in cases if not row["fully_passed"]]
    mapped = [row["requested_bytes"] for row in cases if row.get("native", {}).get("mappedAndUnmapped")]
    if runner.sha256_file(runner.BINARY) != binary_digest:
        raise RuntimeError("Live capacity executable changed during measurement")
    running = [row["requested_bytes"] for row in cases
               if row["fully_passed"] and row["running_at_final_state_sample"]]
    report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "native_binary_sha256": binary_digest, "cases": cases,
              "probe_script_sha256": runner.sha256_file(Path(__file__)),
              "largest_passed_aperture_running_at_final_sample_bytes": max(running, default=0),
              "sustained_guest_running_limit_established": False,
              "full_aperture_metric_includes_natural_guest_stops": True,
              "largest_verified_full_aperture_bytes": max(accepted, default=0),
              "largest_map_unmap_accepted_bytes": max(mapped, default=0),
              "observed_failures_are_not_assumed_to_be_physical_memory_limits": True,
              "smallest_observed_nonpassing_bytes": min(rejected) if rejected else None,
              "physical_commit_maximum_established": False, "physical_pages_fully_touched": False,
              "scope": "actual_native_EFI_start_map_unmap_stop_not_physical_RAM_maximum",
              "all_processes_isolated": True, "shared_vm_actions": 0}
    runner.save_json(runner.EVIDENCE / output_name, report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-exponent", type=int, default=46)
    parser.add_argument("--repeat-boundary", action="store_true",
                        help="Also run two independent repetitions at 4, 8, 32 and 64 TiB")
    args = parser.parse_args()
    if not 34 <= args.max_exponent <= 46:
        raise ValueError("Maximum exponent must be between 34 and 46")
    result = run([64 * 1024 * 1024] + [1 << exponent for exponent in range(34, args.max_exponent + 1)])
    print(json.dumps({key: result[key] for key in
                      ("owner", "largest_verified_full_aperture_bytes", "smallest_observed_nonpassing_bytes",
                       "physical_commit_maximum_established")}))
    if args.repeat_boundary:
        run([1 << exponent for _ in range(2) for exponent in (42, 43, 45, 46)],
            "live-capacity-repeat-verification.json")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(runner.redact(type(error).__name__ + ": " + str(error), runner.ROOT))
        raise SystemExit(1) from None
