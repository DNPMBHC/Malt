#!/usr/bin/env python3
"""Compare real Guest D3D11 WARP frames against real host Metal command replay."""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
from pathlib import Path
from benchmark_support import (SCRIPT_DIR, EVIDENCE_DIR, GUEST_DIR, GuestSession,
    discover_started_vm, discover_utmctl, fingerprint, source_digests, sha256_file,
    start_metal_host, stop_metal_host, writable_path, write_json, redact_text,
    validate_guest_environment, validate_probe_metadata)
from command_protocol import seeded_resource, command_batch
from guest_preflight import collect_preflight
from pixel_compare import compare_rgba
from run_guest_m2_benchmark import read_host_rows, snapshot_inputs, validate_host_identity

CASES = (("legacy", 0), ("seeded", 0), ("seeded", 30), ("seeded", 31))

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=EVIDENCE_DIR / "m2-pixel-validation")
    parser.add_argument("--host-ip", default="192.168.64.1")
    parser.add_argument("--port", type=int, default=39003)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    output = writable_path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    cases = []
    receiver_active = False
    exit_code = 1
    try:
        utmctl = discover_utmctl()
        guest = GuestSession(utmctl, discover_started_vm(utmctl))
        guest_metadata = guest.metadata()
        validate_guest_environment(guest_metadata)
        collect_preflight(guest, output / "preflight-initial")
        probe_digest = guest.prepare_probe(SCRIPT_DIR / "build" / "d3d11_probe.exe")
        inputs = snapshot_inputs(output)
        bound_inputs = source_digests()
        expected_session = None
        for pattern, sequence in CASES:
            stem = "validate-" + pattern + "-" + str(sequence)
            case_dir = output / stem
            case_dir.mkdir(parents=True, exist_ok=True)
            preflight = collect_preflight(guest, case_dir / "preflight-reference")
            common = ["--frames", str(sequence + 1), "--warmup", "0", "--width", "1280", "--height", "720",
                "--commands", "16", "--resource-bytes", "65536", "--command-every", "30",
                "--resource-every", "30", "--resource-pattern", pattern, "--seed", str(args.seed),
                "--completion-mode", "gpu-complete"]
            reference_name = stem + "-reference.rgba"
            reference_meta_name = stem + "-reference.json"
            reference_csv_name = stem + "-reference.csv"
            reference_args = common + ["--driver-type", "warp",
                "--capture-rgba", GUEST_DIR + "\\" + reference_name, "--capture-frame", str(sequence),
                "--metadata-json", GUEST_DIR + "\\" + reference_meta_name,
                "--csv", GUEST_DIR + "\\" + reference_csv_name]
            reference_execution = guest.run_interactive(stem + "-reference", reference_args, case_dir,
                [reference_name, reference_meta_name, reference_csv_name])
            reference_metadata = json.loads((case_dir / reference_meta_name).read_text())
            expected = {"width": 1280, "height": 720, "commands": 16,
                "resource_bytes": 65536, "command_every": 30, "resource_every": 30,
                "resource_pattern": pattern, "seed": args.seed, "completion_mode": "gpu-complete"}
            validate_probe_metadata(reference_metadata, {**expected, "requested_driver_type": "warp",
                "capture_requested": True, "capture_frame": sequence,
                "transport_mode": "direct_present", "offload_mode": "pixel-readback"})
            reference_adapter = fingerprint(reference_metadata)
            if reference_adapter["requested_driver_type"] != "warp" or not reference_adapter["adapter_software_flag"]:
                raise RuntimeError("reference frame is not an explicitly selected software adapter")
            replay_preflight = collect_preflight(guest, case_dir / "preflight-replay")
            receiver_active = True
            receiver = start_metal_host(case_dir, "command-only", args.host_ip, args.port,
                capture_frames=[sequence])
            shutil.copy2(SCRIPT_DIR / "build" / "metal_host", case_dir / "metal_host")
            replay_meta_name = stem + "-replay.json"
            replay_csv_name = stem + "-replay.csv"
            replay_args = common + ["--offload-mode", "command-only", "--transport-host", args.host_ip,
                "--port", str(args.port), "--metadata-json", GUEST_DIR + "\\" + replay_meta_name,
                "--csv", GUEST_DIR + "\\" + replay_csv_name]
            replay_execution = guest.run_interactive(stem + "-replay", replay_args, case_dir,
                [replay_meta_name, replay_csv_name])
            replay_metadata = json.loads((case_dir / replay_meta_name).read_text())
            validate_probe_metadata(replay_metadata, {**expected, "requested_driver_type": "hardware",
                "capture_requested": False, "transport_mode": "offload_tcp", "offload_mode": "command-only"})
            replay_adapter = fingerprint(replay_metadata)
            session = reference_adapter["windows_session_id"]
            if session != preflight["console_session_id"] or replay_adapter["windows_session_id"] != replay_preflight["console_session_id"] or replay_adapter["windows_session_id"] != session or (
                expected_session is not None and expected_session != session):
                raise RuntimeError("reference and replay changed the actual interactive Windows session")
            expected_session = session
            host_rows = read_host_rows(case_dir / "host.jsonl", sequence + 1)
            validate_host_identity(host_rows, receiver)
            capture = case_dir / "host-captures" / f"frame-{sequence:06d}.rgba"
            capture_metadata_path = capture.with_suffix(".json")
            capture_metadata = json.loads(capture_metadata_path.read_text())
            if (capture_metadata.get("frame_sequence"), capture_metadata.get("width"),
                capture_metadata.get("height"), capture_metadata.get("offload_mode")) != (
                sequence, 1280, 720, "command-only"):
                raise RuntimeError("Metal capture scene or sequence differs from the reference")
            expected_resource = (seeded_resource(args.seed, sequence // 30) if pattern == "seeded"
                                 else bytes((i * 31 + 7) & 255 for i in range(65536)))
            if capture_metadata["resource_sha256"] != hashlib.sha256(expected_resource).hexdigest():
                raise RuntimeError("Metal capture used a different resource epoch")
            if capture_metadata["command_sha256"] != hashlib.sha256(command_batch(1280)).hexdigest():
                raise RuntimeError("Metal capture used a different command batch")
            if capture_metadata["scene_draw_count"] != 16 or capture_metadata["pixel_format"] != "rgba8Unorm":
                raise RuntimeError("capture is not the native 16-draw RGBA replay target")
            if capture_metadata.get("device") != "Apple M4" or capture_metadata.get("completion_scope") != "gpu-command-complete":
                raise RuntimeError("capture GPU or completion scope differs from the required Metal execution")
            if capture_metadata["host_binary_sha256"] != receiver["metal_host_binary"]:
                raise RuntimeError("capture binary SHA differs from the restarted receiver")
            comparison = compare_rgba((case_dir / reference_name).read_bytes(), capture.read_bytes(), 1280, 720, 1)
            if capture_metadata["rgba_sha256"] != comparison["actual_sha256"]:
                raise RuntimeError("capture file SHA differs from its rendering metadata")
            if any(source_digests()[key] != bound_inputs[key] for key in (
                "d3d11_probe_cpp", "d3d11_probe_exe", "metal_host_swift", "analyze_py", "benchmark_support_py")):
                raise RuntimeError("validation inputs changed during capture")
            case = {"pattern": pattern, "seed": args.seed, "frame_sequence": sequence,
                "reference": "actual Guest D3D11 software rendering",
                "actual": "actual Apple M4 Metal render target",
                "reference_adapter": reference_adapter, "replay_adapter": replay_adapter,
                "reference_preflight": preflight, "replay_preflight": replay_preflight,
                "reference_execution": reference_execution, "replay_execution": replay_execution,
                "receiver": receiver, "source_digests": source_digests(),
                "capture_metadata": capture_metadata, "comparison": comparison,
                "artifacts": {path.relative_to(case_dir).as_posix(): sha256_file(path) for path in (
                    case_dir / reference_name, case_dir / reference_meta_name, case_dir / reference_csv_name,
                    case_dir / replay_meta_name, case_dir / replay_csv_name,
                    case_dir / (stem + "-reference.stderr.log"), case_dir / (stem + "-replay.stderr.log"),
                    capture, capture_metadata_path, case_dir / "metal_host", case_dir / "receiver-start.json")},
                "host_jsonl_sha256": sha256_file(case_dir / "host.jsonl"),
                "performance_sample": False, "performance_measurement": False}
            write_json(case_dir / "comparison.json", case)
            cases.append(case)
            stop_metal_host()
            receiver_active = False
            print(json.dumps({"pattern": pattern, "frame_sequence": sequence, "passed": comparison["passed"],
                "max_channel_error": comparison["max_channel_error"],
                "compared_pixels": comparison["compared_pixels"]}), flush=True)
            if not comparison["passed"]:
                raise RuntimeError("real cross-API pixels exceeded one LSB")
        write_json(output / "manifest.json", {"schema_version":1,"complete":True,"passed":True,
            "owner":"@DNPMBHC","probe_binary_sha256":probe_digest,"source_digests":source_digests(),
            "inputs":inputs,"guest":guest_metadata,
            "windows_session_id":expected_session,"cases":cases,"performance_samples":False,
            "performance_measurement":False})
        exit_code = 0
    except Exception as error:
        write_json(output / "failure.json", {"complete":False,"error":redact_text(str(error)),"completed_cases":cases})
        print(json.dumps({"complete":False,"error":redact_text(str(error))}),flush=True)
    finally:
        if receiver_active:
            try:
                stop_metal_host()
            except Exception as error:
                write_json(output / "cleanup-failure.json", {"complete":False,
                    "error":redact_text(str(error)),"completed_cases":len(cases)})
                print(json.dumps({"complete":False,"cleanup_error":redact_text(str(error))}),flush=True)
                exit_code = 1
    return exit_code
if __name__ == "__main__":
    raise SystemExit(main())
