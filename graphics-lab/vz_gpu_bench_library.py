#!/usr/bin/env python3
"""Build an in-process producer library and exercise its public entry point. Owner: @DNPMBHC."""
from __future__ import annotations
import json
import shutil
from pathlib import Path
import vz_gpu_bench_runner as runner
from vz_gpu_bench_support import redact, save_json, sha256_file

SOURCES = ("SurfaceFrameProducer.swift", "SurfaceFrameLease.swift", "InProcessZeroCopyRenderer.swift",
           "IOSurfacePresentBridge.swift", "SharedCommandRing.swift", "GPUShader.swift",
           "Metal4Engine.swift", "BenchmarkStatistics.swift", "EFIGuestProbe.swift",
           "EFIGuestSurfaceLease.swift", "VZVirtioGPUDevice.swift", "VirtioGPUProtocol.swift",
           "VirtioGPUCommandProcessor.swift")
LIBRARY_DIR = runner.BUILD / "consumer-library"

SMOKE_SOURCE = r'''import Foundation
import IOSurface
import ModuleX

final class FrameResult: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: [String: Bool] = [:]
    func accept(_ frame: SurfaceFrameLease) {
        lock.lock()
        if checks.isEmpty {
            checks = ["public_entry_called": true,
                      "synthetic_origin": frame.metadata.origin == "host_synthetic_not_guest_scanout",
                      "actual_surface": IOSurfaceGetWidth(frame.surface) == frame.metadata.width,
                      "ready_timeline_completed": frame.readyEvent.signaledValue >= frame.metadata.readyValue,
                      "release_idempotent": frame.release() && !frame.release()]
        } else { frame.release() }
        lock.unlock()
    }
    var result: [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }
}

let producer = try SurfaceFrameProducer(width: 64, height: 64, draws: 64)
let result = FrameResult()
let ready = DispatchSemaphore(value: 0)
producer.start { frame in
    result.accept(frame)
    ready.signal()
}
guard ready.wait(timeout: .now() + 12) == .success else { exit(1) }
let stopped = DispatchSemaphore(value: 0)
producer.stop { stopped.signal() }
guard stopped.wait(timeout: .now() + 12) == .success, result.result.values.allSatisfy({ $0 }) else { exit(1) }
let bytes = try JSONEncoder().encode(result.result)
print(String(decoding: bytes, as: UTF8.self))
'''


def build_and_smoke() -> dict:
    LIBRARY_DIR.mkdir(parents=True, exist_ok=True)
    snapshot = LIBRARY_DIR / "sources"
    snapshot.mkdir(exist_ok=True)
    digests = {}
    for name in SOURCES:
        shutil.copy2(runner.MODULE / name, snapshot / name)
        digests[name] = sha256_file(snapshot / name)
    library = LIBRARY_DIR / "libModuleX.a"
    command = ["xcrun", "swiftc", "-O", "-warnings-as-errors", "-module-cache-path",
               str(LIBRARY_DIR / "module-cache"), "-parse-as-library", "-emit-library", "-static",
               "-emit-module", "-module-name", "ModuleX", "-emit-module-path",
               str(LIBRARY_DIR / "ModuleX.swiftmodule")]
    command += [str(snapshot / name) for name in SOURCES] + ["-o", str(library)]
    result = runner.capture(command)
    if result.returncode:
        raise RuntimeError("Producer library compilation failed: " + redact(result.stderr, runner.ROOT))
    smoke = LIBRARY_DIR / "main.swift"
    smoke.write_text(SMOKE_SOURCE)
    executable = LIBRARY_DIR / "demo-app-consumer"
    result = runner.capture(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-I", str(LIBRARY_DIR),
                             "-L", str(LIBRARY_DIR), "-lModuleX", str(smoke), "-o", str(executable)])
    if result.returncode:
        raise RuntimeError("Public consumer compilation failed: " + redact(result.stderr, runner.ROOT))
    result = runner.capture(["codesign", "--force", "--sign", "-", "--options", "runtime",
                             "--entitlements", str(runner.MODULE / "vz_bridge.entitlements"), str(executable)])
    if result.returncode:
        raise RuntimeError("Public consumer signing failed")
    result = runner.capture([str(executable)], timeout=30)
    if result.returncode:
        raise RuntimeError("Public consumer failed: " + redact(result.stderr, runner.ROOT))
    if any(sha256_file(runner.MODULE / name) != digest for name, digest in digests.items()):
        raise RuntimeError("Producer library source changed during public consumer verification")
    report = {"owner": "@DNPMBHC", "module_name": "ModuleX", "linkage": "static_in_same_process",
              "hardened_runtime": True, "virtualization_entitlement": True,
              "sources": digests, "library_sha256": sha256_file(library),
              "consumer_sha256": sha256_file(executable), "checks": json.loads(result.stdout),
              "efi_diagnostic_entry_exported": True,
              "supports_real_guest_scanout": False, "supports_virtual_hid_sink": False}
    save_json(runner.EVIDENCE / "producer-library-binding.json", report)
    return report


if __name__ == "__main__":
    try:
        print(json.dumps(build_and_smoke()))
    except (RuntimeError, OSError, ValueError) as error:
        print(redact(str(error), runner.ROOT))
        raise SystemExit(1) from None
