#!/usr/bin/env python3
"""Run three graphics modes in one real interactive Windows Guest session."""
from __future__ import annotations
import argparse
import json
import math
import shutil
import statistics
import time
from pathlib import Path
import analyze
from guest_preflight import collect_preflight
from benchmark_support import (SCRIPT_DIR, EVIDENCE_DIR, GUEST_DIR, GuestSession,
    checked, discover_started_vm, discover_utmctl, fingerprint, source_digests,
    sha256_file, start_metal_host, stop_metal_host, writable_path, write_json,
    redact_text, validate_guest_environment, validate_probe_metadata)

MODES = ("direct-present", "pixel-readback", "command-only")

def audit_run(rows: list[dict], host_rows: list[dict], mode: str, warmup: int,
              command_every: int, resource_every: int, resource_bytes: int,
              width: int, height: int, commands: int) -> dict:
    if mode != "direct-present":
        measured = [r for r in host_rows if not r.get("warmup")]
        if len(measured) != len(rows):
            raise ValueError("host and Guest measured frame counts differ")
        if any(r.get("capture_enabled") or r.get("capture_configured") for r in measured):
            raise ValueError("capture work cannot be included in performance samples")
        if any(r.get("display_sync_enabled") is not False for r in measured):
            raise ValueError("paired throughput measurement must disable host display sync")
        if any(r.get("offload_mode") != mode for r in measured):
            raise ValueError("host offload mode does not match the run")
    else:
        measured = []
    cache_bytes, refresh_bytes = [], []
    for index, row in enumerate(rows):
        sequence = warmup + index
        if mode == "direct-present":
            if row["transferred_bytes"] or row["network_bytes_out"] or row["network_bytes_in"]:
                raise ValueError("Direct Present unexpectedly transferred data")
            continue
        command_bytes = commands * (32 if mode == "command-only" else 16)
        command_transfer = command_bytes if sequence == 0 or sequence % command_every == 0 else 0
        resource_transfer = resource_bytes if sequence == 0 or sequence % resource_every == 0 else 0
        pixels = 0 if mode == "command-only" else width * height * 4
        request_bytes = 32 + command_transfer + resource_transfer + pixels
        if (row["command_bytes"], row["resource_bytes"], row["network_bytes_out"],
            row["network_bytes_in"], row["transferred_bytes"]) != (
            command_transfer, resource_transfer, request_bytes, 56, request_bytes + 56):
            raise ValueError("application byte accounting does not match the wire protocol")
        host = measured[index]
        if host["frame_index"] != sequence or host["pixel_bytes"] != pixels:
            raise ValueError("host sequence or pixel bytes differ")
        if host["transferred_bytes_in"] != request_bytes or host["ack_bytes_out"] != 56:
            raise ValueError("host and Guest byte accounting differ")
        guest_gpu = row["host_gpu_ms"]
        host_gpu = host.get("metal_command_complete_ms")
        if any(isinstance(value, bool) or not isinstance(value, (int, float)) or
               not math.isfinite(value) or value <= 0 for value in (guest_gpu, host_gpu)):
            raise ValueError("real host GPU timing is missing or invalid")
        if not math.isclose(guest_gpu, math.floor(host_gpu * 1000) / 1000, rel_tol=0, abs_tol=1e-6):
            raise ValueError("ACK GPU timing differs from the actual Metal command duration")
        if mode == "command-only":
            if row["gpu_ms"] is not None:
                raise ValueError("command-only must not report Guest GPU work")
            if host.get("scene_draw_count") != commands:
                raise ValueError("received scene draw count was not executed")
        (refresh_bytes if command_transfer or resource_transfer else cache_bytes).append(request_bytes + 56)
    return {"cache_frame_count": len(cache_bytes), "refresh_frame_count": len(refresh_bytes),
        "cache_total_bytes": statistics.fmean(cache_bytes) if cache_bytes else None,
        "refresh_total_bytes": statistics.fmean(refresh_bytes) if refresh_bytes else None,
        "mean_total_bytes": statistics.fmean(r["transferred_bytes"] for r in rows),
        "max_total_bytes": max(r["transferred_bytes"] for r in rows),
        "hello_bytes": 0 if mode == "direct-present" else 32, "ack_bytes_per_frame": 0 if mode == "direct-present" else 56}

