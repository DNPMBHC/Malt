#!/usr/bin/env python3
"""Rebuild/restart native host probes and collect bound evidence. Owner: @DNPMBHC."""
from __future__ import annotations
import argparse
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import uuid
import plistlib
from datetime import datetime, timezone
from pathlib import Path
from vz_gpu_bench_support import compare_pair, redact, save_json, sha256_file

ROOT = Path(__file__).resolve().parents[1]
APP = next(path for path in ROOT.iterdir() if path.is_dir() and (path / ".swiftlint.yml").is_file())
MODULE = APP / "Modules" / "vz-gpu-bridge"
EVIDENCE = ROOT / "handoff" / "phase-5" / "evidence" / "p5-b"
BUILD = Path(tempfile.gettempdir()) / "demo-app-phase5b-native-build"
BINARY = BUILD / "demo-app"


def capture(arguments: list[str], *, cwd: Path | None = None, timeout: int = 120, env: dict | None = None) -> subprocess.CompletedProcess:
    process = subprocess.Popen(arguments, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True, env=env)
    try:
        output, error = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, error = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, error = process.communicate()
        raise RuntimeError("Owned experiment timeout") from None
    return subprocess.CompletedProcess(arguments, process.returncode, output, error)


def build() -> dict:
    BUILD.mkdir(parents=True, exist_ok=True)
    sources = sorted(path for path in MODULE.iterdir() if path.suffix in (".swift", ".c", ".h"))
    snapshot = BUILD / ("sources-" + uuid.uuid4().hex)
    snapshot.mkdir()
    digests = {}
    for path in sources:
        destination = snapshot / path.name
        destination.write_bytes(path.read_bytes())
        digests[path.name] = sha256_file(destination)
    staged = BUILD / ("demo-app-" + uuid.uuid4().hex)
    object_file = BUILD / ("ffi-" + uuid.uuid4().hex + ".o")
    ffi = capture(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", "-c",
                   str(snapshot / "RendererFFIProbe.c"), "-o", str(object_file)])
    if ffi.returncode:
        print(redact(ffi.stdout + ffi.stderr, ROOT))
        raise RuntimeError("C FFI compilation failed")
    command = ["xcrun", "swiftc", "-O", "-warnings-as-errors", "-module-cache-path", str(BUILD / "module-cache"),
               "-import-objc-header", str(snapshot / "RendererFFIProbe.h"), str(object_file)]
    for application in Path("/Applications").glob("*.app"):
        frameworks = application / "Contents" / "Frameworks"
        if (frameworks / "virglrenderer.1.framework").exists():
            command += ["-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
            break
    command += [str(path) for path in sorted(snapshot.glob("*.swift"))] + ["-o", str(staged)]
    result = capture(command)
    log = redact(result.stdout + result.stderr, ROOT)
    if result.returncode:
        print(log)
        raise RuntimeError("Native compilation failed")
    current_names = {path.name for path in MODULE.iterdir() if path.suffix in (".swift", ".c", ".h")}
    if current_names != set(digests) or any(sha256_file(path) != digests[path.name] for path in sources):
        raise RuntimeError("Source changed during compilation; rebuild required")
    signed = capture(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
                      str(MODULE / "vz_bridge.entitlements"), str(staged)])
    if signed.returncode:
        raise RuntimeError("Native Hardened Runtime signing failed")
    check = capture([str(staged), "--mode", "protocol-self-test"], timeout=15)
    if check.returncode or not all(json.loads(check.stdout).values()):
        raise RuntimeError("Built binary did not execute current protocol self-test")
    staged.replace(BINARY)
    binding = {"owner": "@DNPMBHC", "binary_sha256": sha256_file(BINARY),
               "compile_exit": 0, "codesign_exit": 0, "source_snapshot_verified": True,
               "sources": digests,
               "entitlements_sha256": sha256_file(MODULE / "vz_bridge.entitlements")}
    save_json(EVIDENCE / "build-binding.json", binding)
    (EVIDENCE / "native-compile.log").write_text(log or "Native optimized compilation: exit 0\n")
    return binding


def run_mode(mode: str, extra: list[str] | None = None, timeout: int = 120) -> dict:
    binding = json.loads((EVIDENCE / "build-binding.json").read_text())
    current_names = {path.name for path in MODULE.iterdir() if path.suffix in (".swift", ".c", ".h")}
    if current_names != set(binding["sources"]) or any(
            sha256_file(MODULE / name) != digest for name, digest in binding["sources"].items()):
        raise RuntimeError("Source differs from executable binding; rebuild required")
    if sha256_file(BINARY) != binding["binary_sha256"]:
        raise RuntimeError("Executable SHA-256 changed after verified build")
    result = capture([str(BINARY), "--mode", mode] + (extra or []), timeout=timeout)
    log = redact(result.stdout + result.stderr, ROOT)
    if result.returncode:
        raise RuntimeError("Native mode failed: " + mode + " exit=" + str(result.returncode) + " " + log[-800:])
    return json.loads(result.stdout)


