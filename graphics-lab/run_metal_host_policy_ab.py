#!/usr/bin/env python3
"""Run controlled A/B and fallback benchmarks for metal_host.swift dynamic resource policy."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import analyze

SCRIPT_DIR = Path(__file__).resolve().parent


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stop_metal_host() -> None:
    pid_file = SCRIPT_DIR / "build/metal_host.pid"
    if pid_file.is_file():
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(pid, signal.SIGTERM)
            for _ in range(20):
                try:
                    os.kill(pid, 0)
                    time.sleep(0.05)
                except OSError:
                    break
        except (ValueError, OSError):
            pass
        pid_file.unlink(missing_ok=True)
    subprocess.run(["pkill", "-f", str(SCRIPT_DIR / "build/metal_host")], capture_output=True, check=False)


def parse_host_jsonl(path: Path) -> dict[str, Any]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    measured = [r for r in rows if not r.get("warmup", False)]
    receive_ms = [float(r["host_receive_to_present_complete_ms"]) for r in measured]
    gpu_ms = [float(r["metal_command_complete_ms"]) for r in measured if r.get("metal_command_complete_ms") is not None]
    pacing_ms = [float(r.get("pacing_sleep_ms", 0.0)) for r in measured]
    render_paths: dict[str, int] = {}
    policy_modes: dict[str, int] = {}
    for r in measured:
        rp = str(r.get("render_path", "unknown"))
        pm = str(r.get("policy_mode", "unknown"))
        render_paths[rp] = render_paths.get(rp, 0) + 1
        policy_modes[pm] = policy_modes.get(pm, 0) + 1
    return {
        "measured_frames": len(measured),
        "host_receive_to_present_ms": analyze.distribution(receive_ms),
        "metal_gpu_ms": analyze.distribution(gpu_ms),
        "pacing_sleep_ms": analyze.distribution(pacing_ms),
        "render_path_counts": render_paths,
        "policy_mode_counts": policy_modes,
        "policy_qos_values": sorted({str(r.get("policy_qos", "")) for r in measured}),
        "target_fps_caps": sorted({r.get("target_fps_cap") for r in measured}, key=lambda v: -1 if v is None else int(v)),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--frames", type=int, default=90)
    parser.add_argument("--warmup", type=int, default=15)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--port", type=int, default=39013)
    args = parser.parse_args(argv)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    arms = [
        ("baseline-off", ["--resource-policy", "off", "--metalfx", "off"]),
        ("maxperf-metalfx-spatial", ["--resource-policy", "maximum-performance", "--metalfx", "spatial"]),
        ("balanced-60fps", ["--resource-policy", "balanced", "--metalfx", "spatial"]),
        ("conserve-30fps", ["--resource-policy", "conserve-energy", "--metalfx", "spatial"]),
        ("fallback-off", ["--resource-policy", "off", "--metalfx", "off"]),
    ]

    runs: list[dict[str, Any]] = []
    source_sha = ""
    binary_sha = ""

    try:
        for round_idx in range(1, args.rounds + 1):
            for arm_name, policy_args in arms:
                stem = f"{arm_name}-r{round_idx}"
                jsonl_path = args.output_dir / f"{stem}-host.jsonl"
                csv_path = args.output_dir / f"{stem}-client.csv"

                print(f"[metal-host-ab] round {round_idx}/{args.rounds} arm={arm_name} restarting metal_host...", flush=True)
                restart_proc = subprocess.run(
                    [
                        str(SCRIPT_DIR / "restart_metal_host.sh"),
                        "--bind", "127.0.0.1",
                        "--port", str(args.port),
                        "--jsonl", str(jsonl_path),
                        *policy_args,
                    ],
                    capture_output=True, text=True, check=False,
                )
                if restart_proc.returncode != 0:
                    raise RuntimeError(f"restart_metal_host failed for {stem}: {restart_proc.stderr}")

                for line in restart_proc.stdout.splitlines():
                    if line.startswith("source_sha256="):
                        source_sha = line.partition("=")[2].strip()
                    elif line.startswith("binary_sha256="):
                        binary_sha = line.partition("=")[2].strip()

                client_proc = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT_DIR / "synthetic_client.py"),
                        "--host", "127.0.0.1",
                        "--port", str(args.port),
                        "--frames", str(args.frames),
                        "--warmup", str(args.warmup),
                        "--width", str(args.width),
                        "--height", str(args.height),
                        "--commands", "16",
                        "--resource-bytes", "65536",
                        "--csv", str(csv_path),
                    ],
                    capture_output=True, text=True, check=False,
                )
                if client_proc.returncode != 0:
                    raise RuntimeError(f"synthetic_client failed for {stem}: {client_proc.stderr}")

                stop_metal_host()

                with csv_path.open("r", encoding="utf-8-sig", newline="") as stream:
                    rows = analyze.load_rows(stream)
                client_summary = analyze.summarize(rows)
                host_summary = parse_host_jsonl(jsonl_path)

                runs.append({
                    "arm": arm_name,
                    "round": round_idx,
                    "policy_args": policy_args,
                    "client_summary": client_summary,
                    "host_summary": host_summary,
                    "files": {
                        "client_csv": csv_path.name,
                        "client_csv_sha256": sha256_file(csv_path),
                        "host_jsonl": jsonl_path.name,
                        "host_jsonl_sha256": sha256_file(jsonl_path),
                    },
                })
    finally:
        stop_metal_host()

    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        grouped.setdefault(run["arm"], []).append(run)

    aggregate: dict[str, Any] = {}
    for arm_name, items in grouped.items():
        aggregate[arm_name] = {
            "rounds": len(items),
            "derived_fps_mean": statistics.fmean(
                i["client_summary"]["timing"]["derived_fps_from_mean_interval"] for i in items
            ),
            "frame_interval_p50_ms_mean": statistics.fmean(
                i["client_summary"]["timing"]["cpu_frame_interval_ms"]["p50"] for i in items
            ),
            "frame_interval_p95_ms_mean": statistics.fmean(
                i["client_summary"]["timing"]["cpu_frame_interval_ms"]["p95"] for i in items
            ),
            "frame_interval_mean_ms_mean": statistics.fmean(
                i["client_summary"]["timing"]["cpu_frame_interval_ms"]["mean"] for i in items
            ),
            "host_gpu_ms_mean": statistics.fmean(
                i["host_summary"]["metal_gpu_ms"]["mean"] for i in items
            ),
            "pacing_sleep_ms_mean": statistics.fmean(
                i["host_summary"]["pacing_sleep_ms"]["mean"] for i in items
            ),
            "render_paths_observed": sorted({k for i in items for k in i["host_summary"]["render_path_counts"].keys()}),
            "policy_qos_observed": sorted({q for i in items for q in i["host_summary"]["policy_qos_values"]}),
            "target_fps_caps_observed": items[0]["host_summary"]["target_fps_caps"],
        }

    manifest = {
        "schema_version": 1,
        "experiment": "metal_host_resource_policy_ab_and_fallback",
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": {
            "architecture": platform.machine(),
            "os_version": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, check=False).stdout.strip(),
            "os_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True, check=False).stdout.strip(),
        },
        "workload": {
            "frames": args.frames,
            "warmup": args.warmup,
            "width": args.width,
            "height": args.height,
            "commands": 16,
            "resource_bytes": 65536,
            "sender": "synthetic_client.py (loopback TCP)",
            "note": "Verifies real metal_host consumer pacing, QoS, MetalFX spatial gate, and fallback; not a D3D or guest test.",
        },
        "immutable_digests": {
            "metal_host_swift": source_sha or sha256_file(SCRIPT_DIR / "metal_host.swift"),
            "metal_host_binary": binary_sha,
            "synthetic_client_py": sha256_file(SCRIPT_DIR / "synthetic_client.py"),
            "restart_metal_host_sh": sha256_file(SCRIPT_DIR / "restart_metal_host.sh"),
            "run_metal_host_policy_ab_py": sha256_file(SCRIPT_DIR / "run_metal_host_policy_ab.py"),
        },
        "aggregate": aggregate,
        "runs": runs,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[metal-host-ab] completed {len(runs)} runs; manifest saved to {manifest_path.name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
