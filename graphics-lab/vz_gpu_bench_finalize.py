#!/usr/bin/env python3
"""Verify, summarize and seal native experiment evidence. Owner: @DNPMBHC."""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

import vz_gpu_bench_runner as runner
from vz_gpu_bench_support import compare_pair, redact, save_json, sha256_file


def load(name: str) -> dict:
    return json.loads((runner.EVIDENCE / name).read_text())


def owned_sources() -> list[Path]:
    module = [p for p in runner.MODULE.rglob("*") if p.is_file()
              and p.suffix in {".swift", ".c", ".h", ".sh", ".entitlements"}
              and not {"build", ".build"}.intersection(p.relative_to(runner.MODULE).parts)]
    helpers = list((runner.ROOT / "graphics-lab").glob("vz_gpu_bench_*.py"))
    tests = list((runner.ROOT / "graphics-lab").glob("test_vz_gpu_*.py"))
    return sorted(module + helpers + tests)


def alias(path: Path) -> str:
    if path.is_relative_to(runner.MODULE):
        return "module-x/" + path.relative_to(runner.MODULE).as_posix()
    return path.relative_to(runner.ROOT).as_posix()


def verify_binding() -> dict:
    binding = load("build-binding.json")
    benchmark = load("vz-zero-copy-benchmark.json")
    names = {p.name for p in runner.MODULE.iterdir() if p.suffix in {".swift", ".c", ".h"}}
    checks = {
        "binary_matches": sha256_file(runner.BINARY) == binding["binary_sha256"] == benchmark["binary_sha256"],
        "source_binding_matches": names == set(binding["sources"]) and all(
            sha256_file(runner.MODULE / name) == digest for name, digest in binding["sources"].items()),
        "entitlements_match": sha256_file(runner.MODULE / "vz_bridge.entitlements") == binding["entitlements_sha256"],
        "benchmark_script_matches": sha256_file(runner.ROOT / "graphics-lab/vz_gpu_bench_runner.py")
        == benchmark["benchmark_script_sha256"],
        "validator_matches": sha256_file(runner.ROOT / "graphics-lab/vz_gpu_bench_support.py")
        == benchmark["evidence_validator_sha256"],
        "diagnostic_bindings_match": all(sha256_file(runner.EVIDENCE / name) == digest
                                          for name, digest in benchmark["evidence_sha256"].items()),
        "balanced_order": all(len(set(tuple(row["mode_order"]) for row in benchmark["runs"]
                                      if row["resolution"] == size)) == 3
                              for size in ([1280, 720], [2560, 1440])),
    }
    for name in ("efi-guest-1280.json", "efi-guest-2560.json", "efi-guest-external-consumer.json"):
        report = load(name)
        checks[name + "_passed"] = report["passed"] and all(report["checks"].values())
        checks[name + "_native_binding"] = report["native_binary_sha256"] == binding["binary_sha256"]
        checks[name + "_fixture_binding"] = all(
            report[key] == sha256_file(runner.MODULE / "efi_fixture" / filename)
            for key, filename in (("guest_source_sha256", "DemoGuest.c"), ("guest_header_sha256", "DemoUEFI.h")))
    external = load("efi-guest-external-consumer.json")
    checks["external_static_library_sources_match"] = all(
        sha256_file(runner.MODULE / name) == digest for name, digest in external["library_binding"]["sources"].items())
    downstream = load("efi-downstream-consumer-roundtrip.json")
    checks["efi_downstream_consumer_passed"] = downstream["passed"] and downstream["gpu_all_pixels_equal"]
    checks["efi_downstream_harness_matches"] = downstream["harness_sha256"] == sha256_file(
        runner.EVIDENCE / "efi-consumer-roundtrip.swift")
    package = next(runner.ROOT.glob("*/*/Package.swift")).parent
    runtime = next(package.glob("Sources/*/Runtime"))
    checks["efi_downstream_consumer_sources_match"] = all(
        sha256_file(runtime / name) == digest for name, digest in downstream["consumer_source_sha256"].items())
    checks["efi_downstream_producer_sources_match"] = all(
        sha256_file(runner.MODULE / name) == digest
        for name, digest in downstream["producer_library_binding"]["sources"].items())
    checks["capacity_probe_binding"] = load("shared-memory-capacity-boundary.json")["native_binary_sha256"] == binding["binary_sha256"]
    live = load("live-shared-memory-capacity-boundary.json")
    checks["live_capacity_probe_binding"] = live["native_binary_sha256"] == binding["binary_sha256"]
    checks["live_capacity_script_binding"] = live["probe_script_sha256"] == sha256_file(
        runner.ROOT / "graphics-lab/vz_gpu_bench_live_memory_limits.py")
    checks["live_capacity_scope_is_not_physical_limit"] = not live["physical_commit_maximum_established"]
    checks["live_capacity_lifecycle_available"] = all(
        row.get("native", {}).get("requestedBytes") == row["requested_bytes"]
        and "machineStateBeforeStop" in row["native"] for row in live["cases"])
    repeat = load("live-capacity-repeat-verification.json")
    checks["live_capacity_repeats_binding"] = repeat["native_binary_sha256"] == binding["binary_sha256"]
    checks["live_capacity_repeats_complete"] = len(repeat["cases"]) == 8 and all(
        row["requested_bytes"] == row["native"]["requestedBytes"] for row in repeat["cases"])
    checks["live_capacity_observation_scope"] = not live["physical_pages_fully_touched"] and not live[
        "sustained_guest_running_limit_established"]
    checks["unittest_binary_binding"] = load("unittest-verification.json")["binary_sha256"] == binding["binary_sha256"]
    unit = load("unittest-verification.json")
    checks["unittest_log_binding"] = unit["test_log_sha256"] == sha256_file(runner.EVIDENCE / "unittest.log")
    restart = load("restart-verification.json")
    checks["restart_binary_binding"] = restart["binary_sha256"] == binding["binary_sha256"]
    checks["restarted_host_readiness_passed"] = all(restart["ready"].values())
    if not all(checks.values()):
        raise RuntimeError("Final binding rejected: " + ", ".join(name for name, passed in checks.items() if not passed))
    report = {"owner": "@DNPMBHC", "verified_at_utc": datetime.now(timezone.utc).isoformat(),
              "binary_sha256": binding["binary_sha256"], "verified_before_cleanup": True, **checks}
    save_json(runner.EVIDENCE / "final-binding-verification.json", report)
    return report