def stop() -> bool:
    pid_file = BUILD / "host.pid"
    if not pid_file.exists():
        return False
    pid = int(pid_file.read_text())
    check = capture(["ps", "-p", str(pid), "-o", "command="])
    if not check.stdout.strip().startswith(str(BINARY) + " --mode serve"):
        pid_file.unlink(missing_ok=True)
        return False
    os.kill(pid, signal.SIGTERM)
    for _ in range(20):
        check = capture(["ps", "-p", str(pid), "-o", "command="])
        if not check.stdout.strip().startswith(str(BINARY) + " --mode serve"):
            break
        time.sleep(0.05)
    else:
        os.kill(pid, signal.SIGKILL)
    pid_file.unlink(missing_ok=True)
    return True


def restart() -> dict:
    binding = build()
    stopped = stop()
    output = (BUILD / "host-ready.json").open("w")
    errors = (BUILD / "host-error.log").open("w")
    process = subprocess.Popen([str(BINARY), "--mode", "serve"], stdout=output, stderr=errors,
                               start_new_session=True)
    (BUILD / "host.pid").write_text(str(process.pid))
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("Native server exited before readiness")
            try:
                ready = json.loads((BUILD / "host-ready.json").read_text())
                if all(ready.values()):
                    report = {"owner": "@DNPMBHC", "previous_owned_instance_stopped": stopped,
                              "ready": ready, "binary_sha256": binding["binary_sha256"]}
                    save_json(EVIDENCE / "restart-verification.json", report)
                    return report
            except json.JSONDecodeError:
                pass
            time.sleep(0.05)
        raise RuntimeError("Native server readiness timeout")
    finally:
        output.close()
        errors.close()


def signed_renderer_bundle_probe(signing_identity: str = "-") -> dict:
    application = next((path for path in Path("/Applications").glob("*.app")
                        if (path / "Contents/Frameworks/virglrenderer.1.framework").exists()), None)
    if application is None:
        return {"status": "reference_renderer_unavailable"}
    reference = application / "Contents"
    with tempfile.TemporaryDirectory(prefix="demo-app-ffi-bundle-") as temporary:
        bundle = Path(temporary) / "Demo.app"
        frameworks = bundle / "Contents/Frameworks"
        macos = bundle / "Contents/MacOS"
        resources = bundle / "Contents/Resources/vulkan/icd.d"
        for folder in (frameworks, macos, resources):
            folder.mkdir(parents=True)
        components = ("virglrenderer.1.framework", "epoxy.0.framework", "vulkan.1.framework",
                      "vulkan_kosmickrisp.framework")
        originals = {}
        for name in components:
            source = reference / "Frameworks" / name
            if not source.exists():
                return {"status": "dependency_unavailable", "dependency": name}
            binary = source / name.removesuffix(".framework")
            originals[name] = sha256_file(binary)
            destination = frameworks / name
            shutil.copytree(source, destination, symlinks=True)
            signed = capture(["codesign", "--force", "--sign", signing_identity,
                              "--options", "runtime", str(destination)])
            if signed.returncode:
                raise RuntimeError("Temporary renderer component signing failed")
        shutil.copy2(reference / "Resources/vulkan/icd.d/kosmickrisp_mesa_icd.json",
                     resources / "kosmickrisp_mesa_icd.json")
        executable = macos / "demo-app"
        shutil.copy2(BINARY, executable)
        changed = capture(["install_name_tool", "-delete_rpath", str(reference / "Frameworks"),
                           "-add_rpath", "@executable_path/../Frameworks", str(executable)])
        if changed.returncode:
            raise RuntimeError("Temporary bundle rpath update failed")
        signed = capture(["codesign", "--force", "--sign", signing_identity,
                          "--options", "runtime", "--entitlements",
                          str(MODULE / "vz_bridge.entitlements"), str(executable)])
        if signed.returncode:
            raise RuntimeError("Temporary host executable signing failed")
        environment = dict(os.environ, DEMO_RENDERER_BUNDLE=str(bundle))
        result = capture([str(executable), "--mode", "virgl-probe"], timeout=30, env=environment)
        report = {"owner": "@DNPMBHC", "source_application_modified": False,
                  "hardened_runtime": True, "library_validation_disabled": False,
                  "signing_kind": "ad_hoc" if signing_identity == "-" else "local_identity",
                  "process_exit": result.returncode, "source_component_sha256": originals}
        if result.returncode == 0:
            report["ffi"] = json.loads(result.stdout)
        else:
            report["error"] = redact(result.stderr.split("*** First throw call stack:")[0], ROOT)[:1500]
        report["source_application_hashes_unchanged"] = all(
            sha256_file(reference / "Frameworks" / name / name.removesuffix(".framework")) == digest
            for name, digest in originals.items())
        output_name = "signed-renderer-bundle.json" if signing_identity == "-" else "signed-renderer-team-bundle.json"
        save_json(EVIDENCE / output_name, report)
        return report


