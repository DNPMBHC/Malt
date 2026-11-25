"""Host-only evidence validation. Owner: @DNPMBHC."""
from __future__ import annotations
import hashlib
import json
import math
import re
from pathlib import Path


def redact(text: str, workspace: Path | None = None) -> str:
    if workspace:
        for directory in workspace.iterdir():
            if directory.is_dir() and (directory / ".swiftlint.yml").is_file():
                text = text.replace(str(directory), "<module-x>").replace(directory.name, "module-x")
        text = text.replace(str(workspace), "<workspace>")
    text = text.replace(str(Path.home()), "<home>")
    text = re.sub(r"/(?:Users|Volumes|Applications|private|var|tmp)/[^\s\"'<>]+", "<local-path>", text)
    return text


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def save_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def validate_sample(sample: dict) -> None:
    for field in ("width", "height", "drawCalls", "frames"):
        if isinstance(sample.get(field), bool) or not isinstance(sample.get(field), int) or sample[field] <= 0:
            raise ValueError("invalid workload field: " + field)
    warmup = sample.get("warmupFrames")
    if isinstance(warmup, bool) or not isinstance(warmup, int) or warmup < 0:
        raise ValueError("nonnegative integer warmup required")
    for field in ("meanMs", "p50Ms", "p95Ms", "p99Ms", "fps", "wallMs"):
        number = sample.get(field)
        if isinstance(number, bool) or not isinstance(number, (float, int)) or not math.isfinite(number) or number <= 0:
            raise ValueError("invalid timing field: " + field)
    if sample.get("metalAPI") != "Metal4" or sample.get("gpuCompletionBoundary") != "MTLSharedEvent":
        raise ValueError("actual Metal4 GPU completion required")
    total = sample["frames"] + sample["warmupFrames"]
    if sample.get("gpuCompletedFrames") != total or sample.get("submittedCommands") != total * sample["drawCalls"]:
        raise ValueError("GPU completion or draw count mismatch")
    latencies = sample.get("frameLatenciesMs", [])
    if len(latencies) != sample["frames"] or any(not math.isfinite(number) or number <= 0 for number in latencies):
        raise ValueError("complete finite per-frame latency series required")
    if not math.isclose(sample["meanMs"], sum(latencies) / len(latencies), rel_tol=1e-6):
        raise ValueError("mean must match recorded frame latencies")
    for field in ("cpuUserMs", "cpuSysMs", "hostCpuPercent"):
        value = sample.get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError("finite nonnegative CPU telemetry required")
    expected_cpu = (sample["cpuUserMs"] + sample["cpuSysMs"]) / sample["wallMs"] * 100
    if not math.isclose(sample["hostCpuPercent"], expected_cpu, rel_tol=1e-6, abs_tol=1e-6):
        raise ValueError("CPU percentage must match process times")
    if not re.fullmatch(r"[0-9a-f]{64}", sample.get("imageSHA256", "")):
        raise ValueError("full-frame digest required")
    if not math.isclose(sample["fps"], sample["frames"] * 1000 / sample["wallMs"], rel_tol=1e-6):
        raise ValueError("throughput must include GPU drain")


def compare_pair(native: dict, ipc: dict, worker: dict) -> dict:
    validate_sample(native)
    validate_sample(ipc)
    for field in ("width", "height", "drawCalls", "frames", "warmupFrames"):
        if native[field] != ipc[field]:
            raise ValueError("incomparable workload: " + field)
    if native["imageSHA256"] != ipc["imageSHA256"] or ipc["imageSHA256"] != worker.get("imageSHA256"):
        raise ValueError("renderer/client/full-frame pixel digest mismatch")
    if worker.get("measurementFrames") != ipc["frames"]:
        raise ValueError("worker CPU measurement boundary mismatch")
    if not native.get("ringAliasesMetalMemory") or not native.get("zeroCopySurfaceActive"):
        raise ValueError("native shared-memory alias proof required")
    if worker.get("framesRendered") != ipc["frames"] + ipc["warmupFrames"]:
        raise ValueError("worker total rendered frame count mismatch")
    for field in ("cpuUserMs", "cpuSysMs"):
        value = worker.get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError("worker CPU invalid")
    worker_cpu = worker["cpuUserMs"] + worker["cpuSysMs"]
    ipc_cpu = (worker_cpu + ipc["cpuUserMs"] + ipc["cpuSysMs"]) / ipc["wallMs"] * 100
    acknowledgement_only = ipc.get("mode") == "multi_process_ipc_ack"
    if acknowledgement_only and ipc.get("image_validation_origin") != "renderer_worker":
        raise ValueError("ACK-only image validation must originate at the renderer")
    return {
        "scope": "host_synthetic_socket_ack_vs_in_process" if acknowledgement_only
                 else "host_synthetic_socket_copy_vs_in_process",
        "real_qemu_comparison": False,
        "mean_latency_saved_ms": ipc["meanMs"] - native["meanMs"],
        "p99_native_ms": native["p99Ms"],
        "p99_ipc_ms": ipc["p99Ms"],
        "native_cpu_percent_one_core": native["hostCpuPercent"],
        "ipc_cpu_percent_one_core_total": ipc_cpu,
        "cpu_percentage_points_saved": ipc_cpu - native["hostCpuPercent"],
        "identical_full_frame_sha256": native["imageSHA256"],
        "ipc_pixel_payload_bytes_per_frame": 0 if acknowledgement_only else ipc["width"] * ipc["height"] * 4,
        "pixel_validation_scope": "renderer_worker" if acknowledgement_only else "client_and_worker",
        "native_cpu_ms_per_frame": (native["cpuUserMs"] + native["cpuSysMs"]) / native["frames"],
        "ipc_cpu_ms_per_frame_total": (worker_cpu + ipc["cpuUserMs"] + ipc["cpuSysMs"]) / ipc["frames"],
        "ipc_command_payload_bytes_per_frame": ipc["drawCalls"] * 16,
        "native_cpu_pixel_payload_bytes_per_frame": 0,
    }
