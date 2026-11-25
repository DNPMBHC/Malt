#!/usr/bin/env python3
"""Validate real local Metal replay; the CPU oracle is not a Guest D3D11 reference."""
from __future__ import annotations

import argparse
import csv
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import time

from benchmark_support import (EVIDENCE_DIR, SCRIPT_DIR, WORKSPACE_ROOT, clean_value,
    checked, redact_text, runtime_environment, sha256_file, source_digests,
    writable_path, write_json)
from command_protocol import command_batch, run_client, seeded_resource


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def float32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def auxiliary_cpu_rgba(resource: bytes, width: int, height: int) -> bytes:
    """Scalar FP32 shader oracle, independent of MSL and the replay implementation."""
    pattern = bytearray()
    for address in range(0, len(resource), 4):
        value = 0
        for index in range(8):
            value ^= struct.unpack_from("<I", resource, (address + index * 4) % len(resource))[0]
        shade = float32(float(value & 255) / float32(255.0))
        green = float32(float32(0.25) + float32(shade * float32(0.5)))
        blue = float32(float32(1.0) - float32(shade * float32(0.35)))
        for channel in (shade, green, blue, 1.0):
            pattern.append(min(255, max(0, round(float32(channel * float32(255.0))))))
    pixel_count = width * height
    words = len(resource) // 4
    return bytes(pattern) * (pixel_count // words) + bytes(pattern[:(pixel_count % words) * 4])


def fnv1a64(data: bytes) -> str:
    result = 14695981039346656037
    for byte in data:
        result = ((result ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return format(result, "x")


def start_local_receiver(directory: Path, port: int, captures: list[int]) -> dict:
    directory = writable_path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    command = [str(SCRIPT_DIR / "restart_metal_host.sh"), "--bind", "127.0.0.1", "--port", str(port),
        "--jsonl", str(directory / "host.jsonl"), "--resource-policy", "off", "--metalfx", "off",
        "--offload-mode", "command-only", "--display-sync", "off",
        "--capture-dir", str((directory / "host-captures").relative_to(WORKSPACE_ROOT)),
        "--capture-frame", ",".join(map(str, captures))]
    process = checked(command, env=runtime_environment(SCRIPT_DIR / "build" / "runtime"), timeout=120)
    markers = dict(line.split("=", 1) for line in process.stdout.splitlines() if "=" in line)
    result = {"metal_host_swift": markers.get("source_sha256"), "metal_host_binary": markers.get("binary_sha256")}
    assert result["metal_host_swift"] == sha256_file(SCRIPT_DIR / "metal_host.swift")
    assert result["metal_host_binary"] == sha256_file(SCRIPT_DIR / "build" / "metal_host")
    assert "display_sync_enabled=false" in process.stdout
    write_json(directory / "receiver-start.json", {**result, "status": markers.get("status"),
        "offload_mode": "command-only", "display_sync_enabled": False, "restarted_from_source": True})
    return result


def stop_owned_receiver(pid: int) -> None:
    pid_file = SCRIPT_DIR / "build" / "metal_host.pid"
    if not pid_file.is_file() or pid_file.read_text().strip() != str(pid):
        raise RuntimeError("receiver PID ownership changed before cleanup")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pid_file.unlink()
        return
    library = ctypes.CDLL(ctypes.util.find_library("proc"))
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    found = library.proc_pidpath(pid, buffer, len(buffer))
    expected = (SCRIPT_DIR / "build" / "metal_host").resolve()
    if found <= 0 or Path(buffer.value.decode()).resolve() != expected:
        raise RuntimeError("cleanup refused an unverified receiver executable")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            if pid_file.is_file() and pid_file.read_text().strip() == str(pid):
                pid_file.unlink()
            return
        time.sleep(0.1)
    raise RuntimeError("owned receiver did not stop after SIGTERM")


def read_host_rows(directory: Path, count: int) -> list[dict]:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        path = directory / "host.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
        if len(rows) == count:
            return rows
        if len(rows) > count:
            raise RuntimeError("receiver recorded unexpected extra frames")
        time.sleep(0.05)
    raise RuntimeError("receiver log did not contain the complete frame sequence")


def compare_capture(directory: Path, sequence: int, seed: int, width: int, height: int,
                    cadence: int, digests: dict) -> dict:
    capture = directory / "host-captures" / f"frame-{sequence:06d}"
    metadata = json.loads(capture.with_suffix(".json").read_text())
    actual = capture.with_suffix(".rgba").read_bytes()
    resource = seeded_resource(seed, sequence // cadence)
    expected = auxiliary_cpu_rgba(resource, width, height)
    assert len(actual) == len(expected) == width * height * 4
    assert metadata["frame_sequence"] == sequence
    assert metadata["rgba_sha256"] == sha256_bytes(actual)
    assert metadata["resource_sha256"] == sha256_bytes(resource)
    assert metadata["command_sha256"] == sha256_bytes(command_batch(width))
    assert metadata["host_binary_sha256"] == digests["metal_host_binary"]
    assert metadata["scene_draw_count"] == 16 and metadata["presentation_draw_count"] == 1
    assert metadata["completion_scope"] == "gpu-command-complete"
    assert metadata["display_sync_enabled"] is False
    maxima = [0, 0, 0, 0]
    differing_pixels = 0
    failing_pixels = 0
    first_failure = None
    for offset in range(0, len(actual), 4):
        errors = [abs(actual[offset + channel] - expected[offset + channel]) for channel in range(4)]
        maxima = [max(maxima[channel], errors[channel]) for channel in range(4)]
        differing_pixels += int(any(errors))
        if max(errors) > 1:
            failing_pixels += 1
            if first_failure is None:
                pixel = offset // 4
                first_failure = {"x": pixel % width, "y": pixel // width,
                    "actual_rgba": list(actual[offset:offset + 4]), "expected_rgba": list(expected[offset:offset + 4])}
    result = {"frame_sequence": sequence, "resource_epoch": sequence // cadence,
        "reference_kind": "independent-scalar-float32-CPU-auxiliary-oracle",
        "is_guest_d3d11_reference": False, "pixel_count": width * height,
        "maximum_channel_error_lsb": max(maxima), "channel_maximum_errors_lsb": maxima,
        "differing_pixels": differing_pixels, "pixels_exceeding_one_lsb": failing_pixels,
        "first_failure": first_failure, "actual_rgba_sha256": sha256_bytes(actual),
        "cpu_oracle_rgba_sha256": sha256_bytes(expected), "resource_sha256": sha256_bytes(resource),
        "capture_metadata_sha256": sha256_file(capture.with_suffix(".json")), "passed": failing_pixels == 0}
    write_json(directory / f"frame-{sequence:06d}-cpu-comparison.json", result)
    if not result["passed"]:
        raise RuntimeError("real Metal pixels exceeded the auxiliary CPU oracle tolerance")
    return result


def validate_run(directory: Path, frames: int, seed: int, width: int, height: int,
                 cadence: int, captures: list[int], digests: dict, client_rows: list[dict]) -> dict:
    rows = read_host_rows(directory, frames)
    commands = command_batch(width)
    command_hash = fnv1a64(commands)
    for sequence, (host, client) in enumerate(zip(rows, client_rows)):
        update = sequence % cadence == 0
        expected_commands, expected_resources = (512, 65536) if update else (0, 0)
        expected_request = 32 + expected_commands + expected_resources
        assert host["frame_index"] == client["sequence"] == sequence
        assert host["protocol_version"] == 2 and host["offload_mode"] == "command-only"
        assert host["scene_draw_count"] == 16 and host["presentation_draw_count"] == 1
        assert host["pixel_bytes"] == 0 and host["resource_resident_bytes"] == 65536
        assert host["command_updated_bytes"] == client["command_bytes"] == expected_commands
        assert host["resource_updated_bytes"] == client["resource_bytes"] == expected_resources
        assert host["transferred_bytes_in"] == client["request_bytes"] == expected_request
        assert host["ack_bytes_out"] == client["ack_bytes"] == 56
        assert host["command_fnv1a64"] == command_hash
        assert host["resource_fnv1a64"] == fnv1a64(seeded_resource(seed, sequence // cadence))
        assert host["completion_scope"] == "gpu-command-complete"
        assert host["display_sync_enabled"] is False
        assert host["capture_enabled"] == (sequence in captures)
        assert host["host_binary_sha256"] == digests["metal_host_binary"]
        assert host["metal_command_complete_ms"] > 0 and client["host_gpu_ms"] > 0
        assert abs(host["metal_command_complete_ms"] - client["host_gpu_ms"]) < 0.0011
    comparisons = [compare_capture(directory, sequence, seed, width, height, cadence, digests) for sequence in captures]
    if all(frame in captures for frame in (0, 30, 31)):
        by_sequence = {row["frame_sequence"]: row for row in comparisons}
        assert by_sequence[0]["actual_rgba_sha256"] != by_sequence[30]["actual_rgba_sha256"]
        assert by_sequence[30]["actual_rgba_sha256"] == by_sequence[31]["actual_rgba_sha256"]
    gpu = [row["metal_command_complete_ms"] for row in rows]
    result = {"passed": True, "frame_count": frames, "seed": seed, "width": width, "height": height,
        "cadence": cadence, "scene_draw_count_each_frame": 16, "pixel_bytes_each_frame": 0,
        "ack_count": frames, "ack_bytes_each_frame": 56, "updated_frame_roundtrip_bytes": 66136,
        "retained_frame_roundtrip_bytes": 88,
        "application_frame_bytes_total": sum(row["request_bytes"] + row["ack_bytes"] for row in client_rows),
        "host_gpu_ms_minimum": min(gpu), "host_gpu_ms_median": statistics.median(gpu), "host_gpu_ms_maximum": max(gpu),
        "digests": digests, "captures": comparisons, "performance_measurement": False,
        "completion_scope": "gpu-command-complete", "display_sync_enabled": False,
        "guest_d3d11_pixel_validation_completed": False}
    write_json(directory / "validation.json", result)
    return result


def run_native(output: Path, port: int) -> dict:
    directory = output / "native-protocol"
    digests = start_local_receiver(directory, port, [0, 30, 31])
    pid = int((SCRIPT_DIR / "build" / "metal_host.pid").read_text().strip())
    try:
        client = run_client(port=port, frames=32, width=1280, height=720, seed=7,
                            command_every=30, resource_every=30)
        write_json(directory / "client.json", client)
        result = validate_run(directory, 32, 7, 1280, 720, 30, [0, 30, 31], digests, client["records"])
        result["client_kind"] = "independent-native-Python-wire-client"
        return result
    finally:
        stop_owned_receiver(pid)
        write_json(directory / "receiver-stop.json", {"stopped": True, "owned_receiver_only": True})


def run_wine_cpp(output: Path, port: int, frames: int) -> dict:
    import run_m0_fingerprints as m0
    import run_wine_benchmark as wine
    work = writable_path(SCRIPT_DIR / "build" / "m0-runtime" / "dxvk")
    prefix = work / "prefix"
    if not (prefix / "drive_c" / "windows" / "system32").is_dir():
        return {"skipped": True, "reason": "reusable M0 DXVK prefix was not available"}
    components = wine.resolve_wine_components(m0.discover_engine_root())
    env = wine._backend_env(components, "dxvk", prefix, work)
    env.update(runtime_environment(work))
    env.update({"WINEPREFIX": str(prefix), "USER": "runner-x", "LOGNAME": "runner-x"})
    try:
        idle = subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env,
                              capture_output=True, timeout=1)
    except subprocess.TimeoutExpired:
        return {"skipped": True, "reason": "M0 DXVK prefix was still active"}
    if idle.returncode:
        raise RuntimeError("DXVK prefix idle-state check failed")
    probe = SCRIPT_DIR / "build" / "d3d11_probe.exe"
    win_dir = prefix / "drive_c" / "graphics-lab" / "local-replay"
    win_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(probe, win_dir / "d3d11_probe.exe")
    assert sha256_file(probe) == sha256_file(win_dir / "d3d11_probe.exe")
    directory = output / f"cpp-dxvk-{frames}-frames"
    captures = [0, 2] if frames == 3 else [0, 30, 31]
    digests = start_local_receiver(directory, port, captures)
    pid = int((SCRIPT_DIR / "build" / "metal_host.pid").read_text().strip())
    digests.update({"d3d11_probe_cpp": sha256_file(SCRIPT_DIR / "d3d11_probe.cpp"),
                    "d3d11_probe_exe": sha256_file(probe)})
    try:
        windows_base = "C:" + "\\" + "graphics-lab" + "\\" + "local-replay" + "\\"
        args = [str(components["wine_bin"]), windows_base + "d3d11_probe.exe", "--frames", str(frames),
            "--warmup", "0", "--width", "1280", "--height", "720", "--commands", "16",
            "--resource-bytes", "65536", "--command-every", "30", "--resource-every", "30",
            "--resource-pattern", "seeded", "--seed", "7", "--offload-mode", "command-only",
            "--transport-host", "127.0.0.1", "--port", str(port), "--csv", windows_base + "frames.csv",
            "--metadata-json", windows_base + "metadata.json"]
        process = subprocess.run(args, cwd=work, env=env, capture_output=True, text=True, timeout=90)
        (directory / "stderr.log").write_text(redact_text(process.stderr))
        (directory / "stdout.log").write_text(redact_text(process.stdout))
        if process.returncode:
            raise RuntimeError("real C++ EXE command-only DXVK run failed")
        shutil.copy2(win_dir / "frames.csv", directory / "frames.csv")
        metadata = json.loads((win_dir / "metadata.json").read_text())
        write_json(directory / "metadata.json", metadata)
        assert metadata["offload_mode"] == "command-only" and metadata["resource_pattern"] == "seeded"
        with (directory / "frames.csv").open(newline="") as handle:
            csv_rows = list(csv.DictReader(handle))
        assert len(csv_rows) == frames
        client_rows = []
        for sequence, row in enumerate(csv_rows):
            assert row["gpu_ms"] == ""
            client_rows.append({"sequence": sequence, "host_gpu_ms": float(row["host_gpu_ms"]),
                "request_bytes": int(row["network_bytes_out"]), "ack_bytes": int(row["network_bytes_in"]),
                "command_bytes": int(row["command_bytes"]), "resource_bytes": int(row["resource_bytes"])})
        result = validate_run(directory, frames, 7, 1280, 720, 30, captures, digests, client_rows)
        result.update({"client_kind": "real-C++-EXE-under-host-Wine-DXVK", "environment": "host-wine",
                       "is_windows_guest_run": False, "engine_digests": components["digests"]})
        write_json(directory / "validation.json", result)
        return result
    finally:
        try:
            subprocess.run([str(components["wineserver_bin"]), "-k"], cwd=work, env=env,
                           capture_output=True, timeout=10)
            subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env,
                           capture_output=True, timeout=10)
        finally:
            stop_owned_receiver(pid)
            write_json(directory / "receiver-stop.json", {"stopped": True, "owned_receiver_only": True})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=EVIDENCE_DIR / "local-metal-protocol")
    parser.add_argument("--port", type=int, default=39003)
    parser.add_argument("--skip-wine", action="store_true")
    args = parser.parse_args()
    output = writable_path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        native = run_native(output, args.port)
        results.append(native)
        print(json.dumps({"stage": "native-protocol", "passed": True,
            "frames": 32, "maximum_error_lsb": max(c["maximum_channel_error_lsb"] for c in native["captures"])}), flush=True)
        if not args.skip_wine:
            for count in (3, 32):
                result = run_wine_cpp(output, args.port, count)
                results.append(result)
                print(json.dumps({"stage": f"cpp-dxvk-{count}-frames", "passed": result.get("passed", False),
                                  "skipped": result.get("skipped", False)}), flush=True)
        manifest = {"owner": "@DNPMBHC", "passed": True, "kind": "local-real-Metal-command-replay-validation",
            "runs": results, "validator_sha256": sha256_file(Path(__file__)), "digests": source_digests(),
            "guest_d3d11_reference_validated": False, "guest_paired_performance_measured": False,
            "reference_scope": "auxiliary CPU oracle only; Guest software reference remains required",
            "receivers_stopped": True}
        write_json(output / "manifest.json", manifest)
        return 0
    except Exception as error:
        failure = {"passed": False, "error": redact_text(str(error)), "completed_runs": results,
                   "guest_d3d11_reference_validated": False}
        write_json(output / "failure.json", failure)
        print(json.dumps(clean_value(failure)), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