def signing_matrix() -> list[dict]:
    results = []
    with tempfile.TemporaryDirectory(prefix="demo-app-signing-") as temporary:
        directory = Path(temporary)
        empty = directory / "empty.plist"
        empty.write_bytes(plistlib.dumps({}))
        cases = (("hardened_virtualization", True, MODULE / "vz_bridge.entitlements"),
                 ("hardened_no_virtualization", True, empty),
                 ("nonhardened_virtualization", False, MODULE / "vz_bridge.entitlements"))
        for name, hardened, entitlements in cases:
            executable = directory / name
            shutil.copy2(BINARY, executable)
            command = ["codesign", "--force", "--sign", "-"]
            if hardened:
                command += ["--options", "runtime"]
            command += ["--entitlements", str(entitlements), str(executable)]
            signed = capture(command)
            if signed.returncode:
                raise RuntimeError("Signing matrix preparation failed")
            validation = capture([str(executable), "--mode", "validate"])
            row = {"case": name, "binary_sha256": sha256_file(executable),
                   "validation_exit": validation.returncode}
            if validation.returncode == 0:
                row["signature"] = json.loads(validation.stdout)["entitlementProbe"]
            runtime = capture([str(executable), "--mode", "runtime-case", "--frames", "1"])
            row["runtime_exit"] = runtime.returncode
            if runtime.returncode == 0:
                row["runtime"] = json.loads(runtime.stdout)
            else:
                row["runtime_error"] = redact(runtime.stderr.split("*** First throw call stack:")[0], ROOT)[:1000]
            ffi = capture([str(executable), "--mode", "virgl-probe"], timeout=30)
            row["ffi_exit"] = ffi.returncode
            row["ffi_diagnostics"] = redact(ffi.stderr, ROOT)[:1500]
            if ffi.returncode == 0:
                row["ffi"] = json.loads(ffi.stdout)
            else:
                row["ffi_error"] = redact(ffi.stderr.split("*** First throw call stack:")[0], ROOT)[:1000]
            results.append(row)
    save_json(EVIDENCE / "signing-matrix.json", results)
    return results


def diagnostics() -> dict:
    reports = {}
    for mode in ("validate", "runtime-probe", "secure-boot-probe", "protocol-self-test", "producer-probe", "virgl-probe"):
        reports[mode] = run_mode(mode)
        save_json(EVIDENCE / (mode + ".json"), reports[mode])
    reports["signing-matrix"] = signing_matrix()
    reports["signed-renderer-bundle"] = signed_renderer_bundle_probe()
    negatives = []
    for index, name in ((1, "unaligned_pointer"), (2, "unaligned_offset"),
                        (3, "unaligned_length"), (4, "outside_region")):
        result = capture([str(BINARY), "--mode", "runtime-case", "--frames", str(index + 1)])
        detail = {"name": name, "process_exit": result.returncode}
        if result.returncode:
            detail["exception"] = redact(result.stderr.split("*** First throw call stack:")[0], ROOT).strip()
            if "NSInvalidArgumentException" not in detail["exception"]:
                raise RuntimeError("Unexpected negative mapping failure")
        else:
            detail["runtime_report"] = json.loads(result.stdout)
            if any(case["succeeded"] for case in detail["runtime_report"]["mappings"]):
                raise RuntimeError("Invalid mapping was accepted")
        negatives.append(detail)
    save_json(EVIDENCE / "mapping-negative-cases.json", negatives)
    for width, height in ((1280, 720), (2560, 1440)):
        report = run_mode("present-smoke", ["--width", str(width), "--height", str(height)], timeout=60)
        if report["presentedDrawables"] < 1 or not report["sameIOSurfaceBackedTexture"]:
            raise RuntimeError("Actual native presentation was not observed")
        save_json(EVIDENCE / ("present-" + str(width) + ".json"), report)
        reports["present-" + str(width)] = report
    return reports


