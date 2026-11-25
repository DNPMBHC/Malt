#!/usr/bin/env python3
"""Run four-way Wine D3D11 benchmarks (DXMT / D3DMetal / DXVK+KosmicKrisp / DXVK+MoltenVK)
and optional DXMT MetalFX Spatial preset sweeps with immutable SHA-256 bindings."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
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
REPO_ROOT = SCRIPT_DIR.parent.resolve()
DEFAULT_ENGINE_ROOT = Path.home() / "Library/Application Support/com.gamemac.www/wine-engine"
DEFAULT_KOSMICKRISP_DIR = DEFAULT_ENGINE_ROOT / "downloads/kosmickrisp-mesa-bb986060e0"
DEFAULT_OFFICIAL_SDK_ROOT = Path.home() / "VulkanSDK/1.4.363.1/macOS"
DEFAULT_PATCH_PATH = REPO_ROOT / "handoff/phase-4/evidence/p4-a/kosmickrisp-fillmode-eval.patch"

FOUR_WAY_BACKENDS = ("dxmt", "d3dmetal", "dxvk_kosmickrisp", "dxvk_moltenvk")
ROUND_ROTATIONS = (
    ("dxmt", "d3dmetal", "dxvk_kosmickrisp", "dxvk_moltenvk"),
    ("dxvk_kosmickrisp", "dxvk_moltenvk", "d3dmetal", "dxmt"),
    ("d3dmetal", "dxvk_kosmickrisp", "dxmt", "dxvk_moltenvk"),
)
METALFX_PRESET_FACTORS: dict[str, str | None] = {
    "off": None,
    "ultra_quality": "1.3",
    "quality": "1.5",
    "balanced": "1.7",
    "performance": "2.0",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(text: str, extra_roots: list[Path] | None = None) -> str:
    roots = [
        REPO_ROOT,
        Path.home().resolve(),
        Path(tempfile.gettempdir()).resolve(),
    ]
    if extra_roots:
        roots.extend(r.resolve() for r in extra_roots)
    redacted = text
    for root in sorted(set(roots), key=lambda p: len(str(p)), reverse=True):
        if root == REPO_ROOT:
            label = "<workspace>"
        elif root == Path.home().resolve():
            label = "<home>"
        else:
            label = "<tmp>"
        redacted = redacted.replace(str(root), label)
    redacted = re.sub(r"/Users/[^/\s\"']+", "<home>", redacted)
    redacted = re.sub(r"/Volumes/[^/\s\"']+", "<EXTERNAL_VOLUME>", redacted)
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


def resolve_four_way_components(
    engine_root: Path,
    kosmickrisp_root: Path = DEFAULT_KOSMICKRISP_DIR,
    official_sdk_root: Path = DEFAULT_OFFICIAL_SDK_ROOT,
) -> dict[str, Any]:
    wine_root = engine_root / "containers/wine_installations/10000073"
    dxvk_root = engine_root / "downloads/dxvk-1.10.3"
    mvk_root = engine_root / "downloads/MoltenVK-v1.2.1"
    gptk_root = engine_root / "downloads/gptk-4.0-1"
    dxmt_root = engine_root / "downloads/dxmt-v0.80"

    kk_dylib = kosmickrisp_root / "lib/libvulkan_kosmickrisp.dylib"
    kk_loader = kosmickrisp_root / "lib/libvulkan.1.dylib"
    kk_icd_json = kosmickrisp_root / "icd.d/kosmickrisp_icd.json"
    official_kk_arm64 = official_sdk_root / "lib/libvulkan_kosmickrisp.dylib"

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
        kk_dylib,
        kk_loader,
        kk_icd_json,
    ]
    missing = [str(p.name) for p in required if not p.exists()]
    if missing:
        raise FileNotFoundError(f"missing required four-way Wine components: {', '.join(missing)}")

    wine_ver = subprocess.run(
        [str(wine_root / "bin/wine"), "--version"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    digests: dict[str, str] = {
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
        "vulkan_loader_dylib": sha256_file(kk_loader),
        "kosmickrisp_x86_64_dylib": sha256_file(kk_dylib),
        "kosmickrisp_icd_json": sha256_file(kk_icd_json),
    }
    if official_kk_arm64.is_file():
        digests["official_sdk_kosmickrisp_arm64_dylib"] = sha256_file(official_kk_arm64)
    if DEFAULT_PATCH_PATH.is_file():
        digests["kosmickrisp_fillmode_eval_patch_source"] = sha256_file(DEFAULT_PATCH_PATH)

    return {
        "wine_bin": wine_root / "bin/wine",
        "wineserver_bin": wine_root / "bin/wineserver",
        "dxvk_root": dxvk_root,
        "mvk_root": mvk_root,
        "gptk_root": gptk_root,
        "dxmt_root": dxmt_root,
        "kosmickrisp_root": kosmickrisp_root,
        "kk_dylib": kk_dylib,
        "kk_loader": kk_loader,
        "kk_icd_json": kk_icd_json,
        "digests": digests,
        "versions": {
            "wine": wine_ver,
            "dxvk": "dxvk-1.10.3 (cxaddon-1.10.3-1-25-g737aacd)",
            "moltenvk": "MoltenVK-v1.2.1 (x86_64)",
            "d3dmetal": "Apple GPTK 4.0-1",
            "dxmt": "dxmt-v0.80 (dxmt-wine-builtin-7641370)",
            "vulkan_loader": "LunarG Vulkan SDK 1.4.363.1 (universal x86_64+arm64)",
            "kosmickrisp_x86_64": (
                "Mesa 27.0.0-devel (upstream git-bb986060e0, x86_64 cross-compile + "
                "archived fillModeNonSolid(solid/lines) eval patch; Vulkan 1.4.368, CTS 1.4.6.2)"
            ),
            "official_sdk_kosmickrisp_arm64": (
                "LunarG Vulkan SDK 1.4.363.1 (git-269a955c89, arm64-only, geometryShader=false)"
            ),
        },
    }


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

    if backend in ("dxvk_moltenvk", "dxvk_kosmickrisp"):
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


def build_backend_env(
    components: dict[str, Any],
    backend: str,
    prefix: Path,
    work_dir: Path,
    metalfx_preset: str = "off",
) -> dict[str, str]:
    env = os.environ.copy()
    for stale in (
        "VK_DRIVER_FILES", "VK_ICD_FILENAMES", "WINE_SONAME_LIBVULKAN",
        "DXMT_METALFX_SPATIAL_SWAPCHAIN", "DXMT_CONFIG",
        "D3DM_ENABLE_METALFX", "DXVK_STATE_CACHE_PATH",
    ):
        env.pop(stale, None)

    env["WINEPREFIX"] = str(prefix)
    env["WINEDEBUG"] = "-all"
    env["XDG_CACHE_HOME"] = str(work_dir / "xdg_cache")
    (work_dir / "xdg_cache").mkdir(parents=True, exist_ok=True)

    if backend in ("dxvk_moltenvk", "dxvk_kosmickrisp"):
        cache_dir = work_dir / "dxvk_cache"
        log_dir = work_dir / "dxvk_logs"
        cache_dir.mkdir(parents=True, exist_ok=True)
        log_dir.mkdir(parents=True, exist_ok=True)
        env["WINEDLLPATH"] = str(components["dxvk_root"] / "wine")
        env["DXVK_STATE_CACHE_PATH"] = str(cache_dir)
        env["DXVK_LOG_LEVEL"] = "info"
        env["DXVK_LOG_PATH"] = str(log_dir)
        if backend == "dxvk_moltenvk":
            env["WINE_SONAME_LIBVULKAN"] = str(components["mvk_root"] / "external/libMoltenVK.dylib")
        else:
            env["WINE_SONAME_LIBVULKAN"] = str(components["kk_loader"])
            env["VK_DRIVER_FILES"] = str(components["kk_icd_json"])
            env["VK_ICD_FILENAMES"] = str(components["kk_icd_json"])
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
        if metalfx_preset not in METALFX_PRESET_FACTORS:
            raise ValueError(f"unsupported MetalFX preset: {metalfx_preset}")
        factor = METALFX_PRESET_FACTORS[metalfx_preset]
        if factor is None:
            env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "0"
        else:
            env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            env["DXMT_CONFIG"] = f"d3d11.metalSpatialUpscaleFactor={factor}"
    else:
        raise ValueError(f"unsupported backend: {backend}")
    return env


def _to_wine_z_path(path: Path) -> str:
    return "Z:" + str(path.resolve()).replace("/", "\\")


def _extract_dxvk_log_facts(log_text: str) -> dict[str, Any]:
    def first_line(needle: str) -> str | None:
        return next((ln.strip() for ln in log_text.splitlines() if needle in ln), None)

    return {
        "dxvk_log_detected": "DXVK:" in log_text,
        "feature_level_line": first_line("Using feature level"),
        "device_name_line": first_line("Device name:"),
        "driver_version_line": first_line("Driver version"),
        "robust_buffer_access2_line": first_line("robustBufferAccess2"),
        "geometry_shader_line": first_line("geometryShader"),
    }


def run_single_pass(
    components: dict[str, Any],
    probe_exe: Path,
    backend: str,
    arm_label: str,
    cache_state: str,
    round_index: int,
    prefix: Path,
    work_dir: Path,
    output_dir: Path,
    workload: dict[str, int],
    metalfx_preset: str = "off",
) -> dict[str, Any]:
    stem = f"{arm_label}-r{round_index}-{cache_state}"
    tmp_csv = work_dir / f"{stem}.csv"
    startup_json = output_dir / f"{stem}-startup.json"
    final_csv = output_dir / f"{stem}.csv"
    summary_json = output_dir / f"{stem}-summary.json"
    stderr_log = work_dir / f"{stem}.stderr.log"

    env = build_backend_env(components, backend, prefix, work_dir, metalfx_preset=metalfx_preset)
    if backend in ("dxvk_moltenvk", "dxvk_kosmickrisp"):
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
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, check=False)
    stderr_log.write_text(redact_text(proc.stderr), encoding="utf-8")
    _kill_wineserver(components["wineserver_bin"], prefix)
    if proc.returncode != 0:
        raise RuntimeError(
            f"{stem} failed (exit={proc.returncode}): {redact_text(proc.stderr[-1200:])}"
        )

    if not tmp_csv.is_file():
        raise RuntimeError(f"probe finished without producing CSV for {stem}")
    shutil.copy2(tmp_csv, final_csv)

    with final_csv.open("r", encoding="utf-8-sig", newline="") as stream:
        rows = analyze.load_rows(stream)
    summary = analyze.summarize(rows)
    startup = json.loads(startup_json.read_text(encoding="utf-8"))

    if backend in ("dxvk_moltenvk", "dxvk_kosmickrisp"):
        cache_files_after = sorted((work_dir / "dxvk_cache").glob("*.dxvk-cache"))
    elif backend == "dxmt":
        cache_files_after = sorted((work_dir / "dxmt_cache").glob("shaders_*.db"))
    else:
        cache_files_after = []
    cache_bytes_after = sum(f.stat().st_size for f in cache_files_after)

    backend_evidence: dict[str, Any] = {
        "arm": arm_label,
        "backend": backend,
        "cache_state": cache_state,
        "round": round_index,
        "metalfx_preset": metalfx_preset,
    }
    if backend in ("dxvk_moltenvk", "dxvk_kosmickrisp"):
        dxvk_log = work_dir / "dxvk_logs/d3d11_probe_d3d11.log"
        log_text = dxvk_log.read_text(encoding="utf-8", errors="replace") if dxvk_log.is_file() else ""
        backend_evidence.update(_extract_dxvk_log_facts(log_text))
        backend_evidence.update({
            "vulkan_icd": "kosmickrisp" if backend == "dxvk_kosmickrisp" else "moltenvk",
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
            "metalfx_config_line": next(
                (ln.strip() for ln in log_text.splitlines() if "metalSpatialUpscaleFactor" in ln), None
            ),
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
    combined["files"]["summary_json"] = summary_json.name
    combined["files"]["summary_json_sha256"] = sha256_file(summary_json)
    return combined


def aggregate_runs(runs: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for run in runs:
        arm = run["backend_evidence"].get("arm") or run["backend_evidence"]["backend"]
        cache_state = run["backend_evidence"]["cache_state"]
        grouped.setdefault(arm, {}).setdefault(cache_state, []).append(run)

    def mean_of(values: list[float | None]) -> float | None:
        valid = [v for v in values if v is not None]
        return statistics.fmean(valid) if valid else None

    result: dict[str, Any] = {}
    for arm, states in sorted(grouped.items()):
        result[arm] = {}
        for state, items in sorted(states.items()):
            result[arm][state] = {
                "rounds": len(items),
                "process_start_to_d3d_ready_ms_mean": mean_of(
                    [r["startup"].get("process_start_to_d3d_ready_ms") for r in items]
                ),
                "probe_internal_init_ms_mean": mean_of(
                    [r["startup"].get("probe_internal_initialization_ms") for r in items]
                ),
                "warmup_ms_mean": mean_of([r["summary"]["run"].get("warmup_ms") for r in items]),
                "derived_fps_mean": mean_of(
                    [r["summary"]["timing"].get("derived_fps_from_mean_interval") for r in items]
                ),
                "frame_interval_mean_ms_mean": mean_of(
                    [r["summary"]["timing"]["cpu_frame_interval_ms"].get("mean") for r in items]
                ),
                "frame_interval_p50_ms_mean": mean_of(
                    [r["summary"]["timing"]["cpu_frame_interval_ms"].get("p50") for r in items]
                ),
                "frame_interval_p95_ms_mean": mean_of(
                    [r["summary"]["timing"]["cpu_frame_interval_ms"].get("p95") for r in items]
                ),
                "frame_interval_p99_ms_mean": mean_of(
                    [r["summary"]["timing"]["cpu_frame_interval_ms"].get("p99") for r in items]
                ),
                "gpu_ms_mean": mean_of([r["summary"]["timing"]["gpu_ms"].get("mean") for r in items]),
                "gpu_ms_coverage_mean": mean_of(
                    [r["summary"]["timing"]["gpu_ms"].get("coverage") for r in items]
                ),
                "process_resident_mib_mean": mean_of(
                    [
                        (r["summary"]["memory"]["process_resident_bytes"]["mean"] / (1024 * 1024))
                        if r["summary"]["memory"]["process_resident_bytes"]["mean"] is not None
                        else None
                        for r in items
                    ]
                ),
                "device_memory_mib_mean": mean_of(
                    [
                        (r["summary"]["memory"]["device_memory_bytes"]["mean"] / (1024 * 1024))
                        if r["summary"]["memory"]["device_memory_bytes"]["mean"] is not None
                        else None
                        for r in items
                    ]
                ),
            }
    return result


def build_four_way_manifest(
    components: dict[str, Any],
    probe_exe: Path,
    workload: dict[str, int],
    rounds: int,
    runs: list[dict[str, Any]],
    experiment_name: str,
) -> dict[str, Any]:
    immutable_digests = {
        "wine_kosmickrisp_benchmark_py": sha256_file(Path(__file__).resolve()),
        "analyze_py": sha256_file(SCRIPT_DIR / "analyze.py"),
        "run_probe_py": sha256_file(SCRIPT_DIR / "run_probe.py"),
        "d3d11_probe_cpp": sha256_file(SCRIPT_DIR / "d3d11_probe.cpp"),
        "d3d11_probe_exe": sha256_file(probe_exe),
        **components["digests"],
    }
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "experiment": experiment_name,
        "realWineExecuted": True,
        "realBenchmarkExecuted": True,
        "status_separation": {
            "code_implementation": "verified",
            "local_synthetic_verification": "verified",
            "real_wine_verification": "verified_self_owned_d3d11_probe_1280x720",
            "windows_guest_verification": "not_in_scope_for_window_4a",
            "vendor_and_commercial_game_validation": "not_tested_no_extrapolation",
        },
        "host": collect_host_metadata(),
        "workload": workload,
        "rounds_per_condition": rounds,
        "versions": components["versions"],
        "immutable_digests": immutable_digests,
        "cache_isolation_notes": {
            "dxmt": (
                "Disposable WINEPREFIX + DXMT_SHADER_CACHE=1 + empty DXMT_SHADER_CACHE_PATH + "
                "DXMT_USE_DEFAULT_METAL_CACHE=0 + isolated XDG_CACHE_HOME per round."
            ),
            "d3dmetal": (
                "Disposable WINEPREFIX + isolated XDG_CACHE_HOME per round; "
                "macOS system Metal pipeline cache is left untouched."
            ),
            "dxvk_kosmickrisp": (
                "Disposable WINEPREFIX + empty DXVK_STATE_CACHE_PATH + isolated XDG_CACHE_HOME per round; "
                "WINE_SONAME_LIBVULKAN points to LunarG Vulkan Loader 1.4.363.1 and VK_DRIVER_FILES locks KosmicKrisp ICD."
            ),
            "dxvk_moltenvk": (
                "Disposable WINEPREFIX + empty DXVK_STATE_CACHE_PATH + isolated XDG_CACHE_HOME per round; "
                "WINE_SONAME_LIBVULKAN points directly to MoltenVK v1.2.1."
            ),
        },
        "runs": runs,
        "aggregate": aggregate_runs(runs),
    }
    return manifest


def run_four_way_suite(
    components: dict[str, Any],
    probe_exe: Path,
    output_dir: Path,
    workload: dict[str, int],
    rounds: int,
) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    runs: list[dict[str, Any]] = []
    for round_index in range(1, rounds + 1):
        order = ROUND_ROTATIONS[(round_index - 1) % len(ROUND_ROTATIONS)]
        for backend in order:
            with tempfile.TemporaryDirectory(prefix=f"p4a-{backend}-r{round_index}-") as tmp_name:
                work_dir = Path(tmp_name)
                prefix = _prepare_prefix(components, backend, work_dir)
                for cache_state in ("cold", "hot"):
                    print(
                        f"[4-way] round={round_index}/{rounds} backend={backend} cache={cache_state}",
                        flush=True,
                    )
                    runs.append(
                        run_single_pass(
                            components=components,
                            probe_exe=probe_exe,
                            backend=backend,
                            arm_label=backend,
                            cache_state=cache_state,
                            round_index=round_index,
                            prefix=prefix,
                            work_dir=work_dir,
                            output_dir=output_dir,
                            workload=workload,
                            metalfx_preset="off",
                        )
                    )
    manifest = build_four_way_manifest(
        components=components,
        probe_exe=probe_exe,
        workload=workload,
        rounds=rounds,
        runs=runs,
        experiment_name="wine_four_way_dxmt_d3dmetal_dxvk_kosmickrisp_moltenvk",
    )
    manifest_text = redact_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (output_dir / "manifest.json").write_text(manifest_text, encoding="utf-8")
    return json.loads(manifest_text)


def run_dxmt_metalfx_sweep(
    components: dict[str, Any],
    probe_exe: Path,
    output_dir: Path,
    workload: dict[str, int],
    rounds: int,
    presets: tuple[str, ...] = ("off", "quality", "performance"),
) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    runs: list[dict[str, Any]] = []
    for round_index in range(1, rounds + 1):
        order = presets if round_index % 2 == 1 else tuple(reversed(presets))
        for preset in order:
            arm_label = f"dxmt_metalfx_{preset}"
            with tempfile.TemporaryDirectory(prefix=f"p4a-{arm_label}-r{round_index}-") as tmp_name:
                work_dir = Path(tmp_name)
                prefix = _prepare_prefix(components, "dxmt", work_dir)
                for cache_state in ("cold", "hot"):
                    print(
                        f"[dxmt-metalfx] round={round_index}/{rounds} preset={preset} cache={cache_state}",
                        flush=True,
                    )
                    runs.append(
                        run_single_pass(
                            components=components,
                            probe_exe=probe_exe,
                            backend="dxmt",
                            arm_label=arm_label,
                            cache_state=cache_state,
                            round_index=round_index,
                            prefix=prefix,
                            work_dir=work_dir,
                            output_dir=output_dir,
                            workload=workload,
                            metalfx_preset=preset,
                        )
                    )
    manifest = build_four_way_manifest(
        components=components,
        probe_exe=probe_exe,
        workload=workload,
        rounds=rounds,
        runs=runs,
        experiment_name="dxmt_metalfx_spatial_preset_comparison",
    )
    manifest_text = redact_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (output_dir / "manifest.json").write_text(manifest_text, encoding="utf-8")
    return json.loads(manifest_text)


def main() -> int:
    parser = argparse.ArgumentParser(description="Window 4A four-way Wine + KosmicKrisp benchmark runner")
    parser.add_argument("--probe", type=Path, default=SCRIPT_DIR / "build/d3d11_probe.exe")
    parser.add_argument("--engine-root", type=Path, default=DEFAULT_ENGINE_ROOT)
    parser.add_argument("--kosmickrisp-root", type=Path, default=DEFAULT_KOSMICKRISP_DIR)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "handoff/phase-4/evidence/p4-a/wine-four-way-benchmark",
    )
    parser.add_argument("--metalfx-output-dir", type=Path, default=None)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--frames", type=int, default=900)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--commands", type=int, default=16)
    parser.add_argument("--resource-bytes", type=int, default=65536)
    args = parser.parse_args()

    components = resolve_four_way_components(
        engine_root=args.engine_root,
        kosmickrisp_root=args.kosmickrisp_root,
    )
    workload = {
        "width": args.width,
        "height": args.height,
        "warmup": args.warmup,
        "frames": args.frames,
        "commands": args.commands,
        "resource_bytes": args.resource_bytes,
    }
    four_way = run_four_way_suite(
        components=components,
        probe_exe=args.probe,
        output_dir=args.output_dir,
        workload=workload,
        rounds=args.rounds,
    )
    print(json.dumps({"four_way_aggregate": four_way["aggregate"]}, indent=2))

    if args.metalfx_output_dir is not None:
        metalfx = run_dxmt_metalfx_sweep(
            components=components,
            probe_exe=args.probe,
            output_dir=args.metalfx_output_dir,
            workload=workload,
            rounds=args.rounds,
        )
        print(json.dumps({"dxmt_metalfx_aggregate": metalfx["aggregate"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
