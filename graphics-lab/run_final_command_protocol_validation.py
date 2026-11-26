#!/usr/bin/env python3
"""Validate final C++ command-only replay on 32 real host Metal GPU frames."""
from __future__ import annotations
import csv
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from benchmark_support import (EVIDENCE_DIR, SCRIPT_DIR, clean_value, redact_text,
    runtime_environment, sha256_file, source_digests, writable_path, write_json)
from run_local_replay_validation import start_local_receiver, stop_owned_receiver, validate_run
import run_m0_fingerprints as m0
import run_wine_benchmark as wine


def main() -> int:
    output = writable_path(EVIDENCE_DIR / "local-metal-protocol" / "final-command-protocol")
    if output.exists():
        raise RuntimeError("final command protocol evidence directory already exists")
    output.mkdir(parents=True)
    work = writable_path(SCRIPT_DIR / "build" / "final-timing-reference-runtime")
    prefix = work / "prefix"
    if not (prefix / "drive_c" / "windows" / "system32").is_dir():
        raise RuntimeError("independent DXVK prefix is unavailable")
    if (SCRIPT_DIR / "build" / "metal_host.pid").exists():
        raise RuntimeError("receiver ownership is already held")
    freeze = EVIDENCE_DIR / "m0-m2-final-source-freeze.json"
    frozen = json.loads(freeze.read_text())
    freeze_digest = sha256_file(freeze)
    digests = source_digests()
    for key in ("d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift", "metal_host_binary"):
        assert digests[key] == frozen["source_digests"][key]
    components = wine.resolve_wine_components(m0.discover_engine_root())
    env = runtime_environment(work)
    backend = wine._backend_env(components, "dxvk", prefix, work)
    env.update({key: value for key, value in backend.items() if key.startswith(("WINE", "DXVK"))})
    env.update({"WINEPREFIX": str(prefix), "USER": "runner-x", "LOGNAME": "runner-x"})
    idle = subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env,
                          capture_output=True, timeout=1)
    assert idle.returncode == 0
    probe = SCRIPT_DIR / "build" / "d3d11_probe.exe"
    win_dir = prefix / "drive_c" / "graphics-lab" / "final-command-protocol"
    win_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(probe, win_dir / "d3d11_probe.exe")
    assert sha256_file(win_dir / "d3d11_probe.exe") == digests["d3d11_probe_exe"]
    pid = None
    try:
        print(json.dumps({"stage": "rebuilding-and-restarting-receiver"}), flush=True)
        rebuilt = start_local_receiver(output, 39003, [0, 30, 31])
        pid = int((SCRIPT_DIR / "build" / "metal_host.pid").read_text().strip())
        for key in ("metal_host_swift", "metal_host_binary"):
            assert rebuilt[key] == frozen["source_digests"][key]
        digests.update(rebuilt)
        windows_base = "C:" + "\\" + "graphics-lab" + "\\" + "final-command-protocol" + "\\"
        args = [str(components["wine_bin"]), windows_base + "d3d11_probe.exe", "--frames", "32",
            "--warmup", "0", "--width", "1280", "--height", "720", "--commands", "16",
            "--resource-bytes", "65536", "--command-every", "30", "--resource-every", "30",
            "--resource-pattern", "seeded", "--seed", "7", "--offload-mode", "command-only",
            "--transport-host", "127.0.0.1", "--port", "39003", "--csv", windows_base + "frames.csv",
            "--metadata-json", windows_base + "metadata.json"]
        process = subprocess.run(args, cwd=work, env=env, capture_output=True, text=True, timeout=90)
        (output / "stderr.log").write_text(redact_text(process.stderr))
        (output / "stdout.log").write_text(redact_text(process.stdout))
        if process.returncode:
            raise RuntimeError("final C++ command-only DXVK run failed")
        shutil.copy2(win_dir / "frames.csv", output / "frames.csv")
        metadata = json.loads((win_dir / "metadata.json").read_text())
        write_json(output / "metadata.json", metadata)
        assert metadata["offload_mode"] == "command-only"
        assert metadata["resource_pattern"] == "seeded" and metadata["seed"] == 7
        with (output / "frames.csv").open(newline="") as handle:
            csv_rows = list(csv.DictReader(handle))
        assert len(csv_rows) == 32
        clients = []
        for sequence, row in enumerate(csv_rows):
            assert row["gpu_ms"] == ""
            clients.append({"sequence": sequence, "host_gpu_ms": float(row["host_gpu_ms"]),
                "request_bytes": int(row["network_bytes_out"]), "ack_bytes": int(row["network_bytes_in"]),
                "command_bytes": int(row["command_bytes"]), "resource_bytes": int(row["resource_bytes"])})
        print(json.dumps({"stage": "validating-32-real-metal-frames-and-captures"}), flush=True)
        result = validate_run(output, 32, 7, 1280, 720, 30, [0, 30, 31], digests, clients)
        reference_dir = EVIDENCE_DIR / "local-metal-protocol" / "final-timing-reference"
        reference_result = json.loads((reference_dir / "validation.json").read_text())
        actual = (output / "host-captures" / "frame-000000.rgba").read_bytes()
        reference = (reference_dir / "reference.rgba").read_bytes()
        assert reference_result["digests"]["d3d11_probe_exe"] == digests["d3d11_probe_exe"]
        assert reference_result["digests"]["metal_host_binary"] == digests["metal_host_binary"]
        assert len(actual) == len(reference) == 1280 * 720 * 4
        maximum = max(abs(a - b) for a, b in zip(actual, reference))
        assert maximum <= 1
        for key in ("d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift", "metal_host_binary"):
            assert source_digests()[key] == digests[key]
        assert sha256_file(freeze) == freeze_digest
        inputs = output / "inputs"
        inputs.mkdir()
        for name in ("d3d11_probe.cpp", "metal_host.swift", "run_final_command_protocol_validation.py",
                     "run_local_replay_validation.py", "command_protocol.py", "benchmark_support.py",
                     "build_metal_host.sh", "restart_metal_host.sh"):
            shutil.copy2(SCRIPT_DIR / name, inputs / name)
        shutil.copy2(freeze, inputs / "m0-m2-final-source-freeze.json")
        result.update({"owner": "@DNPMBHC", "client_kind": "real-final-C++-EXE-under-host-Wine-DXVK",
            "environment": "host-wine", "is_windows_guest_run": False,
            "guest_was_not_operated": True, "engine_digests": components["digests"],
            "freeze_sha256": freeze_digest, "validator_sha256": sha256_file(Path(__file__)),
            "scene_draw_count_total": 32 * 16, "presentation_draw_count_total": 32,
            "updated_frames": [0, 30], "retained_frame_count": 30,
            "independent_prefix": "graphics-lab/build/final-timing-reference-runtime/prefix",
            "main_m0_prefix_not_used_or_stopped": True, "receiver_rebuilt_and_restarted": True,
            "frame0_hardware_reference": {"reference_kind": reference_result["reference_kind"],
                "evidence_directory": "final-timing-reference", "maximum_channel_error_lsb": maximum,
                "actual_rgba_sha256": hashlib.sha256(actual).hexdigest(),
                "reference_rgba_sha256": hashlib.sha256(reference).hexdigest(),
                "reference_validation_sha256": sha256_file(reference_dir / "validation.json"),
                "is_windows_guest_run": False, "is_warp_software_reference": False}})
        write_json(output / "validation.json", result)
        print(json.dumps(clean_value({"stage": "validation-passed", "passed": True, "frame_count": 32,
            "scene_draw_count_total": 512, "maximum_cpu_auxiliary_error_lsb":
            max(c["maximum_channel_error_lsb"] for c in result["captures"]),
            "frame0_hardware_reference_error_lsb": maximum, "digests": digests})), flush=True)
        return 0
    finally:
        try:
            subprocess.run([str(components["wineserver_bin"]), "-k"], cwd=work, env=env,
                           capture_output=True, timeout=10)
            stopped = subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env,
                                     capture_output=True, timeout=10)
            assert stopped.returncode == 0
        finally:
            if pid is not None:
                stop_owned_receiver(pid)
            write_json(output / "cleanup.json", {"owner": "@DNPMBHC", "receiver_stopped": pid is not None,
                "owned_receiver_executable_verified": pid is not None, "independent_prefix_idle": True,
                "main_m0_prefix_not_used_or_stopped": True, "guest_was_not_operated": True,
                "receiver_pid_file_absent": not (SCRIPT_DIR / "build" / "metal_host.pid").exists()})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        output = writable_path(EVIDENCE_DIR / "local-metal-protocol" / "final-command-protocol")
        output.mkdir(parents=True, exist_ok=True)
        failure = {"passed": False, "error": redact_text(str(error)), "is_windows_guest_run": False}
        write_json(output / "failure.json", failure)
        print(json.dumps(clean_value(failure)), flush=True)
        raise SystemExit(1)
