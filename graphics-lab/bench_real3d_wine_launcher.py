#!/usr/bin/env python3
"""Supervised official target-cn runs in an owned external Wine Bottle. @DNPMBHC.

Launches official, unmodified binaries and records lifecycle facts: natural exit
codes, host window inventory and coarse luminance statistics. It never clicks,
types or reads agreement, account, identity or CAPTCHA interfaces; the user does
those in the visible window. No anti-cheat file is patched, hooked or replaced.
Chromium switches used here are documented diagnostics recorded per run.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

import bench_real3d_support as support
import bench_real3d_wine_diagnostics as diagnostics
import wine_kosmickrisp_benchmark as wine

INSTALLER_SHA256 = "686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e"
LAUNCHER_SHA256 = {
    "bootstrap": "b2b65ed5ee470a8c9a6a3ef96ed9f6def220226472dee58fb50d445805860538",
    "launcher": "250f619fd0f004d6cdb606dda3dede142d13da4730da8c9cf78a9df9d415233a",
}
LAUNCHER_SIZE = {"bootstrap": 7370008, "launcher": 139611928}
VARIANTS = {
    "baseline": [],
    "in-process-gpu": ["--in-process-gpu"],
    "gpu-sandbox-off": ["--disable-gpu-sandbox"],
    "swiftshader": ["--use-angle=swiftshader", "--disable-gpu-compositing"],
    "no-sandbox": ["--no-sandbox"],
}
SANDBOX_REDUCING = {"gpu-sandbox-off", "no-sandbox"}
WINEDEBUG = "-all,err+all,+seh,+loaddll"
PHRASES = {
    "gpu_process_crash": re.compile(r"GPU process (?:exited|crashed|isn't usable)", re.I),
    "sandbox_failure": re.compile(r"sandbox", re.I),
    "renderer_crash": re.compile(r"renderer process (?:crashed|gone)", re.I),
    "angle_or_gl_error": re.compile(r"\bANGLE\b|eglInitialize|GL_INVALID", re.I),
    "d3d11_create_failure": re.compile(r"D3D11CreateDevice", re.I),
    "unhandled_exception": re.compile(r"unhandled exception|page fault", re.I),
    "unimplemented_function": re.compile(r"unimplemented function", re.I),
}


def owned(runtime: Path) -> Path:
    marker = runtime / "ownership.json"
    if json.loads(marker.read_text()).get("phase") != "p5-a-wine":
        raise RuntimeError("Runtime ownership mismatch")
    return runtime


def window_probe(runtime: Path) -> Path:
    tool = runtime / "tools/window_probe"
    if not tool.is_file():
        tool.parent.mkdir(parents=True, exist_ok=True)
        source = Path(__file__).with_name("bench_real3d_window_probe.swift")
        subprocess.run(["swiftc", "-O", str(source), "-o", str(tool)], check=True,
                       capture_output=True, timeout=300)
    return tool


def wine_pids(runtime: Path) -> list[int]:
    """Engine processes whose working directory lies inside this owned runtime.

    Supervised runs start with cwd=runtime and Wine services move to drive_c, so
    processes of other prefixes using the same engine are excluded.
    """
    ntdll = wine.resolve_four_way_components(wine.DEFAULT_ENGINE_ROOT)["wine_bin"].parent.parent \
        / "lib/wine/x86_64-unix/ntdll.so"
    holders = subprocess.run(["lsof", "-t", str(ntdll)], capture_output=True, text=True,
                             timeout=60).stdout.split()
    server = subprocess.run(["lsof", "-t", str(runtime / "prefix")], capture_output=True,
                            text=True, timeout=60).stdout.split()
    candidates = sorted({int(x) for x in holders + server if x.isdigit()})
    if not candidates:
        return []
    out = subprocess.run(["lsof", "-a", "-d", "cwd", "-p", ",".join(map(str, candidates)), "-Fpn"],
                         capture_output=True, timeout=60).stdout.decode("utf-8", "surrogateescape")
    root, pids, pid = str(runtime.resolve()), [], None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            name = line[1:]
            if name == root or name.startswith(root + "/"):
                pids.append(pid)
    return sorted(set(pids))


def windows(runtime: Path, pids: list[int]) -> list[dict]:
    if not pids:
        return []
    out = subprocess.run([str(window_probe(runtime)), "list", *map(str, pids)],
                         capture_output=True, text=True, timeout=30).stdout
    return json.loads(out or '{"windows": []}')["windows"]


def capture_stats(runtime: Path, window_id: int) -> dict:
    """Measure one window's pixels; the image itself is deleted immediately."""
    image = runtime / "private-capture.png"
    result = subprocess.run(["screencapture", "-x", "-o", "-l", str(window_id), str(image)],
                            capture_output=True, timeout=30)
    try:
        if result.returncode or not image.is_file():
            return {"capture": "unavailable", "native_exit_code": result.returncode}
        out = subprocess.run([str(window_probe(runtime)), "stats", str(image)],
                             capture_output=True, text=True, timeout=30).stdout
        return {"capture": "measured_and_deleted", **json.loads(out)}
    finally:
        image.unlink(missing_ok=True)