def summarize() -> dict:
    benchmark = load("vz-zero-copy-benchmark.json")
    rows = []
    for size in ([1280, 720], [2560, 1440]):
        rounds = [row for row in benchmark["runs"] if row["resolution"] == size]
        if len(rounds) != 3:
            raise ValueError("Three measured rounds per resolution required")
        modes = {}
        for name, worker_name in (("native", None), ("ipc_control_client", "ipc_control_worker"),
                                  ("ipc_client", "ipc_worker")):
            samples = [row[name] for row in rounds]
            for row in rounds:
                if worker_name:
                    compare_pair(row["native"], row[name], row[worker_name])
            latencies = sorted(value for sample in samples for value in sample["frameLatenciesMs"])
            wall = sum(sample["wallMs"] for sample in samples)
            frames = sum(sample["frames"] for sample in samples)
            cpu = sum(sample["cpuUserMs"] + sample["cpuSysMs"] for sample in samples)
            if worker_name:
                cpu += sum(row[worker_name]["cpuUserMs"] + row[worker_name]["cpuSysMs"] for row in rounds)
            if frames != 900 or any(sample["drawCalls"] != 2048 or sample["warmupFrames"] != 60 for sample in samples):
                raise ValueError("Final workload must contain 2048 draws, 60 warmup and 900 measured frames")
            modes[name] = {"mean_ms": sum(latencies) / len(latencies),
                           "p99_ms_pooled": latencies[math.ceil(len(latencies) * .99) - 1],
                           "cpu_ms_per_frame": cpu / frames, "cpu_pct_total_one_core": cpu / wall * 100,
                           "measured_frames": frames, "round_mean_ms": [sample["meanMs"] for sample in samples]}
        native = modes["native"]
        rows.append({"resolution": size, "modes": modes,
                     "copy_baseline_mean_latency_saved_ms": modes["ipc_client"]["mean_ms"] - native["mean_ms"],
                     "ack_baseline_mean_latency_saved_ms": modes["ipc_control_client"]["mean_ms"] - native["mean_ms"],
                     "copy_cpu_ms_per_frame_saved": modes["ipc_client"]["cpu_ms_per_frame"] - native["cpu_ms_per_frame"],
                     "ack_cpu_ms_per_frame_saved": modes["ipc_control_client"]["cpu_ms_per_frame"] - native["cpu_ms_per_frame"]})
    report = {"owner": "@DNPMBHC", "source_benchmark_sha256": sha256_file(runner.EVIDENCE / "vz-zero-copy-benchmark.json"),
              "binary_sha256": benchmark["binary_sha256"], "real_qemu_comparison": False,
              "origin": "host_synthetic_not_guest_scanout", "maximum_in_flight": 1,
              "aggregation": "900 measured frames per mode/resolution; nearest-rank pooled P99; sum client+worker CPU / measured wall",
              "rows": rows}
    save_json(runner.EVIDENCE / "benchmark-summary.json", report)
    return report


