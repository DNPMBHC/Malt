#!/usr/bin/env python3
"""Compare real host DXVK D3D11 capture with an existing final Metal replay capture."""
from __future__ import annotations
import csv
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from benchmark_support import (EVIDENCE_DIR, SCRIPT_DIR, clean_value, redact_text,
    runtime_environment, sha256_file, writable_path, write_json)
import run_m0_fingerprints as m0
import run_wine_benchmark as wine


def main() -> int:
    output = writable_path(EVIDENCE_DIR / "local-metal-protocol" / "final-timing-reference")
    output.mkdir(parents=True, exist_ok=True)
    work = writable_path(SCRIPT_DIR / "build" / "final-timing-reference-runtime")
    work.mkdir(parents=True, exist_ok=True)
    prefix = work / "prefix"
    components = wine.resolve_wine_components(m0.discover_engine_root())
    env = runtime_environment(work)
    backend_environment = wine._backend_env(components, "dxvk", prefix, work)
    env.update({key: value for key, value in backend_environment.items()
                if key.startswith(("WINE", "DXVK"))})
    env.update({"WINEPREFIX": str(prefix), "USER": "runner-x", "LOGNAME": "runner-x"})
    source = SCRIPT_DIR / "d3d11_probe.cpp"
    binary = SCRIPT_DIR / "build" / "d3d11_probe.exe"
    metal_source = SCRIPT_DIR / "metal_host.swift"
    metal_binary = SCRIPT_DIR / "build" / "metal_host"
    digests = {"d3d11_probe_cpp": sha256_file(source), "d3d11_probe_exe": sha256_file(binary),
        "metal_host_swift": sha256_file(metal_source), "metal_host_binary": sha256_file(metal_binary),
        "reference_validator_py": sha256_file(Path(__file__))}
    frozen = json.loads((EVIDENCE_DIR / "m0-m2-final-source-freeze.json").read_text())
    for key in ["d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift", "metal_host_binary"]:
        assert digests[key] == frozen["source_digests"][key]
    freeze_digest = sha256_file(EVIDENCE_DIR / "m0-m2-final-source-freeze.json")
    idle = subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env,
                          capture_output=True, timeout=1)
    if idle.returncode:
        raise RuntimeError("independent DXVK prefix was not idle")
    if not (prefix / "drive_c" / "windows" / "system32").is_dir():
        init = subprocess.run([str(components["wine_bin"]), "wineboot", "--init"],
                              cwd=work, env=env, capture_output=True, text=True, timeout=60)
        (output / "wineboot-stderr.log").write_text(redact_text(init.stderr))
        (output / "wineboot-stdout.log").write_text(redact_text(init.stdout))
        subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env,
                       capture_output=True, timeout=30)
    system32 = prefix / "drive_c" / "windows" / "system32"
    if not system32.is_dir():
        raise RuntimeError("independent Wine prefix initialization failed")
    for dll in (components["dxvk_root"] / "wine" / "x86_64-windows").glob("*.dll"):
        shutil.copy2(dll, system32 / dll.name)
    installed = prefix / "drive_c" / "graphics-lab" / "local-replay" / "d3d11_probe.exe"
    installed.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, installed)
    assert sha256_file(installed) == digests["d3d11_probe_exe"]
    separator = "\\"
    base = "C:" + separator + "graphics-lab" + separator
    try:
        process = subprocess.run([str(components["wine_bin"]), base + "local-replay" + separator + "d3d11_probe.exe",
            "--frames", "1", "--warmup", "0", "--width", "1280", "--height", "720",
            "--commands", "16", "--resource-bytes", "65536", "--resource-pattern", "seeded", "--seed", "7",
            "--driver-type", "hardware", "--completion-mode", "gpu-complete",
            "--capture-rgba", base + "reference.rgba", "--capture-frame", "0",
            "--csv", base + "reference.csv", "--metadata-json", base + "reference-metadata.json"],
            cwd=work, env=env, capture_output=True, text=True, timeout=60)
        (output / "stderr.log").write_text(redact_text(process.stderr))
        (output / "stdout.log").write_text(redact_text(process.stdout))
        if process.returncode:
            raise RuntimeError("real host D3D11 hardware reference capture failed")
        windows_directory = prefix / "drive_c" / "graphics-lab"
        for name in ["reference.rgba", "reference.csv"]:
            shutil.copy2(windows_directory / name, output / name)
        metadata = json.loads((windows_directory / "reference-metadata.json").read_text())
        write_json(output / "metadata.json", metadata)
        assert metadata["requested_driver_type"] == "hardware"
        assert metadata["completion_mode"] == "gpu-complete"
        assert metadata["resource_pattern"] == "seeded" and metadata["seed"] == 7
        assert not metadata["adapter_flags"] & 2
        reference = (output / "reference.rgba").read_bytes()
        metal_directory = EVIDENCE_DIR / "local-metal-protocol" / "cpp-dxvk-32-frames" / "host-captures"
        metal = (metal_directory / "frame-000000.rgba").read_bytes()
        metal_metadata = json.loads((metal_directory / "frame-000000.json").read_text())
        assert len(reference) == len(metal) == 1280 * 720 * 4
        assert metal_metadata["host_binary_sha256"] == digests["metal_host_binary"]
        assert sha256_file(source) == digests["d3d11_probe_cpp"] and sha256_file(binary) == digests["d3d11_probe_exe"]
        assert sha256_file(metal_source) == digests["metal_host_swift"]
        assert sha256_file(metal_binary) == digests["metal_host_binary"]
        assert sha256_file(EVIDENCE_DIR / "m0-m2-final-source-freeze.json") == freeze_digest
        maxima = [max(abs(reference[i] - metal[i]) for i in range(channel, len(reference), 4)) for channel in range(4)]
        maximum = max(maxima)
        different_pixels = sum(any(reference[i + c] != metal[i + c] for c in range(4)) for i in range(0, len(reference), 4))
        failures = 0
        first_failure = None
        if maximum > 1:
            for offset in range(0, len(reference), 4):
                if max(abs(reference[offset + c] - metal[offset + c]) for c in range(4)) > 1:
                    failures += 1
                    if first_failure is None:
                        pixel = offset // 4
                        first_failure = {"x": pixel % 1280, "y": pixel // 1280,
                            "reference_rgba": list(reference[offset:offset + 4]), "metal_rgba": list(metal[offset:offset + 4])}
        with (output / "reference.csv").open(newline="") as handle:
            rows = list(csv.DictReader(handle))
        assert len(rows) == 1 and float(rows[0]["gpu_ms"]) > 0
        inputs = output / "inputs"
        inputs.mkdir(exist_ok=True)
        for name in ["d3d11_probe.cpp", "metal_host.swift", "run_final_timing_reference_validation.py"]:
            shutil.copy2(SCRIPT_DIR / name, inputs / name)
        shutil.copy2(EVIDENCE_DIR / "m0-m2-final-source-freeze.json", inputs / "m0-m2-final-source-freeze.json")
        result = {"passed": maximum <= 1, "reference_kind": "real-D3D11-hardware-API-under-host-Wine-DXVK",
            "is_windows_guest_run": False, "is_warp_software_reference": False,
            "pixel_count": 1280 * 720, "maximum_channel_error_lsb": maximum,
            "channel_maximum_errors_lsb": maxima, "differing_pixels": different_pixels,
            "pixels_exceeding_one_lsb": failures, "first_failure": first_failure,
            "reference_rgba_sha256": hashlib.sha256(reference).hexdigest(),
            "metal_rgba_sha256": hashlib.sha256(metal).hexdigest(),
            "reference_gpu_ms": float(rows[0]["gpu_ms"]), "digests": digests,
            "engine_digests": components["digests"], "reference_adapter_description": metadata["adapter_description"],
            "reference_adapter_software_flag": False, "metal_capture": "cpp-dxvk-32-frames/host-captures/frame-000000.rgba",
            "guest_d3d11_software_reference_still_required": True, "receiver_was_not_started": True,
            "independent_prefix": "graphics-lab/build/final-timing-reference-runtime/prefix",
            "main_m0_prefix_not_used": True, "freeze_sha256": freeze_digest,
            "timing_scope": "per-frame GPU completion; timestamp query extraction excluded"}
        write_json(output / "validation.json", result)
        if not result["passed"]:
            raise RuntimeError("hardware D3D11 to Metal pixel tolerance failed")
        print(json.dumps(clean_value(result)), flush=True)
        return 0
    finally:
        subprocess.run([str(components["wineserver_bin"]), "-k"], cwd=work, env=env, capture_output=True, timeout=10)
        subprocess.run([str(components["wineserver_bin"]), "-w"], cwd=work, env=env, capture_output=True, timeout=10)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        output = writable_path(EVIDENCE_DIR / "local-metal-protocol" / "final-timing-reference")
        write_json(output / "failure.json", {"passed": False, "error": redact_text(str(error)), "is_windows_guest_run": False})
        print(json.dumps({"passed": False, "error": redact_text(str(error))}), flush=True)
        raise SystemExit(1)