def prepare(runtime: Path, backend: str) -> dict:
    if runtime.exists():
        raise RuntimeError("Runtime already exists; inspect ownership before reuse")
    matches = [p for p in support.ROOT.glob("*_CN_installer_*.exe")
               if p.is_file() and support.sha256(p) == INSTALLER_SHA256]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one Windows-verified official installer")
    installer = matches[0]
    runtime.mkdir(parents=True)
    support.write_json(runtime / "ownership.json", {"owner": "@DNPMBHC", "phase": "p5-a-wine",
                                                    "backend": backend, "created_at": support.utc()})
    components = wine.resolve_four_way_components(wine.DEFAULT_ENGINE_ROOT)
    prefix = wine._prepare_prefix(components, backend, runtime)
    for directory, subdirs, filenames in os.walk(prefix / "drive_c/users", followlinks=False):
        for name in subdirs + filenames:
            entry = Path(directory) / name
            if entry.is_symlink():
                entry.unlink()
                entry.mkdir()
    devices = prefix / "dosdevices"
    for entry in devices.iterdir():
        if entry.is_symlink() and entry.name.lower() != "c:":
            entry.unlink()
    (runtime / "data").mkdir()
    (devices / "r:").symlink_to(runtime / "data", target_is_directory=True)
    tools = prefix / "drive_c/p5a-tools"
    tools.mkdir()
    shutil.copy2(installer, tools / "installer-x.exe")
    window_probe(runtime)
    return {"owner": "@DNPMBHC", "prepared_at_utc": support.utc(), "backend": backend,
            "wine_version": components["versions"]["wine"],
            "host_user_directory_links_removed": True, "host_drive_mappings_removed": True,
            "installer_sha256": INSTALLER_SHA256}


def find_launcher(runtime: Path, role: str) -> Path:
    roots = (runtime / "data", runtime / "prefix/drive_c")
    matches = [p for root in roots for p in root.rglob("*.exe")
               if p.is_file() and not p.is_symlink() and p.stat().st_size == LAUNCHER_SIZE[role] and support.sha256(p) == LAUNCHER_SHA256[role]]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one SHA-bound {role}; found {len(matches)}")
    return matches[0]


def to_windows_path(runtime: Path, path: Path) -> str:
    if (runtime / "data") in path.parents:
        return "R:\\" + str(path.relative_to(runtime / "data")).replace("/", "\\")
    return "C:\\" + str(path.relative_to(runtime / "prefix/drive_c")).replace("/", "\\")