def read_host_rows(path: Path, count: int) -> list[dict]:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        data = path.read_text() if path.is_file() else ""
        lines = data.splitlines(keepends=True)
        rows = [json.loads(line) for line in lines if line.endswith("\n")]
        if len(rows) > count:
            raise RuntimeError("receiver telemetry contains unexpected extra frames")
        if len(rows) == count:
            return rows
        time.sleep(0.1)
    raise RuntimeError("receiver telemetry did not finish")

def validate_host_identity(rows: list[dict], receiver: dict) -> None:
    if not rows or any(row.get("host_binary_sha256") != receiver["metal_host_binary"] or
        row.get("completion_scope") != "gpu-command-complete" or
        row.get("device") != "Apple M4" for row in rows):
        raise RuntimeError("receiver GPU identity, completion scope, or running binary SHA differs")

def completion_record(stderr: Path) -> dict:
    records = []
    for line in stderr.read_text().splitlines():
        if line.startswith("probe_completion_json="):
            records.append(json.loads(line.split("=", 1)[1]))
    if len(records) != 1:
        raise RuntimeError("probe must emit one measurement completion record")
    record = records[0]
    frames = record.get("measured_frames")
    if isinstance(frames, bool) or not isinstance(frames, int) or frames < 1:
        raise RuntimeError("invalid completed measurement frame count")
    if record.get("completion_mode") != "gpu-complete":
        raise RuntimeError("measurement completion boundary is not GPU completion")
    wall = record.get("measurement_wall_ms")
    fps = record.get("throughput_including_gpu_drain_fps")
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or
           not math.isfinite(value) or value <= 0 for value in (wall, fps)):
        raise RuntimeError("completed measurement timing must be finite and positive")
    if not math.isclose(fps, frames * 1000 / wall, rel_tol=1e-6, abs_tol=1e-6):
        raise RuntimeError("completed FPS disagrees with frame count and measurement wall time")
    return record


def summarize_mode_comparison(samples: list[dict], rows_by_run: list[list[dict]], mode: str) -> dict:
    if not samples or len(samples) != len(rows_by_run):
        raise ValueError("comparison requires matching run records and frame samples")
    pooled_rows = [row for rows in rows_by_run for row in rows]
    pooled = analyze.summarize(pooled_rows)
    intervals = analyze.distribution([
        float(row["cpu_frame_ms"]) for rows in rows_by_run for row in rows[1:]])
    return {
        "rounds": len(samples), "measured_frames": len(pooled_rows),
        "fps_including_gpu_drain_mean": statistics.fmean(
            r["completion"]["throughput_including_gpu_drain_fps"] for r in samples),
        "fps_including_gpu_drain_pooled": len(pooled_rows) * 1000 /
            sum(r["completion"]["measurement_wall_ms"] for r in samples),
        "frame_interval_ms": {key: intervals[key]
                              for key in ("sample_count", "mean", "p50", "p95", "p99")},
        "percentile_scope": "pooled measured frame intervals excluding each round's first frame",
        "mean_total_bytes": statistics.fmean(
            r["byte_accounting"]["mean_total_bytes"] for r in samples),
        "host_gpu_ms_mean": pooled["timing"]["host_gpu_ms"]["mean"]
            if mode != "direct-present" else None}


