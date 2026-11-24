#!/usr/bin/env python3
"""Run paired Wine D3D11 benchmarks comparing DXVK and D3DMetal with immutable digests."""

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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import analyze


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENGINE_ROOT = Path.home() / "Library/Application Support/com.gamemac.www/wine-engine"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(text: str, extra_roots: list[Path] | None = None) -> str:
    roots = [
        SCRIPT_DIR.parent.resolve(),
        Path.home().resolve(),
        Path(tempfile.gettempdir()).resolve(),
    ]
    if extra_roots:
        roots.extend(r.resolve() for r in extra_roots)
    redacted = text
    for root in sorted(set(roots), key=lambda p: len(str(p)), reverse=True):
        label = "<workspace>" if root == SCRIPT_DIR.parent.resolve() else "<home>" if root == Path.home().resolve() else "<tmp>"
        redacted = redacted.replace(str(root), label)
    username = os.environ.get("USER", "")
    if username:
        redacted = redacted.replace(f"/Users/{username}", "<home>")
    return redacted


def collect_host_metadata() -> dict[str, Any]:
    def cmd_out(args: list[str]) -> str:
        proc = subprocess.run(args, capture_output=True, text=True, check=False)
        return proc.stdout.strip() if proc.returncode == 0 else "unknown"

    display_info = cmd_out(["system_profiler", "SPDisplaysDataType"])
    display_lines = [
        line.strip()
        for line in display_info.splitlines()
        if any(k in line for k in ("Chipset Model:", "Display Type:", "Resolution:", "UI Looks like:", "Refresh"))
    ]
    return {
        "os_product": cmd_out(["sw_vers", "-productName"]),
        "os_version": cmd_out(["sw_vers", "-productVersion"]),
        "os_build": cmd_out(["sw_vers", "-buildVersion"]),
        "sdk_version": cmd_out(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        "architecture": platform.machine(),
        "cpu_brand": cmd_out(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memory_bytes": int(cmd_out(["sysctl", "-n", "hw.memsize"]) or "0"),
        "display_summary": display_lines,
        "python_version": platform.python_version(),
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
    }


def resolve_wine_components(engine_root: Path) -> dict[str, Any]:
    wine_root = engine_root / "containers/wine_installations/10000073"
    dxvk_root = engine_root / "downloads/dxvk-1.10.3"
    mvk_root = engine_root / "downloads/MoltenVK-v1.2.1"
    gptk_root = engine_root / "downloads/gptk-4.0-1"
    dxmt_root = engine_root / "downloads/dxmt-v0.80"

    required = [
        wine_root / "bin/wine",
        wine_root / "bin/wineserver",
        dxvk_root / "wine/x86_64-windows/d3d11.dll",
        mvk_root / "external/libMoltenVK.dylib",
        gptk_root / "wine/x86_64-windows/d3d11.dll",
        gptk_root / "external/libd3dshared.dylib",
        dxmt_root / "wine/x86_64-windows/d3d11.dll",
        dxmt_root / "wine/x86_64-windows/dxgi.dll",
        dxmt_root / "wine/x86_64-unix/winemetal.so",
    ]
    missing = [str(p.name) for p in required if not p.exists()]
    if missing:
        raise FileNotFoundError(f"missing required Wine backend components: {', '.join(missing)}")

    wine_ver = subprocess.run(
        [str(wine_root / "bin/wine"), "--version"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    return {
        "wine_bin": wine_root / "bin/wine",
        "wineserver_bin": wine_root / "bin/wineserver",
        "wine_version": wine_ver,
        "dxvk_root": dxvk_root,
        "mvk_root": mvk_root,
        "gptk_root": gptk_root,
        "dxmt_root": dxmt_root,
        "digests": {
            "wine": sha256_file(wine_root / "bin/wine"),
            "dxvk_d3d11_dll": sha256_file(dxvk_root / "wine/x86_64-windows/d3d11.dll"),
            "moltenvk_dylib": sha256_file(mvk_root / "external/libMoltenVK.dylib"),
            "d3dmetal_d3d11_dll": sha256_file(gptk_root / "wine/x86_64-windows/d3d11.dll"),
            "d3dmetal_dxgi_dll": sha256_file(gptk_root / "wine/x86_64-windows/dxgi.dll"),
            "d3dmetal_libd3dshared_dylib": sha256_file(gptk_root / "external/libd3dshared.dylib"),
            "dxmt_d3d11_dll": sha256_file(dxmt_root / "wine/x86_64-windows/d3d11.dll"),
            "dxmt_dxgi_dll": sha256_file(dxmt_root / "wine/x86_64-windows/dxgi.dll"),
            "dxmt_winemetal_dll": sha256_file(dxmt_root / "wine/x86_64-windows/winemetal.dll"),
            "dxmt_winemetal_so": sha256_file(dxmt_root / "wine/x86_64-unix/winemetal.so"),
        },
        "versions": {
            "wine": wine_ver,
            "dxvk": "dxvk-1.10.3 (cxaddon-1.10.3-1-25-g737aacd)",
            "moltenvk": "MoltenVK-v1.2.1",
            "d3dmetal": "Apple GPTK 4.0-1",
            "dxmt": "dxmt-v0.80 (dxmt-wine-builtin-7641370)",
        },
    }


def _run_checked(cmd: list[str], env: dict[str, str], stderr_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, check=False)
    if stderr_path is not None:
        stderr_path.write_text(redact_text(proc.stderr), encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed (exit={proc.returncode}): {redact_text(proc.stderr[-1000:])}"
        )
    return proc


def _kill_wineserver(wineserver: Path, prefix: Path) -> None:
    env = os.environ.copy()
    env["WINEPREFIX"] = str(prefix)
    subprocess.run([str(wineserver), "-k"], env=env, capture_output=True, check=False)
    subprocess.run([str(wineserver), "-w"], env=env, capture_output=True, check=False)


def _prepare_prefix(components: dict[str, Any], backend: str, work_dir: Path) -> Path:
    prefix = work_dir / "prefix"
    env = os.environ.copy()
    env["WINEPREFIX"] = str(prefix)
    env["WINEDEBUG"] = "-all"
    env["XDG_CACHE_HOME"] = str(work_dir / "xdg_cache")
    (work_dir / "xdg_cache").mkdir(parents=True, exist_ok=True)

    subprocess.run(
        [str(components["wine_bin"]), "wineboot", "--init"],
        env=env, capture_output=True, check=False,
    )
    subprocess.run(
        [str(components["wineserver_bin"]), "-w"],
        env=env, capture_output=True, check=False,
    )
    sys32 = prefix / "drive_c/windows/system32"
    if not sys32.is_dir():
        raise RuntimeError("wineboot did not create system32 in disposable prefix")

    if backend == "dxvk":
        src_dir = components["dxvk_root"] / "wine/x86_64-windows"
    elif backend == "d3dmetal":
        src_dir = components["gptk_root"] / "wine/x86_64-windows"
    elif backend == "dxmt":
        src_dir = components["dxmt_root"] / "wine/x86_64-windows"
    else:
        raise ValueError(f"unsupported backend: {backend}")
    for dll in src_dir.glob("*.dll"):
        shutil.copy2(dll, sys32 / dll.name)

    _kill_wineserver(components["wineserver_bin"], prefix)
    return prefix


def _backend_env(components: dict[str, Any], backend: str, prefix: Path, work_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["WINEPREFIX"] = str(prefix)
    env["WINEDEBUG"] = "-all"
    env["XDG_CACHE_HOME"] = str(work_dir / "xdg_cache")
    (work_dir / "xdg_cache").mkdir(parents=True, exist_ok=True)
    if backend == "dxvk":
        cache_dir = work_dir / "dxvk_cache"
        log_dir = work_dir / "dxvk_logs"
        cache_dir.mkdir(parents=True, exist_ok=True)
        log_dir.mkdir(parents=True, exist_ok=True)
        env["WINEDLLPATH"] = str(components["dxvk_root"] / "wine")
        env["WINE_SONAME_LIBVULKAN"] = str(components["mvk_root"] / "external/libMoltenVK.dylib")
        env["DXVK_STATE_CACHE_PATH"] = str(cache_dir)
        env["DXVK_LOG_LEVEL"] = "info"
        env["DXVK_LOG_PATH"] = str(log_dir)
    elif backend == "d3dmetal":
        env["WINEDLLPATH"] = str(components["gptk_root"] / "wine")
        env["WINE_GPTK_LIBD3DSHARED_PATH"] = str(components["gptk_root"] / "external/libd3dshared.dylib")
        env["DYLD_FRAMEWORK_PATH"] = str(components["gptk_root"] / "external")
        env["D3DM_ENABLE_METALFX"] = "0"
    elif backend == "dxmt":
        cache_dir = work_dir / "dxmt_cache"
        log_dir = work_dir / "dxmt_logs"
        cache_dir.mkdir(parents=True, exist_ok=True)
        log_dir.mkdir(parents=True, exist_ok=True)
        env["WINEDLLPATH"] = str(components["dxmt_root"] / "wine")
        env["DXMT_SHADER_CACHE"] = "1"
        env["DXMT_SHADER_CACHE_PATH"] = str(cache_dir)
        env["DXMT_USE_DEFAULT_METAL_CACHE"] = "0"
        env["DXMT_LOG_LEVEL"] = "info"
        env["DXMT_LOG_PATH"] = str(log_dir)
    else:
        raise ValueError(f"unsupported backend: {backend}")
    return env


def _to_wine_z_path(path: Path) -> str:
    return "Z:" + str(path.resolve()).replace("/", "\\")


def run_single_pass(
    components: dict[str, Any],
    probe_exe: Path,
    backend: str,
    cache_state: str,
    round_index: int,
    prefix: Path,
    work_dir: Path,
    output_dir: Path,
    workload: dict[str, int],
) -> dict[str, Any]:
    stem = f"{backend}-r{round_index}-{cache_state}"
    tmp_csv = work_dir / f"{stem}.csv"
    startup_json = output_dir / f"{stem}-startup.json"
    final_csv = output_dir / f"{stem}.csv"
    summary_json = output_dir / f"{stem}-summary.json"
    stderr_log = work_dir / f"{stem}.stderr.log"

    env = _backend_env(components, backend, prefix, work_dir)
    if backend == "dxvk":
        cache_files_before = sorted((work_dir / "dxvk_cache").glob("*.dxvk-cache"))
    elif backend == "dxmt":
        cache_files_before = sorted((work_dir / "dxmt_cache").glob("shaders_*.db"))
    else:
        cache_files_before = []
    cache_bytes_before = sum(f.stat().st_size for f in cache_files_before)

    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "run_probe.py"),
        "--json",
        str(startup_json),
        "--",
        str(components["wine_bin"]),
        str(probe_exe),
        "--frames", str(workload["frames"]),
        "--warmup", str(workload["warmup"]),
        "--width", str(workload["width"]),
        "--height", str(workload["height"]),
        "--commands", str(workload["commands"]),
        "--resource-bytes", str(workload["resource_bytes"]),
        "--csv", _to_wine_z_path(tmp_csv),
    ]
    _run_checked(cmd, env=env, stderr_path=stderr_log)
    _kill_wineserver(components["wineserver_bin"], prefix)

    if not tmp_csv.is_file():
        raise RuntimeError(f"probe finished without producing CSV for {stem}")
    shutil.copy2(tmp_csv, final_csv)

    with final_csv.open("r", encoding="utf-8-sig", newline="") as stream:
        rows = analyze.load_rows(stream)
    summary = analyze.summarize(rows)
    startup = json.loads(startup_json.read_text(encoding="utf-8"))

    if backend == "dxvk":
        cache_files_after = sorted((work_dir / "dxvk_cache").glob("*.dxvk-cache"))
    elif backend == "dxmt":
        cache_files_after = sorted((work_dir / "dxmt_cache").glob("shaders_*.db"))
    else:
        cache_files_after = []
    cache_bytes_after = sum(f.stat().st_size for f in cache_files_after)

    backend_evidence: dict[str, Any] = {
        "backend": backend,
        "cache_state": cache_state,
        "round": round_index,
    }
    if backend == "dxvk":
        dxvk_log = work_dir / "dxvk_logs/d3d11_probe_d3d11.log"
        log_text = dxvk_log.read_text(encoding="utf-8", errors="replace") if dxvk_log.is_file() else ""
        backend_evidence.update({
            "dxvk_log_detected": "DXVK:" in log_text,
            "feature_level_line": next((ln.strip() for ln in log_text.splitlines() if "Using feature level" in ln), None),
            "dxvk_state_cache_bytes_before": cache_bytes_before,
            "dxvk_state_cache_bytes_after": cache_bytes_after,
            "cache_isolation": "isolated_dxvk_state_cache_and_disposable_prefix",
        })
    elif backend == "dxmt":
        dxmt_log = work_dir / "dxmt_logs/d3d11_probe_d3d11.log"
        log_text = dxmt_log.read_text(encoding="utf-8", errors="replace") if dxmt_log.is_file() else ""
        backend_evidence.update({
            "dxmt_log_detected": "DXMT:" in log_text,
            "feature_level_line": next((ln.strip() for ln in log_text.splitlines() if "Using feature level" in ln), None),
            "dxmt_shader_cache_bytes_before": cache_bytes_before,
            "dxmt_shader_cache_bytes_after": cache_bytes_after,
            "cache_isolation": "isolated_dxmt_shader_cache_non_default_metal_cache_and_disposable_prefix",
        })
    else:
        stderr_text = stderr_log.read_text(encoding="utf-8", errors="replace")
        backend_evidence.update({
            "d3dmetal_timestamp_unsupported_logged": "Unsupported: D3D11 timestamp query" in stderr_text,
            "cache_isolation": "disposable_prefix_and_isolated_xdg_cache_only_macos_system_metal_cache_not_cleared",
        })

    combined = {
        "schema_version": 1,
        "pass": stem,
        "startup": startup,
        "summary": summary,
        "backend_evidence": backend_evidence,
        "files": {
            "csv": final_csv.name,
            "csv_sha256": sha256_file(final_csv),
            "startup_json": startup_json.name,
            "startup_json_sha256": sha256_file(startup_json),
        },
    }
    summary_json.write_text(json.dumps(combined, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return combined


def aggregate_runs(runs: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for run in runs:
        backend = run["backend_evidence"]["backend"]
        cache_state = run["backend_evidence"]["cache_state"]
        grouped.setdefault(backend, {}).setdefault(cache_state, []).append(run)

    def mean_of(values: list[float | None]) -> float | None:
        valid = [v for v in values if v is not None]
        return statistics.fmean(valid) if valid else None

    result: dict[str, Any] = {}
    for backend, states in sorted(grouped.items()):
        result[backend] = {}
        for state, items in sorted(states.items()):
            result[backend][state] = {
                "rounds": len(items),
                "process_start_to_d3d_ready_ms_mean": mean_of([i["startup"]["process_start_to_d3d_ready_ms"] for i in items]),
                "probe_internal_init_ms_mean": mean_of([i["startup"]["probe_internal_initialization_ms"] for i in items]),
                "warmup_ms_mean": mean_of([i["summary"]["run"]["warmup_ms"] for i in items]),
                "derived_fps_mean": mean_of([i["summary"]["timing"]["derived_fps_from_mean_interval"] for i in items]),
                "frame_interval_p50_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["p50"] for i in items]),
                "frame_interval_p95_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["p95"] for i in items]),
                "frame_interval_p99_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["p99"] for i in items]),
                "frame_interval_mean_ms_mean": mean_of([i["summary"]["timing"]["cpu_frame_interval_ms"]["mean"] for i in items]),
                "gpu_ms_mean": mean_of([i["summary"]["timing"]["gpu_ms"]["mean"] for i in items]),
                "gpu_ms_coverage_mean": mean_of([i["summary"]["timing"]["gpu_ms"]["coverage"] for i in items]),
                "process_resident_mib_mean": (
                    mean_of([i["summary"]["memory"]["process_resident_bytes"]["mean"] for i in items]) or 0.0
                ) / (1024.0 * 1024.0),
                "device_memory_mib_mean": (
                    (mean_of([i["summary"]["memory"]["device_memory_bytes"]["mean"] for i in items]) or 0.0) / (1024.0 * 1024.0)
                    if any(i["summary"]["memory"]["device_memory_bytes"]["sample_count"] > 0 for i in items)
                    else None
                ),
            }
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, default=SCRIPT_DIR / "build/d3d11_probe.exe")
    parser.add_argument("--engine-root", type=Path, default=DEFAULT_ENGINE_ROOT)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--backends",
        default="dxvk,d3dmetal,dxmt",
        help="comma-separated subset of backends to run: dxvk,d3dmetal,dxmt",
    )
    parser.add_argument(
        "--merge-baseline",
        type=Path,
        default=None,
        help="optional existing manifest.json whose runs/digests are merged for unified three-engine comparison",
    )
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--frames", type=int, default=900)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--commands", type=int, default=16)
    parser.add_argument("--resource-bytes", type=int, default=65536)
    args = parser.parse_args(argv)

    if not args.probe.is_file():
        parser.error(f"probe executable not found: {args.probe}")
    selected_backends = [b.strip().lower() for b in args.backends.split(",") if b.strip()]
    valid_backends = {"dxvk", "d3dmetal", "dxmt"}
    if not selected_backends or any(b not in valid_backends for b in selected_backends):
        parser.error("--backends must be a comma-separated list from: dxvk,d3dmetal,dxmt")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    components = resolve_wine_components(args.engine_root)
    workload = {
        "frames": args.frames,
        "warmup": args.warmup,
        "width": args.width,
        "height": args.height,
        "commands": args.commands,
        "resource_bytes": args.resource_bytes,
    }
    runs: list[dict[str, Any]] = []

    for r in range(1, args.rounds + 1):
        shift = (r - 1) % len(selected_backends)
        order = selected_backends[shift:] + selected_backends[:shift]
        for backend in order:
            print(f"[wine-bench] round {r}/{args.rounds} backend={backend} preparing disposable prefix...", flush=True)
            with tempfile.TemporaryDirectory(prefix=f"graphics-lab-{backend}-r{r}-") as tmp_name:
                work_dir = Path(tmp_name)
                prefix = _prepare_prefix(components, backend, work_dir)
                for cache_state in ("cold", "hot"):
                    print(f"[wine-bench] round {r}/{args.rounds} backend={backend} state={cache_state}...", flush=True)
                    result = run_single_pass(
                        components=components,
                        probe_exe=args.probe,
                        backend=backend,
                        cache_state=cache_state,
                        round_index=r,
                        prefix=prefix,
                        work_dir=work_dir,
                        output_dir=args.output_dir,
                        workload=workload,
                    )
                    runs.append(result)

    merged_runs = list(runs)
    baseline_reference: dict[str, Any] | None = None
    if args.merge_baseline is not None:
        baseline = json.loads(args.merge_baseline.read_text(encoding="utf-8"))
        if baseline.get("workload") != workload:
            raise RuntimeError("baseline manifest workload does not match current run parameters")
        current_probe_sha = sha256_file(args.probe)
        if baseline.get("immutable_digests", {}).get("d3d11_probe_exe") != current_probe_sha:
            raise RuntimeError("baseline manifest d3d11_probe_exe SHA-256 differs from current probe")
        baseline_runs = [
            item for item in baseline.get("runs", [])
            if item.get("backend_evidence", {}).get("backend") not in set(selected_backends)
        ]
        merged_runs = baseline_runs + runs
        baseline_reference = {
            "baseline_manifest_relpath": str(args.merge_baseline.name),
            "baseline_manifest_sha256": sha256_file(args.merge_baseline),
            "baseline_recorded_at_utc": baseline.get("host", {}).get("recorded_at_utc"),
            "merged_baseline_run_count": len(baseline_runs),
        }

    manifest = {
        "schema_version": 1,
        "experiment": "wine_three_engine_dxmt_vs_d3dmetal_vs_dxvk" if args.merge_baseline else "wine_dxvk_vs_d3dmetal_d3d11_probe",
        "host": collect_host_metadata(),
        "workload": workload,
        "backends_executed_in_this_run": selected_backends,
        "rounds_per_condition": args.rounds,
        "baseline_reference": baseline_reference,
        "immutable_digests": {
            "d3d11_probe_cpp": sha256_file(SCRIPT_DIR / "d3d11_probe.cpp"),
            "d3d11_probe_exe": sha256_file(args.probe),
            "run_probe_py": sha256_file(SCRIPT_DIR / "run_probe.py"),
            "analyze_py": sha256_file(SCRIPT_DIR / "analyze.py"),
            "run_wine_benchmark_py": sha256_file(SCRIPT_DIR / "run_wine_benchmark.py"),
            **components["digests"],
        },
        "runtime_versions": components["versions"],
        "cache_isolation_notes": {
            "dxvk": "Disposable WINEPREFIX + empty DXVK_STATE_CACHE_PATH and XDG_CACHE_HOME per round; hot pass reuses populated cache with fresh process.",
            "dxmt": "Disposable WINEPREFIX + DXMT_SHADER_CACHE=1 + empty DXMT_SHADER_CACHE_PATH + DXMT_USE_DEFAULT_METAL_CACHE=0 + isolated XDG_CACHE_HOME per round.",
            "d3dmetal": "Disposable WINEPREFIX + isolated XDG_CACHE_HOME per round; macOS system Metal pipeline cache is not cleared (shared user cache untouched).",
        },
        "aggregate": aggregate_runs(merged_runs),
        "runs": runs,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[wine-bench] completed {len(runs)} new runs (total aggregated={len(merged_runs)}); manifest saved to {manifest_path.name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
