#!/usr/bin/env python3
"""Run paired Phase C3 Direct Present vs Offload TCP benchmarks inside a real Windows 11 ARM64 UTM Guest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import analyze

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent
DEFAULT_UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
DEFAULT_VM_ID = "B107A021-E60C-426B-BB62-626122CE44BE"
GUEST_SHARE_DIR = r"C:\whisky-guest-share"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(text: str) -> str:
    roots = [
        WORKSPACE_ROOT.resolve(),
        Path.home().resolve(),
        Path(tempfile.gettempdir()).resolve(),
    ]
    redacted = text
    for root in sorted(set(roots), key=lambda p: len(str(p)), reverse=True):
        label = "<workspace>" if root == WORKSPACE_ROOT.resolve() else "<home>" if root == Path.home().resolve() else "<tmp>"
        redacted = redacted.replace(str(root), label)
    username = os.environ.get("USER", "")
    if username:
        redacted = redacted.replace(f"/Users/{username}", "<home>")
    return redacted


def collect_guest_metadata(utmctl: Path, vm_id: str) -> dict[str, Any]:
    ps_script = (
        "$os = Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'; "
        "$gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1 Name,AdapterCompatibility,DriverVersion,VideoProcessor; "
        "@{ "
        "os_product = $os.ProductName; "
        "display_version = $os.DisplayVersion; "
        "build_lab_ex = $os.BuildLabEx; "
        "current_build = $os.CurrentBuildNumber; "
        "edition_id = $os.EditionID; "
        "architecture = $env:PROCESSOR_ARCHITECTURE; "
        "gpu_name = $gpu.Name; "
        "gpu_vendor = $gpu.AdapterCompatibility; "
        "gpu_driver_version = $gpu.DriverVersion; "
        "gpu_processor = $gpu.VideoProcessor "
        "} | ConvertTo-Json -Compress"
    )
    proc = subprocess.run(
        [str(utmctl), "exec", vm_id, "--cmd", "powershell.exe", "-NoProfile", "-Command", ps_script],
        capture_output=True, text=True, check=True,
    )
    return json.loads(proc.stdout.strip())


def stop_metal_host() -> None:
    pid_file = SCRIPT_DIR / "build/metal_host.pid"
    if pid_file.is_file():
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(pid, 15)
        except (ValueError, OSError):
            pass
        pid_file.unlink(missing_ok=True)
    subprocess.run(["pkill", "-f", str(SCRIPT_DIR / "build/metal_host")], capture_output=True, check=False)


def start_metal_host(bind_ip: str, port: int, jsonl_path: Path) -> tuple[str, str]:
    proc = subprocess.run(
        [
            str(SCRIPT_DIR / "restart_metal_host.sh"),
            "--bind", bind_ip,
            "--port", str(port),
            "--jsonl", str(jsonl_path),
            "--resource-policy", "off",
            "--metalfx", "off",
        ],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"restart_metal_host failed: {redact_text(proc.stderr)}")
    src_sha = ""
    bin_sha = ""
    for line in proc.stdout.splitlines():
        if line.startswith("source_sha256="):
            src_sha = line.partition("=")[2].strip()
        elif line.startswith("binary_sha256="):
            bin_sha = line.partition("=")[2].strip()
    return src_sha, bin_sha


def push_probe_to_guest(utmctl: Path, vm_id: str, local_probe: Path) -> None:
    guest_probe = f"{GUEST_SHARE_DIR}\\d3d11_probe.exe"
    with local_probe.open("rb") as stream:
        proc = subprocess.run(
            [str(utmctl), "file", "push", vm_id, guest_probe],
            stdin=stream, capture_output=True, check=False,
        )
    if proc.returncode != 0:
        raise RuntimeError(f"utmctl file push failed: {redact_text(proc.stderr.decode(errors='replace'))}")
    verify = subprocess.run(
        [
            str(utmctl), "exec", vm_id, "--cmd", "powershell.exe", "-NoProfile", "-Command",
            f"(Get-FileHash -Algorithm SHA256 '{guest_probe}').Hash.ToLower()",
        ],
        capture_output=True, text=True, check=True,
    )
    if verify.stdout.strip().lower() != sha256_file(local_probe):
        raise RuntimeError("Guest d3d11_probe.exe SHA-256 mismatch after push")


def pull_guest_file(utmctl: Path, vm_id: str, guest_path: str, local_path: Path) -> None:
    proc = subprocess.run(
        [str(utmctl), "file", "pull", vm_id, guest_path],
        capture_output=True, check=False,
    )
    if proc.returncode != 0 or not proc.stdout:
        raise RuntimeError(f"utmctl file pull failed for {guest_path}")
    local_path.write_bytes(proc.stdout)


def run_guest_direct_present(
    utmctl: Path,
    vm_id: str,
    stem: str,
    workload: dict[str, int],
    local_csv: Path,
) -> dict[str, Any]:
    guest_csv = f"{GUEST_SHARE_DIR}\\{stem}.csv"
    guest_err = f"{GUEST_SHARE_DIR}\\{stem}.err"
    guest_done = f"{GUEST_SHARE_DIR}\\{stem}.done"
    guest_bat = f"{GUEST_SHARE_DIR}\\run_{stem}.bat"
    probe_args = (
        f"--frames {workload['frames']} --warmup {workload['warmup']} "
        f"--width {workload['width']} --height {workload['height']} "
        f"--commands {workload['commands']} --resource-bytes {workload['resource_bytes']} "
        f"--csv {guest_csv}"
    )
    ps_cmd = (
        f"$bat = \"@echo off`r`n{GUEST_SHARE_DIR}\\d3d11_probe.exe {probe_args} 2>{guest_err}`r`n"
        f"echo %ERRORLEVEL% > {guest_done}`r`n\"; "
        f"Set-Content -Path '{guest_bat}' -Value $bat -Encoding ASCII; "
        f"Remove-Item '{guest_csv}','{guest_err}','{guest_done}' -ErrorAction SilentlyContinue; "
        f"$action = New-ScheduledTaskAction -Execute '{guest_bat}'; "
        "$principal = New-ScheduledTaskPrincipal -UserId 'whisky' -LogonType Interactive -RunLevel Limited; "
        f"Register-ScheduledTask -TaskName 'WhiskyC3Direct' -Action $action -Principal $principal -Force | Out-Null; "
        "Start-ScheduledTask -TaskName 'WhiskyC3Direct'; "
        "for ($i = 0; $i -lt 360; $i++) { "
        f"if (Test-Path '{guest_done}') {{ break }}; "
        "Start-Sleep -Milliseconds 500 "
        "}; "
        "Unregister-ScheduledTask -TaskName 'WhiskyC3Direct' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; "
        f"$code = (Get-Content '{guest_done}' -ErrorAction SilentlyContinue | Out-String).Trim(); "
        f"$err = (Get-Content '{guest_err}' -ErrorAction SilentlyContinue | Out-String).Trim(); "
        "@{ exit_code = $code; stderr = $err } | ConvertTo-Json -Compress"
    )
    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(utmctl), "exec", vm_id, "--cmd", "powershell.exe", "-NoProfile", "-Command", ps_cmd],
        capture_output=True, text=True, check=True,
    )
    wall_ms = (time.perf_counter() - t0) * 1000.0
    info = json.loads(proc.stdout.strip())
    if info.get("exit_code") != "0":
        raise RuntimeError(f"Guest direct_present failed: {info}")

    pull_guest_file(utmctl, vm_id, guest_csv, local_csv)
    return {"wall_ms": wall_ms, "stderr": info.get("stderr", "")}


def run_guest_offload_tcp(
    utmctl: Path,
    vm_id: str,
    stem: str,
    host_ip: str,
    port: int,
    workload: dict[str, int],
    local_csv: Path,
) -> dict[str, Any]:
    guest_csv = f"{GUEST_SHARE_DIR}\\{stem}.csv"
    t0 = time.perf_counter()
    proc = subprocess.run(
        [
            str(utmctl), "exec", vm_id, "--cmd", f"{GUEST_SHARE_DIR}\\d3d11_probe.exe",
            "--frames", str(workload["frames"]),
            "--warmup", str(workload["warmup"]),
            "--width", str(workload["width"]),
            "--height", str(workload["height"]),
            "--commands", str(workload["commands"]),
            "--command-every", str(workload["command_every"]),
            "--resource-bytes", str(workload["resource_bytes"]),
            "--resource-every", str(workload["resource_every"]),
            "--transport-host", host_ip,
            "--port", str(port),
            "--csv", guest_csv,
        ],
        capture_output=True, text=True, check=False,
    )
    wall_ms = (time.perf_counter() - t0) * 1000.0
    if proc.returncode != 0:
        raise RuntimeError(f"Guest offload_tcp failed (exit={proc.returncode}): {redact_text(proc.stderr)}")
    pull_guest_file(utmctl, vm_id, guest_csv, local_csv)
    return {"wall_ms": wall_ms, "stderr": proc.stderr.strip()}


def summarize_breakdown(runs: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        grouped.setdefault(run["mode"], []).append(run)

    def mean_of(values: list[float | None]) -> float | None:
        valid = [v for v in values if v is not None]
        return statistics.fmean(valid) if valid else None

    agg: dict[str, Any] = {}
    for mode, items in sorted(grouped.items()):
        cpu_submit_mean = mean_of([i["summary"]["timing"]["cpu_submit_ms"]["mean"] for i in items])
        gpu_mean = mean_of([i["summary"]["timing"]["gpu_ms"]["mean"] for i in items])
        host_gpu_mean = mean_of([i["summary"]["timing"]["host_gpu_ms"]["mean"] for i in items])
        agg[mode] = {
            "rounds": len(items),
            "initialization_ms_mean": mean_of([i["summary"]["run"]["initialization_ms"] for i in items]),
            "warmup_ms_mean": mean_of([i["summary"]["run"]["warmup_ms"] for i in items]),
            "derived_fps_mean": mean_of([i["summary"]["timing"]["derived_fps_from_mean_interval"] for i in items]),
            "frame_interval_mean_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["mean"] for i in items]),
            "frame_interval_p50_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["p50"] for i in items]),
            "frame_interval_p95_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["p95"] for i in items]),
            "frame_interval_p99_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["p99"] for i in items]),
            "cpu_submit_ms_mean": cpu_submit_mean,
            "guest_gpu_ms_mean": gpu_mean,
            "host_metal_gpu_ms_mean": host_gpu_mean,
            "process_cpu_ms_mean": mean_of([i["summary"]["timing"]["process_cpu_ms"]["mean"] for i in items]),
            "guest_resident_mib_mean": (
                mean_of([i["summary"]["memory"]["process_resident_bytes"]["mean"] for i in items]) or 0.0
            ) / (1024.0 * 1024.0),
            "network_bytes_per_frame_mean": mean_of([i["summary"]["transfer"]["network_bytes_total"]["per_frame_mean"] for i in items]),
        }

    direct = agg.get("direct_present")
    offload = agg.get("offload_tcp")
    if direct and offload and direct["guest_gpu_ms_mean"] is not None and offload["guest_gpu_ms_mean"] is not None:
        direct_gpu = direct["guest_gpu_ms_mean"]
        offload_gpu = offload["guest_gpu_ms_mean"]
        offload_submit = offload["cpu_submit_ms_mean"] or 0.0
        host_gpu = offload["host_metal_gpu_ms_mean"] or 0.0
        extra_copy_ms = max(0.0, offload_gpu - direct_gpu)
        map_tcp_and_present_ms = max(0.0, offload_submit - offload_gpu)
        agg["frame_time_breakdown_ms"] = {
            "guest_d3d11_render_ms": direct_gpu,
            "guest_copyresource_overhead_ms": extra_copy_ms,
            "guest_render_plus_copy_ms": offload_gpu,
            "map_read_plus_tcp_and_host_present_ms": map_tcp_and_present_ms,
            "host_metal_gpu_ms": host_gpu,
            "total_offload_submit_ms": offload_submit,
            "guest_render_plus_copy_share_pct": (offload_gpu / offload_submit * 100.0) if offload_submit > 0 else None,
        }
    return agg


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--utmctl", type=Path, default=DEFAULT_UTMCTL)
    parser.add_argument("--vm-id", default=DEFAULT_VM_ID)
    parser.add_argument("--probe", type=Path, default=SCRIPT_DIR / "build/d3d11_probe.exe")
    parser.add_argument("--host-ip", default="192.168.64.1")
    parser.add_argument("--port", type=int, default=39003)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=60)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    args = parser.parse_args(argv)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    workload = {
        "frames": args.frames,
        "warmup": args.warmup,
        "width": args.width,
        "height": args.height,
        "commands": 16,
        "command_every": 30,
        "resource_bytes": 65536,
        "resource_every": 30,
    }

    print("[guest-c3] pushing d3d11_probe.exe to Guest...", flush=True)
    push_probe_to_guest(args.utmctl, args.vm_id, args.probe)
    guest_meta = collect_guest_metadata(args.utmctl, args.vm_id)

    runs: list[dict[str, Any]] = []
    metal_src_sha = sha256_file(SCRIPT_DIR / "metal_host.swift")
    metal_bin_sha = ""

    try:
        for r in range(1, args.rounds + 1):
            order = ("direct_present", "offload_tcp") if r % 2 == 1 else ("offload_tcp", "direct_present")
            for mode in order:
                stem = f"guest-{mode}-r{r}"
                csv_path = args.output_dir / f"{stem}.csv"
                print(f"[guest-c3] round {r}/{args.rounds} mode={mode}...", flush=True)
                if mode == "direct_present":
                    exec_info = run_guest_direct_present(args.utmctl, args.vm_id, stem, workload, csv_path)
                    host_jsonl_name = None
                    host_jsonl_sha = None
                else:
                    jsonl_path = args.output_dir / f"{stem}-host.jsonl"
                    metal_src_sha, metal_bin_sha = start_metal_host(args.host_ip, args.port, jsonl_path)
                    exec_info = run_guest_offload_tcp(
                        args.utmctl, args.vm_id, stem, args.host_ip, args.port, workload, csv_path
                    )
                    stop_metal_host()
                    host_jsonl_name = jsonl_path.name
                    host_jsonl_sha = sha256_file(jsonl_path)

                with csv_path.open("r", encoding="utf-8-sig", newline="") as stream:
                    rows = analyze.load_rows(stream)
                summary = analyze.summarize(rows)
                runs.append({
                    "mode": mode,
                    "round": r,
                    "wall_ms": exec_info["wall_ms"],
                    "summary": summary,
                    "files": {
                        "csv": csv_path.name,
                        "csv_sha256": sha256_file(csv_path),
                        "host_jsonl": host_jsonl_name,
                        "host_jsonl_sha256": host_jsonl_sha,
                    },
                })
    finally:
        stop_metal_host()

    manifest = {
        "schema_version": 1,
        "experiment": "phase_c3_windows_guest_direct_vs_offload_tcp",
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": {
            "architecture": platform.machine(),
            "os_version": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, check=False).stdout.strip(),
            "os_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True, check=False).stdout.strip(),
        },
        "guest": guest_meta,
        "workload": workload,
        "rounds_per_mode": args.rounds,
        "immutable_digests": {
            "d3d11_probe_cpp": sha256_file(SCRIPT_DIR / "d3d11_probe.cpp"),
            "d3d11_probe_exe": sha256_file(args.probe),
            "metal_host_swift": metal_src_sha,
            "metal_host_binary": metal_bin_sha,
            "run_guest_c3_benchmark_py": sha256_file(SCRIPT_DIR / "run_guest_c3_benchmark.py"),
            "analyze_py": sha256_file(SCRIPT_DIR / "analyze.py"),
        },
        "aggregate": summarize_breakdown(runs),
        "runs": runs,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[guest-c3] completed {len(runs)} runs; manifest saved to {manifest_path.name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