def quality() -> dict:
    result = runner.capture([str(runner.ROOT / "handoff/task-07/.tools/swiftlint"),
                             "lint", "--strict", "--quiet"], cwd=runner.APP)
    log = redact(result.stdout + result.stderr, runner.ROOT)
    (runner.EVIDENCE / "strict-swiftlint.log").write_text(log or "Strict SwiftLint: exit 0; zero violations\n")
    if result.returncode:
        raise RuntimeError("Strict SwiftLint failed: " + log[-1500:])
    swift = list(runner.MODULE.glob("*.swift"))
    maximum = max(len(path.read_text().splitlines()) for path in swift)
    audit = json.loads((runner.EVIDENCE / "anticheat-self-test.log").read_text().strip())
    unit = load("unittest-verification.json")
    diff = runner.capture(["git", "diff", "--check", "--", str(runner.MODULE)], cwd=runner.APP)
    if maximum > 400 or diff.returncode or unit["unittest_exit"] or audit["result"] != "passed":
        raise RuntimeError("Source/test/audit gate rejected")
    report = {"owner": "@DNPMBHC", "strict_swiftlint_exit": 0, "unittest_exit": 0,
              "unittest_count": unit["tests"], "anticheat_self_test_exit": 0, "anticheat_result": audit,
              "swift_file_count": len(swift), "max_swift_file_lines": maximum, "owned_git_diff_check_exit": 0,
              "scope": "host_prototype_quality; full_task_acceptance_recorded_separately"}
    save_json(runner.EVIDENCE / "quality-gates.json", report)
    return report


