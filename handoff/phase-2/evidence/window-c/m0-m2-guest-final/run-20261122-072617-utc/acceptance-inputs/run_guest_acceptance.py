#!/usr/bin/env python3
"""Run module-c acceptance only after the explicit file-based Guest handoff."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
from zoneinfo import ZoneInfo
from benchmark_support import (EVIDENCE_DIR, SCRIPT_DIR, WORKSPACE_ROOT, GuestSession,
    discover_utmctl, discover_started_vm, redact_text, runtime_environment,
    source_digests, sha256_file, stop_metal_host, writable_path, write_json)

A_HANDOFF = EVIDENCE_DIR.parent / "window-a" / "guest-benchmark-handoff.json"
C_HANDOFF = EVIDENCE_DIR / "guest-benchmark-handoff.json"

def freeze_inputs(output: Path) -> dict:
    names = ("run_guest_acceptance.py", "run_guest_m2_benchmark.py", "run_guest_pixel_validation.py",
             "run_m0_fingerprints.py", "guest_preflight.py", "guest_preflight.ps1",
             "benchmark_support.py", "analyze.py", "command_protocol.py", "pixel_compare.py",
             "d3d11_probe.cpp", "metal_host.swift", "restart_metal_host.sh",
             "build_probe.sh", "build_metal_host.sh", "build/d3d11_probe.exe")
    target = output / "acceptance-inputs"
    files = {}
    for name in names:
        source = SCRIPT_DIR / name
        copy = target / name
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, copy)
        digest = sha256_file(copy)
        if sha256_file(source) != digest:
            raise RuntimeError("acceptance input changed while archiving")
        files[name] = {"file": copy.relative_to(output).as_posix(), "sha256": digest}
    write_json(output / "acceptance-inputs.json", {"owner":"@DNPMBHC", "files":files})
    return files

def verify_inputs(files: dict) -> None:
    if any(sha256_file(SCRIPT_DIR / name) != record["sha256"] for name, record in files.items()):
        raise RuntimeError("acceptance source or probe binary changed during execution")

def validate_acceptance_manifests(m0: dict, pixels: dict, performance: dict,
                                  files: dict, session: int) -> dict:
    if not m0.get("guest_collected") or not pixels.get("passed") or not pixels.get("complete") or not performance.get("complete"):
        raise RuntimeError("acceptance manifests are incomplete")
    if pixels.get("performance_measurement") is not False or performance.get("performance_measurement") is not True:
        raise RuntimeError("correctness and performance measurement scopes are inconsistent")
    guest_runs = [run for run in m0["runs"] if run["environment"] == "windows-guest"]
    if len(guest_runs) != 1:
        raise RuntimeError("acceptance requires one actual Guest adapter fingerprint")
    guest_run = guest_runs[0]
    adapter = guest_run["fingerprint"]
    if adapter.get("requested_driver_type") != "hardware" or adapter["windows_session_id"] != session or (
        pixels["windows_session_id"] != session or performance["windows_session_id"] != session):
        raise RuntimeError("acceptance stages changed the actual Windows session or adapter request")
    cpp = files["d3d11_probe.cpp"]["sha256"]
    probe = files["build/d3d11_probe.exe"]["sha256"]
    swift = files["metal_host.swift"]["sha256"]
    if guest_run["probe_source_sha256"] != cpp or guest_run["probe_binary_sha256"] != probe or (
        pixels["probe_binary_sha256"] != probe or performance["probe_binary_sha256"] != probe):
        raise RuntimeError("acceptance stages used different probe inputs")
    for name, manifest in (("d3d11_probe.cpp", m0["input_artifacts"]),
                           ("d3d11_probe.exe", m0["input_artifacts"])):
        if manifest[name]["sha256"] != (cpp if name.endswith(".cpp") else probe):
            raise RuntimeError("M0 archived probe input differs from its actual execution")
    for evidence in (pixels, *pixels["cases"], *performance["runs"]):
        digests = evidence["source_digests"]
        if (digests["d3d11_probe_cpp"], digests["d3d11_probe_exe"], digests["metal_host_swift"]) != (cpp, probe, swift):
            raise RuntimeError("acceptance rendering inputs differ across stages")
    workload = performance["workload"]
    expected = {"width":1280,"height":720,"commands":16,"resource_bytes":65536,
                "frames":300,"warmup":60,"rounds":3,"command_every":30,
                "resource_every":30,"resource_pattern":"legacy"}
    if any(type(workload.get(key)) is not type(value) or workload[key] != value for key, value in expected.items()):
        raise RuntimeError("formal paired benchmark workload differs from 9 runs and 3240 total frames")
    modes = ("direct-present", "pixel-readback", "command-only")
    runs = performance["runs"]
    if len(runs) != 9 or {(run["mode"], run["round"]) for run in runs} != {
        (mode, round_index) for mode in modes for round_index in (1, 2, 3)}:
        raise RuntimeError("formal paired benchmark requires all nine unique mode/round runs")
    for run in runs:
        if run["fingerprint"] != adapter or run["completion"]["measured_frames"] != 300 or run.get("performance_measurement") is not True:
            raise RuntimeError("paired benchmark run changed its adapter or measured frame count")
    for mode in modes:
        comparison = performance["comparison"][mode]
        if (comparison["rounds"], comparison["measured_frames"], comparison["frame_interval_ms"]["sample_count"]) != (3, 900, 897):
            raise RuntimeError("formal comparison has incomplete frame or interval samples")
    cases = pixels["cases"]
    if len(cases) != 4 or {(case["pattern"], case["frame_sequence"]) for case in cases} != {
        ("legacy",0),("seeded",0),("seeded",30),("seeded",31)}:
        raise RuntimeError("Guest pixel validation cases are incomplete")
    for case in cases:
        if case["replay_adapter"] != adapter or case["reference_adapter"]["windows_session_id"] != session or (
            case["reference_adapter"]["requested_driver_type"] != "warp" or not case["reference_adapter"]["adapter_software_flag"]):
            raise RuntimeError("pixel cases changed the Guest session or software reference")
        comparison = case["comparison"]
        error = comparison["max_channel_error"]
        if comparison["passed"] is not True or type(error) is not int or not 0 <= error <= 1 or type(comparison["compared_pixels"]) is not int or comparison["compared_pixels"] != 1280 * 720:
            raise RuntimeError("Guest cross-API pixel comparison is incomplete or exceeds one LSB")
    return adapter

def handoff_time(record: dict) -> datetime:
    for field in ("captured_at_utc", "captured_at", "timestamp_utc", "released_at_utc", "recorded_at_utc", "updated_at_utc", "time_utc"):
        value = record.get(field)
        if isinstance(value, str):
            try:
                instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if instant.tzinfo is not None:
                    return instant.astimezone(timezone.utc)
            except ValueError:
                pass
    raise ValueError("handoff requires an explicit timezone-aware UTC timestamp")

def validate_handoff(record: dict, previous: dict | None = None) -> None:
    if record.get("released") is not True or record.get("next_owner") != "C" or record.get("guest_jobs_clean") is not True:
        raise ValueError("Guest has not been explicitly released cleanly to C")
    instant = handoff_time(record)
    if instant.timestamp() > time.time():
        raise ValueError("handoff timestamp is in the future")
    if previous and previous.get("released") is True and handoff_time(previous) >= instant:
        raise ValueError("this Guest handoff has already been consumed and released")

def require_handoff() -> dict:
    if not A_HANDOFF.is_file():
        raise ValueError("waiting for module-a Guest handoff file")
    record = json.loads(A_HANDOFF.read_text())
    previous = json.loads(C_HANDOFF.read_text()) if C_HANDOFF.is_file() else None
    validate_handoff(record, previous)
    return record

def run_stage(name: str, arguments: list[str], output: Path) -> None:
    print(json.dumps({"stage": name, "status": "running"}), flush=True)
    log_path = output / (name + ".log")
    with log_path.open("w", encoding="utf-8") as log:
        with subprocess.Popen([sys.executable, str(SCRIPT_DIR / arguments[0]), *arguments[1:]],
            cwd=WORKSPACE_ROOT, env=runtime_environment(SCRIPT_DIR / "build" / "acceptance-runtime"),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
            for line in process.stdout:
                cleaned = redact_text(line)
                log.write(cleaned)
                log.flush()
                print(cleaned, end="", flush=True)
            code = process.wait()
    if code:
        raise RuntimeError(f"{name} acceptance failed with exit code {code}")

def report(output: Path, preflight: dict) -> dict:
    m0 = json.loads((output / "m0-adapters" / "manifest.json").read_text())
    pixels = json.loads((output / "pixel-validation" / "manifest.json").read_text())
    performance = json.loads((output / "three-mode-benchmark" / "manifest.json").read_text())
    inputs = json.loads((output / "acceptance-inputs.json").read_text())["files"]
    adapter = validate_acceptance_manifests(m0, pixels, performance, inputs, preflight["console_session_id"])
    guest_run = next(run for run in m0["runs"] if run["environment"] == "windows-guest")
    controller_names = [item["description"] for item in guest_run["guest"]["display_adapters"]]
    reference_adapter = pixels["cases"][0]["reference_adapter"]
    metadata = json.loads((output / "m0-adapters" / guest_run["metadata"]).read_text())
    lines = ["# M0 / M2 真实 Guest 验收", "", "负责方：@DNPMBHC。时间：" + datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d %H:%M:%S") + "（Asia/Shanghai）。", "",
        "Windows HARDWARE 请求实际选择的适配器：`" + adapter["adapter_description"] + "`；vendor/device=" + str(adapter["vendor_id"]) + "/" + str(adapter["device_id"]) + "，flags=" + str(adapter["adapter_flags"]) + "，software=" + str(adapter["adapter_software_flag"]).lower() + "，feature level=" + adapter["selected_feature_level"] + "，Windows Session=" + str(adapter["windows_session_id"]) + "。", "",
        "Win32_VideoController 本轮检测到：" + "、".join(controller_names) + "。显式 WARP 请求的实际适配器为 `" + reference_adapter["adapter_description"] + "`，vendor/device=" + str(reference_adapter["vendor_id"]) + "/" + str(reference_adapter["device_id"]) + "，flags=" + str(reference_adapter["adapter_flags"]) + "，software=" + str(reference_adapter["adapter_software_flag"]).lower() + "。完整 DXGI 枚举与创建 HRESULT 保存在 M0 原始元数据中。", "",
        "显式 Guest WARP 参考与宿主 Metal 原生 RGBA 的四组逐像素对照全部通过，最大逐通道误差 " + str(max(case["comparison"]["max_channel_error"] for case in pixels["cases"])) + " LSB。正确性捕获未混入性能运行。", "",
        "以下统计使用同一 Session、同一二进制、1280×720、16 次绘制、64 KiB 资源，三轮轮换，每组 60 帧预热加 300 帧测量。FPS 用所有轮次的测量帧数除以 GPU 完成边界内的总时间；P50/P95/P99 来自合并帧间隔样本。", "",
        "| 模式 | 完成吞吐 FPS | P50 / P95 / P99 ms | 每帧应用层字节 | 宿主 Metal GPU 均值 ms |",
        "|---|---:|---:|---:|---:|"]
    labels = {"direct-present":"Direct Present", "pixel-readback":"Pixel Readback TCP", "command-only":"Command-Only Metal Replay"}
    for mode, label in labels.items():
        entry = performance["comparison"][mode]
        timing = entry["frame_interval_ms"]
        gpu = entry["host_gpu_ms_mean"]
        lines.append(f"| {label} | {entry['fps_including_gpu_drain_pooled']:.3f} | {timing['p50']:.3f} / {timing['p95']:.3f} / {timing['p99']:.3f} | {entry['mean_total_bytes']:.3f} | {gpu:.6f} |" if gpu is not None else f"| {label} | {entry['fps_including_gpu_drain_pooled']:.3f} | {timing['p50']:.3f} / {timing['p95']:.3f} / {timing['p99']:.3f} | {entry['mean_total_bytes']:.3f} | — |")
    lines += ["", "GPU command completion 和实际屏幕显示分开。Metal 时间包含场景绘制及单独的展示绘制；没有测量输入到光子的延迟。历史 11.35 / 6.19 FPS 属于旧提交统计口径，仅保留为历史记录。", "",
        "command-only 的正常帧不执行 Guest 场景 Draw、CopyResource、像素 Map(READ) 或像素传输；宿主实际执行每帧 16 次场景 Draw。缓存帧 88 字节，资源和描述符刷新帧 66,136 字节，另有每连接 32 字节 hello。", "",
        "完整源码、二进制、CSV、JSONL、参考帧和捕获帧摘要见三个子目录的 manifest 与本目录的 acceptance.json。范围为自有固定场景，不代表通用 D3D/WDDM 栈已经完成。"]
    (output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    manifest = {"owner":"@DNPMBHC", "complete":True, "performance_measurement":True,
        "guest_preflight":preflight, "guest_fingerprint":adapter, "comparison":performance["comparison"],
        "guest_display_controllers":controller_names, "guest_enumerated_adapters":metadata["enumerated_adapters"],
        "explicit_warp_fingerprint":reference_adapter,
        "pixels_passed":True, "source_digests":source_digests(),
        "artifacts":{name:sha256_file(output / name) for name in (
            "m0-adapters/manifest.json", "pixel-validation/manifest.json", "three-mode-benchmark/manifest.json",
            "acceptance-inputs.json", "report.md")}}
    write_json(output / "acceptance.json", manifest)
    return manifest

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    while True:
        try:
            handoff = require_handoff()
            break
        except (ValueError, OSError) as error:
            write_json(EVIDENCE_DIR / "guest-acceptance-blocked.json", {"guest_operations":False,
                "reason":redact_text(str(error)),"captured_at_utc":datetime.now(timezone.utc).isoformat()})
            if not args.wait:
                print(json.dumps({"ready":False,"reason":redact_text(str(error))}), flush=True)
                return 2
            time.sleep(5)
    if args.check_only:
        print(json.dumps({"handoff_valid":True,"guest_operations":False}), flush=True)
        return 0
    output = writable_path(EVIDENCE_DIR / "m0-m2-guest-final" / datetime.now(timezone.utc).strftime("run-%Y%m%d-%H%M%S-utc"))
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "handoff-input.json", {**handoff,"source_sha256":sha256_file(A_HANDOFF)})
    status_path = EVIDENCE_DIR / "m0-m2-status.json"
    status = json.loads(status_path.read_text()) if status_path.is_file() else {"owner":"@DNPMBHC"}
    status.update({"phase":"guest_preflight","current_guest_owner":"C","guest_operations":"preflight_only",
        "guest_benchmarks_started":False,"complete":False})
    write_json(status_path, status)
    try:
        frozen_inputs = freeze_inputs(output)
        from guest_preflight import collect_preflight
        utmctl = discover_utmctl()
        guest = GuestSession(utmctl, discover_started_vm(utmctl))
        preflight = collect_preflight(guest, output / "preflight-before")
        for name, argv in (
            ("m0", ["run_m0_fingerprints.py", "--guest-only", "--output-dir", str(output / "m0-adapters")]),
            ("pixels", ["run_guest_pixel_validation.py", "--output-dir", str(output / "pixel-validation")]),
            ("performance", ["run_guest_m2_benchmark.py", "--output-dir", str(output / "three-mode-benchmark")])):
            require_handoff()
            verify_inputs(frozen_inputs)
            collect_preflight(guest, output / (name + "-preflight"))
            status.update({"phase":"guest_" + name,"guest_operations":"exclusive_C_acceptance",
                "guest_benchmarks_started":name == "performance" or status["guest_benchmarks_started"]})
            write_json(status_path,status)
            run_stage(name, argv, output)
            verify_inputs(frozen_inputs)
        stop_metal_host()
        after = collect_preflight(guest, output / "preflight-after")
        verify_inputs(frozen_inputs)
        manifest = report(output, preflight)
        write_json(C_HANDOFF, {"owner":"@DNPMBHC", "released":True, "next_owner":"B",
            "guest_jobs_clean":True,"host_receiver_stopped":True,"security_baseline_matches":True,
            "captured_at_utc":datetime.now(timezone.utc).isoformat(),
            "acceptance":str((output / "acceptance.json").relative_to(EVIDENCE_DIR)),
            "acceptance_sha256":sha256_file(output / "acceptance.json"),"postflight":after})
        write_json(EVIDENCE_DIR / "m0-m2-guest-final" / "latest.json", {"complete":True,
            "directory":output.relative_to(EVIDENCE_DIR).as_posix(),"comparison":manifest["comparison"]})
        status.update({"phase":"complete","complete":True,"current_guest_owner":"B",
            "guest_operations":"fully_stopped_and_released","remaining":[],
            "acceptance_record":str((output / "acceptance.json").relative_to(EVIDENCE_DIR))})
        write_json(status_path,status)
        print(json.dumps({"complete":True,"released_to":"B","comparison":manifest["comparison"]}), flush=True)
        return 0
    except Exception as error:
        write_json(output / "failure.json", {"complete":False,"error":redact_text(str(error))})
        status.update({"phase":"guest_acceptance_needs_followup","complete":False,
            "failure_record":str((output / "failure.json").relative_to(EVIDENCE_DIR))})
        write_json(status_path,status)
        print(json.dumps({"complete":False,"error":redact_text(str(error))}), flush=True)
        return 1

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print(json.dumps({"complete":False,"interrupted":True,"released":False}), flush=True)
        raise SystemExit(130)