def ipc_run(extra: list[str], socket_path: Path, *, copy_frames: bool = True) -> tuple[dict, dict]:
    with tempfile.TemporaryFile(mode="w+") as output, tempfile.TemporaryFile(mode="w+") as errors:
        worker_mode = "bench-ipc-worker" if copy_frames else "bench-ipc-control-worker"
        client_mode = "bench-ipc-client" if copy_frames else "bench-ipc-control-client"
        worker = subprocess.Popen([str(BINARY), "--mode", worker_mode] + extra +
                                  ["--socket", str(socket_path)], stdout=output, stderr=errors,
                                  start_new_session=True)
        try:
            client = run_mode(client_mode, extra + ["--socket", str(socket_path)])
            worker.wait(timeout=15)
            output.seek(0)
            if worker.returncode:
                raise RuntimeError("IPC worker failed")
            worker_report = json.load(output)
            if not copy_frames:
                client["imageSHA256"] = worker_report["imageSHA256"]
                client["image_validation_origin"] = "renderer_worker"
            return client, worker_report
        finally:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGTERM)
                worker.wait(timeout=5)


def benchmark(rounds: int, frames: int, warmup: int) -> dict:
    results = []
    with tempfile.TemporaryDirectory(prefix="demo-app-gpu-ipc-") as temporary:
        for width, height in ((1280, 720), (2560, 1440)):
            for index in range(rounds):
                extra = ["--width", str(width), "--height", str(height), "--draws", "2048",
                         "--frames", str(frames), "--warmup", str(warmup)]
                socket_path = Path(temporary) / "frame.sock"
                order = (("native", "control", "copy"), ("control", "copy", "native"),
                         ("copy", "native", "control"))[index % 3]
                samples = {}
                for mode in order:
                    samples[mode] = run_mode("bench-zerocopy", extra) if mode == "native" else ipc_run(
                        extra, socket_path, copy_frames=mode == "copy")
                native = samples["native"]
                ipc, worker = samples["copy"]
                control, control_worker = samples["control"]
                comparison = compare_pair(native, ipc, worker)
                control_comparison = compare_pair(native, control, control_worker)
                results.append({"resolution": [width, height], "round": index + 1, "mode_order": order,
                                "native": native, "ipc_client": ipc, "ipc_worker": worker,
                                "comparison": comparison, "ipc_control_client": control,
                                "ipc_control_worker": control_worker, "control_comparison": control_comparison,
                                "pixel_copy_cost_ms": ipc["meanMs"] - control["meanMs"]})
                print(json.dumps({"resolution": [width, height], "round": index + 1,
                                  "mean_saved_ms": comparison["mean_latency_saved_ms"]}), flush=True)
    binding = json.loads((EVIDENCE / "build-binding.json").read_text())
    if sha256_file(BINARY) != binding["binary_sha256"]:
        raise RuntimeError("Measured binary changed during benchmark")
    report = {"build_binding": binding,
              "configuration_validation": json.loads((EVIDENCE / "validate.json").read_text()),
              "runtime_mapping": json.loads((EVIDENCE / "runtime-probe.json").read_text()),
              "benchmark_script_sha256": sha256_file(Path(__file__)),
              "evidence_validator_sha256": sha256_file(ROOT / "graphics-lab/vz_gpu_bench_support.py"),
              "evidence_sha256": {name: sha256_file(EVIDENCE / name) for name in
                                  ("validate.json", "runtime-probe.json", "signing-matrix.json",
                                   "producer-probe.json", "producer-library-binding.json")},
              "owner": "@DNPMBHC", "experiment_started_on": "2026-11-23", "captured_at_utc": datetime.now(timezone.utc).isoformat(), "binary_sha256": sha256_file(BINARY),
              "draw_calls": 2048, "frames_per_round": frames, "warmup_frames": warmup,
              "rounds_per_resolution": rounds, "maximum_in_flight": 1,
              "presentation_in_primary_benchmark": False,
              "real_qemu_comparison": {"status": "not_measured_identical_guest_workload_unavailable"},
              "runs": results}
    save_json(EVIDENCE / "vz-zero-copy-benchmark.json", report)
    return report


def clean() -> dict:
    stop()
    shutil.rmtree(BUILD, ignore_errors=True)
    shutil.rmtree(MODULE / "build", ignore_errors=True)
    shutil.rmtree(MODULE / ".build", ignore_errors=True)
    for path in MODULE.rglob("*.pcm"):
        path.unlink()
    return {"owner": "@DNPMBHC", "owned_build_cache_removed": True}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("build", "restart", "stop", "diagnostics", "bench", "clean"))
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=60)
    args = parser.parse_args()
    if args.action == "build": result = build()
    elif args.action == "restart": result = restart()
    elif args.action == "stop": result = {"owned_instance_stopped": stop()}
    elif args.action == "diagnostics": result = diagnostics()
    elif args.action == "bench": result = benchmark(args.rounds, args.frames, args.warmup)
    else: result = clean()
    print(json.dumps({"action": args.action, "completed": True,
                      "detail": result if args.action in ("stop", "clean", "restart") else "evidence_written"}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print(redact(str(error), ROOT))
        raise SystemExit(1) from None
