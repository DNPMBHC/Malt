#!/usr/bin/env python3
"""Runner for the 2,048-Draw-Call async SwapChain Real-3D high-stress baseline.

Runs Wine four-way backends (DXMT / D3DMetal / DXVK+KosmicKrisp / DXVK+MoltenVK) with host CPU
sampling and merges optional QEMU WHQL viogpu3d guest measurements into a unified SHA-256-bound
baseline manifest for Phase 5 Plan B evaluation.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import wine_kosmickrisp_benchmark as wkb
import bench_real3d_support as support
from bench_real3d_cpu import HostCPUSampler


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.resolve()
DEFAULT_PROBE_SRC = SCRIPT_DIR / "bench_real3d_probe.cpp"
DEFAULT_MINGW = Path("/opt/homebrew/bin/x86_64-w64-mingw32-g++")

WINE_ROTATIONS = (
    ("dxmt", "d3dmetal", "dxvk_kosmickrisp", "dxvk_moltenvk"),
    ("dxvk_kosmickrisp", "dxvk_moltenvk", "d3dmetal", "dxmt"),
    ("d3dmetal", "dxvk_kosmickrisp", "dxmt", "dxvk_moltenvk"),
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (p / 100.0) * (len(ordered) - 1)
    lo = int(math.floor(rank))
    hi = int(math.ceil(rank))
    if lo == hi:
        return ordered[lo]
    frac = rank - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def summarize_real3d_csv(csv_path: Path) -> dict[str, Any]:
    intervals: list[float] = []
    submits: list[float] = []
    rss_values: list[float] = []
    vram_values: list[float] = []
    with csv_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            idx = int(row["frame_index"])
            frame_ms = float(row["cpu_frame_ms"])
            submit_ms = float(row["cpu_submit_ms"])
            if idx > 0:
                intervals.append(frame_ms)
            submits.append(submit_ms)
            rss = int(row["resident_bytes"])
            vram = int(row["device_memory_bytes"])
            if rss > 0:
                rss_values.append(rss / (1024.0 * 1024.0))
            if vram > 0:
                vram_values.append(vram / (1024.0 * 1024.0))

    mean_interval = statistics.fmean(intervals) if intervals else None
    return {
        "frame_count": len(submits),
        "interval_sample_count": len(intervals),
        "derived_fps_from_intervals": (1000.0 / mean_interval) if mean_interval and mean_interval > 0 else None,
        "frame_interval_ms": {
            "mean": mean_interval,
            "p50": percentile(intervals, 50.0),
            "p95": percentile(intervals, 95.0),
            "p99": percentile(intervals, 99.0),
        },
        "cpu_submit_ms": {
            "mean": statistics.fmean(submits) if submits else None,
            "p95": percentile(submits, 95.0),
            "p99": percentile(submits, 99.0),
        },
        "process_resident_mib_mean": statistics.fmean(rss_values) if rss_values else None,
        "device_memory_mib_mean": statistics.fmean(vram_values) if vram_values else None,
    }


def parse_probe_json_lines(stdout_text: str) -> tuple[dict[str, Any], dict[str, Any]]:
    meta: dict[str, Any] = {}
    completion: dict[str, Any] = {}
    for line in stdout_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("real3d_metadata_json="):
            meta = json.loads(stripped.split("=", 1)[1])
        elif stripped.startswith("real3d_completion_json="):
            completion = json.loads(stripped.split("=", 1)[1])
    if not meta or not completion:
        raise RuntimeError("bench_real3d_probe output missing metadata or completion JSON")
    return meta, completion


def compile_probe_binary(
    src_path: Path = DEFAULT_PROBE_SRC,
    output_path: Path = Path("/tmp/bench_real3d_probe.exe"),
    mingw_bin: Path = DEFAULT_MINGW,
) -> Path:
    cmd = [
        str(mingw_bin),
        "-O2",
        "-std=c++17",
        str(src_path),
        "-o",
        str(output_path),
        "-static",
        "-static-libgcc",
        "-static-libstdc++",
        "-ld3d11",
        "-ldxgi",
        "-ld3dcompiler",
        "-lpsapi",
        "-luser32",
        "-lgdi32",
        "-lws2_32",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"failed to compile bench_real3d_probe.cpp: {proc.stderr[-800:]}")
    return output_path


def aggregate_arms(runs: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        grouped.setdefault(run["arm"], []).append(run)

    def mean_of(vals: list[float | None]) -> float | None:
        valid = [v for v in vals if v is not None]
        return statistics.fmean(valid) if valid else None

    out: dict[str, Any] = {}
    for arm, items in sorted(grouped.items()):
        out[arm] = {
            "rounds": len(items),
            "adapter_description": items[0]["metadata"].get("adapter_description"),
            "selected_feature_level": items[0]["metadata"].get("selected_feature_level"),
            "throughput_fps_mean": mean_of(
                [r["completion"].get("throughput_including_gpu_drain_fps") for r in items]
            ),
            "frame_interval_mean_ms_mean": mean_of(
                [r["csv_summary"]["frame_interval_ms"].get("mean") for r in items]
            ),
            "frame_interval_p50_ms_mean": mean_of(
                [r["csv_summary"]["frame_interval_ms"].get("p50") for r in items]
            ),
            "frame_interval_p95_ms_mean": mean_of(
                [r["csv_summary"]["frame_interval_ms"].get("p95") for r in items]
            ),
            "frame_interval_p99_ms_mean": mean_of(
                [r["csv_summary"]["frame_interval_ms"].get("p99") for r in items]
            ),
            "warmup_ms_mean": mean_of([r["completion"].get("warmup_ms") for r in items]),
            "gpu_drain_ms_mean": mean_of([r["completion"].get("gpu_drain_ms") for r in items]),
            "host_cpu_percent_mean": mean_of(
                [r["host_cpu"].get("host_cpu_percent_mean") for r in items]
            ),
            "host_capacity_percent_mean": mean_of(
                [r["host_cpu"].get("host_capacity_percent_mean") for r in items]
            ),
            "host_cpu_percent_peak_mean": mean_of(
                [r["host_cpu"].get("host_cpu_percent_peak") for r in items]
            ),
            "device_memory_mib_mean": mean_of(
                [r["csv_summary"].get("device_memory_mib_mean") for r in items]
            ),
            "process_resident_mib_mean": mean_of(
                [r["csv_summary"].get("process_resident_mib_mean") for r in items]
            ),
        }
    return out


def validate_baseline_runs(runs, workload, rounds, probe_sha256):
    """Refuse a five-way comparison assembled from incompatible experiments."""
    required={"wine_dxmt","wine_d3dmetal","wine_dxvk_kosmickrisp",
              "wine_dxvk_moltenvk","guest_qemu_viogpu3d"}
    pairs=set()
    for run in runs:
        pair=(run["arm"],run["round"])
        if pair in pairs or run["arm"] not in required:
            raise RuntimeError("Duplicate or unknown baseline arm/round")
        pairs.add(pair)
        meta,completion=run["metadata"],run["completion"]
        if run.get("probe_sha256") != probe_sha256:
            raise RuntimeError("Baseline executable binding mismatch")
        if (run.get("native_exit_code") != 0 or meta.get("adapter_is_software")
                or meta.get("draws_per_frame") != workload["draws"]
                or completion.get("measured_frames") != workload["frames"]
                or run["csv_summary"].get("frame_count") != workload["frames"]
                or not run["host_cpu"].get("sample_count")):
            raise RuntimeError("Baseline workload, exit or CPU evidence is incomplete")
        for requested, observed in (("width", "width"), ("height", "height"),
                                    ("cb_updates", "cb_updates_per_frame"),
                                    ("passes_per_frame", "passes_per_frame"),
                                    ("async_swapchain", "async_swapchain")):
            if requested in workload and meta.get(observed) != workload[requested]:
                raise RuntimeError("Baseline scene configuration mismatch")
    expected={(arm,index) for arm in required for index in range(1,rounds+1)}
    return pairs == expected


def run_wine_four_way_real3d(
    probe_exe: Path, output_dir: Path, workload: dict[str, int], rounds: int = 3,
    engine_root: Path = wkb.DEFAULT_ENGINE_ROOT,
    kosmickrisp_root: Path = wkb.DEFAULT_KOSMICKRISP_DIR,
    runtime_root: Path | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    components = wkb.resolve_four_way_components(engine_root=engine_root, kosmickrisp_root=kosmickrisp_root)
    output_dir.mkdir(parents=True, exist_ok=True)
    runtime_root = runtime_root or support.runtime_dir()
    runtime_root.mkdir(parents=True, exist_ok=True)
    runs = []
    for round_index in range(1, rounds + 1):
        for backend in WINE_ROTATIONS[(round_index - 1) % len(WINE_ROTATIONS)]:
            arm = "wine_" + backend
            stem = f"{arm}-r{round_index}"
            print(f"[real3d] round={round_index}/{rounds} arm={arm}", flush=True)
            with tempfile.TemporaryDirectory(prefix=stem+"-", dir=runtime_root) as tmp_name:
                work_dir = Path(tmp_name)
                prefix = wkb._prepare_prefix(components, backend, work_dir)
                env = wkb.build_backend_env(components, backend, prefix, work_dir, metalfx_preset="off")
                env["WINEDEBUG"] = "-all,+loaddll"
                tmp_csv = work_dir / (stem+".csv")
                cmd = [str(components["wine_bin"]), str(probe_exe),
                       "--width", str(workload["width"]), "--height", str(workload["height"]),
                       "--warmup", str(workload["warmup"]), "--frames", str(workload["frames"]),
                       "--draws", str(workload["draws"]), "--cb-updates", str(workload["cb_updates"]),
                       "--csv", wkb._to_wine_z_path(tmp_csv)]
                server = subprocess.Popen([str(components["wineserver_bin"]), "-f", "-p"],
                                          env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                proc = None
                cpu_stats = {}
                stdout_lines, stderr_lines = [], []
                sampler = None
                try:
                    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    sampler = HostCPUSampler((proc.pid,server.pid))
                    def collect_stdout():
                        nonlocal cpu_stats
                        for line in proc.stdout:
                            stdout_lines.append(line)
                            if line.startswith("real3d_measurement_begin="):
                                sampler.start()
                            elif line.startswith("real3d_completion_json="):
                                cpu_stats = sampler.stop()
                    def collect_stderr():
                        stderr_lines.extend(proc.stderr.readlines())
                    readers = [threading.Thread(target=collect_stdout),threading.Thread(target=collect_stderr)]
                    for reader in readers: reader.start()
                    proc.wait(timeout=300)
                    for reader in readers: reader.join(timeout=5)
                    if not cpu_stats and sampler._thread is not None:
                        cpu_stats = sampler.stop()
                    stdout = "".join(stdout_lines)
                    stderr = "".join(stderr_lines)
                    (output_dir / (stem+".stdout.log")).write_text(support.redact(stdout))
                    (output_dir / (stem+".stderr.log")).write_text(support.redact(stderr))
                    if proc.returncode or not tmp_csv.is_file():
                        raise RuntimeError(f"{stem} failed, native exit {proc.returncode}; see redacted logs")
                    if not cpu_stats.get("sample_count"):
                        raise RuntimeError(f"{stem} has no measurement-phase CPU accounting")
                    final_csv = output_dir / (stem+".csv")
                    shutil.copy2(tmp_csv, final_csv)
                    meta, completion = parse_probe_json_lines(stdout)
                    if meta.get("draws_per_frame") != workload["draws"] or completion.get("measured_frames") != workload["frames"] or meta.get("adapter_is_software"):
                        raise RuntimeError("Actual workload or adapter does not satisfy baseline")
                    backend_logs = []
                    for log in work_dir.rglob("*.log"):
                        dest = output_dir / (stem+"-"+log.name)
                        dest.write_text(support.redact(log.read_text(errors="replace")))
                        backend_logs.append({"file":dest.name,"sha256":sha256_file(dest)})
                    runs.append({"arm":arm,"domain":"host_wine","backend":backend,"round":round_index,
                                 "metadata":meta,"completion":completion,"csv_summary":summarize_real3d_csv(final_csv),
                                 "host_cpu":cpu_stats,"native_exit_code":proc.returncode,
                                 "probe_sha256":sha256_file(probe_exe),
                                 "backend_binding":{"dll_sha256":sha256_file(prefix/"drive_c/windows/system32/d3d11.dll"),
                                                    "requested_backend":backend,"library_load_log":stem+".stderr.log",
                                                    "backend_logs":backend_logs},
                                 "files":{"csv":final_csv.name,"csv_sha256":sha256_file(final_csv),
                                          "stdout":stem+".stdout.log","stderr":stem+".stderr.log"}})
                    support.write_json(output_dir / (stem+".json"),runs[-1])
                finally:
                    if proc is not None and proc.poll() is None:
                        proc.terminate()
                    if sampler is not None and sampler._thread is not None:
                        sampler.stop()
                    wkb._kill_wineserver(components["wineserver_bin"], prefix)
                    try: server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.terminate(); server.wait(timeout=10)
    return components, runs

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run 2,048-Draw-Call async Real-3D baseline")
    parser.add_argument("--probe-exe", type=Path, default=Path("/tmp/bench_real3d_probe.exe"))
    parser.add_argument("--probe-source", type=Path, default=DEFAULT_PROBE_SRC)
    parser.add_argument("--compile", action="store_true", help="Compile bench_real3d_probe.cpp first")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "handoff/phase-5/evidence/p5-a/real3d-runs",
    )
    parser.add_argument(
        "--manifest-out",
        type=Path,
        default=REPO_ROOT / "handoff/phase-5/evidence/p5-a/real3d-baseline.json",
    )
    parser.add_argument("--merge-guest-json", type=Path, default=None)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--frames", type=int, default=900)
    parser.add_argument("--draws", type=int, default=2048)
    parser.add_argument("--cb-updates", type=int, default=256)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    args = parser.parse_args(argv)

    probe_exe = args.probe_exe
    if args.compile or not probe_exe.is_file():
        probe_exe = compile_probe_binary(src_path=args.probe_source, output_path=probe_exe)

    workload = {
        "width": args.width,
        "height": args.height,
        "warmup": args.warmup,
        "frames": args.frames,
        "draws": args.draws,
        "cb_updates": args.cb_updates,
        "passes_per_frame": 2,
        "async_swapchain": True,
    }
    components, wine_runs = run_wine_four_way_real3d(
        probe_exe=probe_exe,
        output_dir=args.output_dir,
        workload=workload,
        rounds=args.rounds,
    )
    all_runs = list(wine_runs)
    extra_digests: dict[str, str] = {}
    if args.merge_guest_json is not None and args.merge_guest_json.is_file():
        guest_payload = json.loads(args.merge_guest_json.read_text(encoding="utf-8"))
        all_runs.extend(guest_payload.get("runs", []))
        extra_digests.update(guest_payload.get("digests", {}))

    comparison_valid=validate_baseline_runs(all_runs,workload,args.rounds,sha256_file(probe_exe))

    manifest = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "experiment": "phase5_real3d_async_swapchain_baseline",
        "five_way_comparison_valid": comparison_valid,
        "realWineExecuted": True,
        "realBenchmarkExecuted": True,
        "realGuestExecuted": any(r.get("domain") == "guest_qemu_viogpu3d" for r in all_runs),
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": wkb.collect_host_metadata(),
        "workload": workload,
        "rounds_per_arm": args.rounds,
        "versions": components["versions"],
        "immutable_digests": {
            "bench_real3d_probe_cpp": sha256_file(args.probe_source),
            "bench_real3d_runner_py": sha256_file(Path(__file__).resolve()),
            "bench_real3d_probe_exe": sha256_file(probe_exe),
            **components["digests"],
            **extra_digests,
        },
        "runs": all_runs,
        "aggregate": aggregate_arms(all_runs),
    }
    rendered = support.redact(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
    args.manifest_out.write_text(rendered, encoding="utf-8")
    print(json.dumps({"aggregate": manifest["aggregate"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