def supervise(runtime: Path, stem: str, target: str, args: list[str], max_seconds: int,
              record: dict) -> dict:
    components = wine.resolve_four_way_components(wine.DEFAULT_ENGINE_ROOT)
    backend = json.loads((runtime / "ownership.json").read_text())["backend"]
    env = wine.build_backend_env(components, backend, runtime / "prefix", runtime, metalfx_preset="off")
    env["WINEDEBUG"] = WINEDEBUG
    out_dir = runtime / "runs"
    out_dir.mkdir(exist_ok=True)
    samples, captures, started = [], [], time.monotonic()
    record.update({"owner": "@DNPMBHC", "backend": backend, "arguments": args,
                   "winedebug": WINEDEBUG, "started_at_utc": support.utc(),
                   "official_bytes_modified": False, "authentication_automated": False,
                   "natural_exit_code": None})
    with (out_dir / (stem + ".private.log")).open("wb") as log:
        proc = subprocess.Popen([str(components["wine_bin"]), target, *args], env=env,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                cwd=runtime)
        (out_dir / (stem + ".pid")).write_text(str(proc.pid))
        stop_file = out_dir / (stem + ".stop")
        while True:
            code = proc.poll()
            elapsed = round(time.monotonic() - started, 1)
            pids = wine_pids(runtime)
            wins = windows(runtime, pids)
            visible = [w for w in wins if w["onscreen"] and w["width"] >= 200 and w["height"] >= 150]
            samples.append({"t_s": elapsed, "wine_process_count": len(pids),
                            "window_count": len(wins), "large_onscreen_windows": len(visible)})
            if visible and (not captures or elapsed - captures[-1]["t_s"] >= 30):
                largest = max(visible, key=lambda w: w["width"] * w["height"])
                captures.append({"t_s": elapsed, "width": largest["width"], "height": largest["height"],
                                 **capture_stats(runtime, largest["window_id"])})
            if code is not None:
                record.update({"natural_exit_code": code, "natural_exit_observed": True,
                               "ended_after_s": elapsed})
                break
            if stop_file.exists() or elapsed >= max_seconds:
                record.update({"natural_exit_observed": False, "controlled_stop": True,
                               "controlled_stop_after_s": elapsed,
                               "controlled_stop_reason": "user request" if stop_file.exists() else "max window"})
                os.killpg(proc.pid, signal.SIGTERM)
                subprocess.run([str(components["wineserver_bin"]), "-k"], env=env, capture_output=True)
                proc.wait(timeout=60)
                record["post_stop_wrapper_code_not_natural"] = proc.returncode
                break
            time.sleep(3)
    text = (out_dir / (stem + ".private.log")).read_text(errors="replace")
    record.update({"ended_at_utc": support.utc(), "window_samples": samples[-40:],
                   "sample_count": len(samples),
                   "max_large_onscreen_windows": max((s["large_onscreen_windows"] for s in samples), default=0),
                   "window_captures": captures, "log_summary": summarize(text)})
    return record


def summarize(text: str) -> dict:
    summary = diagnostics.summarize_log(text)
    summary["phrase_counts"] = {key: sum(1 for line in text.splitlines() if rx.search(line))
                                for key, rx in PHRASES.items()}
    summary["raw_content_exported"] = False
    return summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "install", "launch", "stop", "cleanup"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--backend", choices=("dxmt", "d3dmetal"), default="dxmt")
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="baseline")
    parser.add_argument("--role", choices=sorted(LAUNCHER_SHA256), default="launcher")
    parser.add_argument("--max-seconds", type=int, default=600)
    parser.add_argument("--stem")
    args = parser.parse_args(argv)
    evidence = Path(__file__).resolve().parent.parent / "handoff/module-f/valorant-real-runs"
    if args.action == "prepare":
        support.write_json(evidence / "wine-r2-prepare.json", prepare(args.runtime, args.backend))
        return 0
    runtime = owned(args.runtime)
    if args.action == "install":
        record = supervise(runtime, "install", r"C:\p5a-tools\installer-x.exe", [], args.max_seconds,
                           {"stage": "official_installer", "binary_sha256": INSTALLER_SHA256})
        support.write_json(evidence / "wine-r2-install.json", record)
        return 0
    if args.action == "launch":
        path = find_launcher(runtime, args.role)
        stem = args.stem or f"launch-{args.role}-{args.variant}"
        flags = ["--enable-logging=stderr", *VARIANTS[args.variant]]
        record = supervise(runtime, stem, to_windows_path(runtime, path), flags, args.max_seconds,
                           {"stage": "official_launcher", "role": args.role, "variant": args.variant,
                            "binary_sha256": LAUNCHER_SHA256[args.role],
                            "launcher_sandbox_reduced": args.variant in SANDBOX_REDUCING})
        support.write_json(evidence / f"wine-r2-{stem}.json", record)
        return 0
    if args.action == "stop":
        for marker in (runtime / "runs").glob("*.pid"):
            marker.with_suffix(".stop").touch()
        return 0
    components = wine.resolve_four_way_components(wine.DEFAULT_ENGINE_ROOT)
    env = {**os.environ, "WINEPREFIX": str(runtime / "prefix")}
    subprocess.run([str(components["wineserver_bin"]), "-k"], env=env, capture_output=True)
    remaining = wine_pids(runtime)
    if remaining:
        raise RuntimeError("Owned Wine processes remain; refusing removal")
    shutil.rmtree(runtime)
    support.write_json(evidence / "wine-r2-cleanup.json", {"owner": "@DNPMBHC", "cleaned_at_utc": support.utc(),
                                                           "owned_runtime_deleted": not runtime.exists(),
                                                           "remaining_owned_wine_processes": 0})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
