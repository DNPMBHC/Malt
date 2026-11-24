#!/usr/bin/env python3
"""Collect actual DXGI adapter fingerprints without guessing a rendering driver."""
from __future__ import annotations
import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from benchmark_support import (SCRIPT_DIR, EVIDENCE_DIR, GUEST_DIR, GuestSession,
    checked, discover_started_vm, discover_utmctl, fingerprint, redact_text,
    runtime_environment, sha256_file, writable_path, write_json, validate_guest_environment)
import run_wine_benchmark as wine

def discover_engine_root() -> Path:
    candidates = list((Path.home() / "Library" / "Application Support").glob("*/wine-engine"))
    available = [p for p in candidates if (p / "downloads" / "dxmt-v0.80").is_dir()]
    if len(available) != 1:
        raise RuntimeError("one installed three-engine runtime is required")
    return available[0]

def collect_host(output: Path, probe: Path, engine_root: Path | None) -> list[dict]:
    components = wine.resolve_wine_components(engine_root or discover_engine_root())
    runs = []
    for backend in ("dxvk", "d3dmetal", "dxmt"):
        work = writable_path(SCRIPT_DIR / "build" / "m0-runtime" / backend)
        work.mkdir(parents=True, exist_ok=True)
        env = runtime_environment(work)
        env.update({"USER": "runner-x", "LOGNAME": "runner-x"})
        previous = os.environ.copy()
        try:
            os.environ.update(env)
            prefix = wine._prepare_prefix(components, backend, work)
            backend_env = wine._backend_env(components, backend, prefix, work)
            backend_env.update(env)
            backend_env["WINEPREFIX"] = str(prefix)
            # Avoid a host-path argument in the Windows process command line.
            guest_bin = prefix / "drive_c" / "graphics-lab" / "d3d11_probe.exe"
            guest_bin.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(probe, guest_bin)
            metadata_file = guest_bin.parent / "fingerprint.json"
            result = subprocess.run([str(components["wine_bin"]), r"C:\graphics-lab\d3d11_probe.exe",
                "--fingerprint-only", "--metadata-json", r"C:\graphics-lab\fingerprint.json"],
                cwd=work, env=backend_env, capture_output=True, text=True, timeout=180)
            wine._kill_wineserver(components["wineserver_bin"], prefix)
            run_dir = output / backend
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir / "stderr.log").write_text(redact_text(result.stderr), encoding="utf-8")
            if result.returncode or not metadata_file.is_file():
                raise RuntimeError(f"{backend} actual adapter probe failed")
            metadata = json.loads(metadata_file.read_text())
            actual = fingerprint(metadata)
            write_json(run_dir / "metadata.json", metadata)
            run = {"environment": "host-wine", "engine": backend, "fingerprint": actual,
                "session_semantics": "Wine ProcessIdToSessionId result, not a Windows desktop session",
                "metadata": f"{backend}/metadata.json",
                "metadata_sha256": sha256_file(run_dir / "metadata.json"),
                "probe_source_sha256": sha256_file(SCRIPT_DIR / "d3d11_probe.cpp"),
                "probe_binary_sha256": sha256_file(probe),
                "engine_digests": components["digests"], "engine_versions": components["versions"]}
            write_json(run_dir / "run.json", run)
            runs.append(run)
            print(json.dumps({"engine": backend, "fingerprint": actual}, sort_keys=True), flush=True)
        finally:
            os.environ.clear()
            os.environ.update(previous)
    return runs

def collect_guest(output: Path, probe: Path) -> list[dict]:
    utmctl = discover_utmctl()
    guest = GuestSession(utmctl, discover_started_vm(utmctl))
    guest_metadata = guest.metadata()
    validate_guest_environment(guest_metadata)
    verified = guest.prepare_probe(probe)
    metadata_name = "m0-hardware-metadata.json"
    run = guest.run_interactive("m0-hardware", ["--fingerprint-only", "--metadata-json", GUEST_DIR + "\\" + metadata_name],
        output / "guest", [metadata_name])
    metadata = json.loads((output / "guest" / metadata_name).read_text())
    actual = fingerprint(metadata)
    if actual["windows_session_id"] == 0:
        raise RuntimeError("Guest adapter probe must run in an interactive desktop session")
    run.update({"environment": "windows-guest", "guest": guest_metadata, "fingerprint": actual,
        "probe_source_sha256": sha256_file(SCRIPT_DIR / "d3d11_probe.cpp"),
        "probe_binary_sha256": verified, "metadata": f"guest/{metadata_name}",
        "metadata_sha256": sha256_file(output / "guest" / metadata_name)})
    write_json(output / "guest" / "run.json", run)
    print(json.dumps({"environment": "windows-guest", "fingerprint": actual}, sort_keys=True), flush=True)
    return [run]

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=EVIDENCE_DIR / "m0-adapters")
    parser.add_argument("--probe", type=Path, default=SCRIPT_DIR / "build" / "d3d11_probe.exe")
    parser.add_argument("--engine-root", type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--host-only", action="store_true")
    group.add_argument("--guest-only", action="store_true")
    args = parser.parse_args()
    output = writable_path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    inputs = output / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    for name, source in (("d3d11_probe.cpp", SCRIPT_DIR / "d3d11_probe.cpp"),
                         ("d3d11_probe.exe", args.probe),
                         ("run_m0_fingerprints.py", SCRIPT_DIR / "run_m0_fingerprints.py"),
                         ("benchmark_support.py", SCRIPT_DIR / "benchmark_support.py"),
                         ("run_wine_benchmark.py", SCRIPT_DIR / "run_wine_benchmark.py"),
                         ("build_probe.sh", SCRIPT_DIR / "build_probe.sh")):
        shutil.copy2(source, inputs / name)
    runs = []
    try:
        if not args.guest_only:
            runs += collect_host(output, args.probe, args.engine_root)
        if not args.host_only:
            runs += collect_guest(output, args.probe)
        manifest = {"schema_version": 1, "owner": "@DNPMBHC", "kind": "actual-dxgi-adapter-fingerprints",
            "runs": runs, "guest_collected": any(r["environment"] == "windows-guest" for r in runs),
            "input_artifacts": {name: {"file": "inputs/" + name, "sha256": sha256_file(inputs / name)}
                for name in ("d3d11_probe.cpp", "d3d11_probe.exe", "run_m0_fingerprints.py",
                             "benchmark_support.py", "run_wine_benchmark.py", "build_probe.sh")}}
        old = output / "manifest.json"
        if old.is_file():
            previous = json.loads(old.read_text()).get("runs", [])
            replaced = {(r["environment"], r.get("engine")) for r in runs}
            manifest["runs"] = [r for r in previous if (r["environment"], r.get("engine")) not in replaced] + runs
            manifest["guest_collected"] = any(r["environment"] == "windows-guest" for r in manifest["runs"])
        write_json(old, manifest)
        return 0
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        write_json(output / "failure.json", {"error": redact_text(str(error)), "completed_runs": runs})
        print(json.dumps({"passed": False, "error": redact_text(str(error))}), flush=True)
        return 1
if __name__ == "__main__":
    raise SystemExit(main())