def snapshot_inputs(output: Path) -> dict:
    names = ("d3d11_probe.cpp", "metal_host.swift", "analyze.py", "benchmark_support.py",
             "run_guest_m2_benchmark.py", "run_guest_pixel_validation.py", "pixel_compare.py",
             "command_protocol.py", "guest_preflight.py", "guest_preflight.ps1",
             "restart_metal_host.sh", "build_metal_host.sh", "build_probe.sh")
    target = output / "inputs"
    target.mkdir(parents=True, exist_ok=True)
    inputs = {}
    for name in names:
        src = SCRIPT_DIR / name
        if src.is_file():
            shutil.copy2(src, target / name)
            inputs[name] = {"file": f"inputs/{name}", "sha256": sha256_file(target / name)}
    shutil.copy2(SCRIPT_DIR / "build" / "d3d11_probe.exe", target / "d3d11_probe.exe")
    inputs["d3d11_probe.exe"] = {"file": "inputs/d3d11_probe.exe", "sha256": sha256_file(target / "d3d11_probe.exe")}
    return inputs

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=EVIDENCE_DIR / "m2-command-replay")
    parser.add_argument("--host-ip", default="192.168.64.1")
    parser.add_argument("--port", type=int, default=39003)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=60)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    output = writable_path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    runs = []
    receiver_active = False
    exit_code = 1
    try:
        if args.frames < 2 or args.warmup < 0 or args.rounds < 1:
            raise ValueError("invalid measurement counts")
        guest = GuestSession(discover_utmctl(), "")
        guest.vm_id = discover_started_vm(guest.utmctl)
        guest_metadata = guest.metadata()
        validate_guest_environment(guest_metadata)
        collect_preflight(guest, output / "preflight-initial")
        probe_digest = guest.prepare_probe(SCRIPT_DIR / "build" / "d3d11_probe.exe")
        inputs = snapshot_inputs(output)
        expected_sources = source_digests()
        archived_probe_digest = inputs.get("d3d11_probe.exe", {}).get("sha256")
        if (probe_digest != archived_probe_digest or
                probe_digest != expected_sources.get("d3d11_probe_exe")):
            raise RuntimeError("Guest probe binary SHA differs from the archived input or current binary")
        expected_session = None
        expected_adapter = None
        for round_index in range(args.rounds):
            order = MODES[round_index % 3:] + MODES[:round_index % 3]
            for mode in order:
                stem = "m2-" + mode + "-r" + str(round_index + 1)
                run_dir = output / stem
                run_dir.mkdir(parents=True, exist_ok=True)
                preflight = collect_preflight(guest, run_dir / "preflight")
                thermal = checked(["pmset", "-g", "therm"]).stdout
                csv_name = stem + ".csv"
                metadata_name = stem + ".json"
                receiver = None
                if mode != "direct-present":
                    receiver_active = True
                    receiver = start_metal_host(run_dir, mode, args.host_ip, args.port)
                    shutil.copy2(SCRIPT_DIR / "build" / "metal_host", run_dir / "metal_host")
                probe_args = ["--frames", str(args.frames), "--warmup", str(args.warmup),
                    "--width", "1280", "--height", "720", "--commands", "16",
                    "--resource-bytes", "65536", "--command-every", "30", "--resource-every", "30",
                    "--completion-mode", "gpu-complete",
                    "--metadata-json", GUEST_DIR + "\\" + metadata_name,
                    "--csv", GUEST_DIR + "\\" + csv_name]
                if mode != "direct-present":
                    probe_args += ["--offload-mode", mode, "--transport-host", args.host_ip, "--port", str(args.port)]
                execution = guest.run_interactive(stem, probe_args, run_dir, [csv_name, metadata_name])
                metadata = json.loads((run_dir / metadata_name).read_text())
                actual = fingerprint(metadata)
                validate_probe_metadata(metadata, {
                    "requested_driver_type": "hardware", "width": 1280, "height": 720,
                    "commands": 16, "resource_bytes": 65536, "command_every": 30,
                    "resource_every": 30, "resource_pattern": "legacy", "seed": 1,
                    "capture_requested": False, "completion_mode": "gpu-complete",
                    "transport_mode": "direct_present" if mode == "direct-present" else "offload_tcp",
                    "offload_mode": "pixel-readback" if mode == "direct-present" else mode})
                adapter = {key: value for key, value in actual.items() if key != "windows_session_id"}
                if expected_adapter is not None and adapter != expected_adapter:
                    raise RuntimeError("three-mode paired measurement changed the selected DXGI adapter")
                expected_adapter = adapter
                session = actual["windows_session_id"]
                if session != preflight["console_session_id"] or (expected_session is not None and session != expected_session):
                    raise RuntimeError("three-mode paired measurement changed interactive Windows session")
                expected_session = session
                with (run_dir / csv_name).open(newline="") as stream:
                    rows = analyze.load_rows(stream)
                if len(rows) != args.frames:
                    raise RuntimeError("measured CSV frame count differs from the requested measurement count")
                host_rows = read_host_rows(run_dir / "host.jsonl", args.frames + args.warmup) if receiver else []
                if receiver:
                    validate_host_identity(host_rows, receiver)
                audit = audit_run(rows, host_rows, mode, args.warmup, 30, 30, 65536, 1280, 720, 16)
                complete = completion_record(run_dir / (stem + ".stderr.log"))
                if complete["measured_frames"] != args.frames or complete["completion_mode"] != "gpu-complete":
                    raise RuntimeError("measurement completion record is inconsistent")
                current = source_digests()
                for key in ("d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift", "analyze_py", "benchmark_support_py"):
                    if current[key] != expected_sources[key]:
                        raise RuntimeError("measurement inputs changed during the paired run")
                run = {"mode": mode, "round": round_index + 1, "fingerprint": actual,
                    "performance_measurement": True,
                    "preflight": preflight,
                    "execution": execution, "completion": complete, "byte_accounting": audit,
                    "summary": analyze.summarize(rows), "receiver": receiver,
                    "source_digests": current, "thermal_snapshot": thermal,
                    "csv": f"{stem}/{csv_name}", "csv_sha256": sha256_file(run_dir / csv_name),
                    "metadata_sha256": sha256_file(run_dir / metadata_name),
                    "stderr_sha256": sha256_file(run_dir / (stem + ".stderr.log"))}
                if receiver:
                    run["host_jsonl_sha256"] = sha256_file(run_dir / "host.jsonl")
                    run["host_binary_artifact"] = f"{stem}/metal_host"
                    run["host_binary_artifact_sha256"] = sha256_file(run_dir / "metal_host")
                    if run["host_binary_artifact_sha256"] != receiver["metal_host_binary"]:
                        raise RuntimeError("archived receiver binary does not match the running receiver")
                    stop_metal_host()
                    receiver_active = False
                write_json(run_dir / "run.json", run)
                runs.append(run)
                write_json(output / "manifest.json", {"schema_version": 1, "complete": False,
                    "owner": "@DNPMBHC", "inputs": inputs, "guest": guest_metadata, "runs": runs})
                print(json.dumps({"mode": mode, "round": round_index + 1,
                    "fps_including_gpu_drain": complete["throughput_including_gpu_drain_fps"],
                    "mean_bytes": audit["mean_total_bytes"], "session": session}), flush=True)
        comparison = {}
        for mode in MODES:
            samples = [r for r in runs if r["mode"] == mode]
            rows_by_run = []
            for sample in samples:
                with (output / sample["csv"]).open(newline="") as stream:
                    rows_by_run.append(analyze.load_rows(stream))
            comparison[mode] = summarize_mode_comparison(samples, rows_by_run, mode)
        manifest = {"schema_version": 1, "complete": True, "performance_measurement": True,
            "owner": "@DNPMBHC", "inputs": inputs,
            "probe_binary_sha256": probe_digest, "guest": guest_metadata, "windows_session_id": expected_session,
            "completion_scope": "per-frame GPU command completion; not physical screen display",
            "workload": {"width":1280,"height":720,"commands":16,"resource_bytes":65536,
                         "frames":args.frames,"warmup":args.warmup,"rounds":args.rounds,
                         "command_every":30,"resource_every":30,"resource_pattern":"legacy"},
            "historical_reference_fps": {"direct-present":11.35,"pixel-readback":6.19},
            "comparison":comparison,"runs":runs}
        write_json(output / "manifest.json", manifest)
        print(json.dumps({"complete": True, "comparison": comparison}), flush=True)
        exit_code = 0
    except Exception as error:
        write_json(output / "failure.json", {"error": redact_text(str(error)), "completed_runs": len(runs)})
        print(json.dumps({"complete": False, "error": redact_text(str(error))}), flush=True)
    finally:
        if receiver_active:
            try:
                stop_metal_host()
            except Exception as error:
                write_json(output / "cleanup-failure.json", {
                    "complete": False, "error": redact_text(str(error)), "completed_runs": len(runs)})
                print(json.dumps({"complete": False, "cleanup_error": redact_text(str(error))}), flush=True)
                exit_code = 1
    return exit_code
if __name__ == "__main__":
    raise SystemExit(main())