def cleanup() -> dict:
    process = runner.capture(["ps", "-axo", "pid=,command="])
    pid_file = runner.BUILD / "host.pid"
    owned_pid = int(pid_file.read_text()) if pid_file.exists() else -1
    others = []
    for line in process.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and str(runner.BUILD) in parts[1] and int(parts[0]) != owned_pid:
            others.append(int(parts[0]))
    if others:
        raise RuntimeError("Temporary build has active consumers; preserve it until their bounded execution finishes")
    stopped = runner.stop()
    shutil.rmtree(runner.BUILD, ignore_errors=True)
    for name in ("build", ".build"):
        shutil.rmtree(runner.MODULE / name, ignore_errors=True)
    for path in runner.MODULE.rglob("*.pcm"):
        path.unlink()
    counts = {"workspace_large_files_count_excluding_git": 0, "workspace_pcm_count_excluding_git": 0,
              "owned_large_files_count": 0, "owned_pcm_count": 0}
    groups = {"graphics_lab": 0, "historical_handoff": 0, "other_locked_paths": 0}
    owned = set(owned_sources())
    for directory, children, files in os.walk(runner.ROOT):
        children[:] = [name for name in children if name != ".git" and not (Path(directory) / name).is_symlink()]
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            is_owned = path.is_relative_to(runner.MODULE) or path.is_relative_to(runner.EVIDENCE) or path in owned
            if path.suffix == ".pcm":
                counts["workspace_pcm_count_excluding_git"] += 1
                counts["owned_pcm_count"] += int(is_owned)
            if path.stat().st_size > 5 * 1024 * 1024:
                counts["workspace_large_files_count_excluding_git"] += 1
                counts["owned_large_files_count"] += int(is_owned)
                if not is_owned:
                    relative = path.relative_to(runner.ROOT)
                    key = "graphics_lab" if relative.parts[0] == "graphics-lab" else (
                        "historical_handoff" if relative.parts[0] == "handoff" else "other_locked_paths")
                    groups[key] += 1
    if counts["owned_large_files_count"] or counts["owned_pcm_count"] or runner.BUILD.exists():
        raise RuntimeError("Owned cleanup is incomplete")
    report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "owned_server_stopped": stopped, "owned_temporary_build_removed": True, "module_build_removed": True,
              "active_other_consumers_before_cleanup": 0, "outside_owned_large_files_by_group": groups,
              "file_lock_prevents_outside_cleanup": True,
              "full_workspace_zero_large_files_requirement_met": counts["workspace_large_files_count_excluding_git"] == 0,
              "scope": "ordinary workspace files excluding Git metadata and symlinks; outside file locks preserved", **counts}
    save_json(runner.EVIDENCE / "cleanup-verification.json", report)
    return report


def seal() -> dict:
    source_paths = owned_sources()
    textual = source_paths + [p for p in runner.EVIDENCE.iterdir() if p.is_file()
                              and p.suffix in {".json", ".md", ".log", ".txt", ".swift"}]
    forbidden = (str(Path.home()), str(runner.ROOT), runner.APP.name, Path.home().name)
    failures = []
    for path in textual:
        value = path.read_text(errors="replace")
        if any(token in value for token in forbidden) or (path.parent == runner.EVIDENCE and re.search(r"/(Users|Volumes)/", value)):
            failures.append(alias(path))
    if failures:
        raise RuntimeError("Privacy rejected files: " + ", ".join(failures))
    save_json(runner.EVIDENCE / "privacy-verification.json", {
        "owner": "@DNPMBHC", "checked_owned_source_and_evidence_files": len(textual),
        "private_home_workspace_project_tokens_found": False,
        "private_user_or_volume_paths_in_evidence_found": False, "scope": "owned textual files only"})
    manifest = {"owner": "@DNPMBHC", "sealed_at_utc": datetime.now(timezone.utc).isoformat(),
                "inventory_scope": "current_owned_sources_and_evidence; historical_experiments_keep_their_original_binding",
                "source_sha256": {alias(p): sha256_file(p) for p in source_paths},
                "evidence_sha256": {p.name: sha256_file(p) for p in sorted(runner.EVIDENCE.iterdir())
                                    if p.is_file() and p.name != "evidence-manifest.json"},
                "measured_binary_removed_after_verified_cleanup": not runner.BINARY.exists(),
                "full_acceptance_state": load("delivery-status.json")["phase5_full_acceptance"]}
    save_json(runner.EVIDENCE / "evidence-manifest.json", manifest)
    if not all(sha256_file(runner.EVIDENCE / name) == digest for name, digest in manifest["evidence_sha256"].items()):
        raise RuntimeError("Evidence mutated during sealing")
    return {"source_count": len(source_paths), "evidence_count": len(manifest["evidence_sha256"]),
            "all_digests_verified": True, "manifest_sha256": sha256_file(runner.EVIDENCE / "evidence-manifest.json")}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "quality", "cleanup", "seal"))
    args = parser.parse_args()
    if args.action == "verify":
        verify_binding()
        result = summarize()
    elif args.action == "quality":
        result = quality()
    elif args.action == "cleanup":
        result = cleanup()
    else:
        result = seal()
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print(redact(type(error).__name__ + ": " + str(error), runner.ROOT))
        raise SystemExit(1) from None
