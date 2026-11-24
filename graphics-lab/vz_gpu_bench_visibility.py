#!/usr/bin/env python3
"""Observe only the owned experiment window through public WindowServer metadata. Owner: @DNPMBHC."""
from __future__ import annotations
import json
import vz_gpu_bench_runner as runner
from vz_gpu_bench_support import redact, save_json, sha256_file

SOURCE = r'''// Owner: @DNPMBHC
import CoreGraphics
import Foundation

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
child.arguments = ["--mode", "present-smoke", "--width", "1280", "--height", "720"]
let output = Pipe()
let errors = Pipe()
child.standardOutput = output
child.standardError = errors
try child.run()
var observed = false
var observations = 0
let deadline = Date(timeIntervalSinceNow: 10)
while child.isRunning, Date() < deadline {
    if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] {
        for window in windows {
            if let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
               owner.int32Value == child.processIdentifier,
               (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true {
                observed = true
                observations += 1
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.001)
}
if child.isRunning { child.terminate() }
child.waitUntilExit()
let bytes = output.fileHandleForReading.readDataToEndOfFile()
let report = try JSONSerialization.jsonObject(with: bytes)
let result: [String: Any] = ["owner": "@DNPMBHC", "owned_window_observed_onscreen": observed,
                           "positive_observations": observations, "child_exit": child.terminationStatus,
                           "presentation_report": report, "captured_pixel_screenshot": false,
                           "other_window_metadata_recorded": false]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


def run_probe() -> dict:
    directory = runner.BUILD / "visibility-probe"
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "main.swift"
    source.write_text(SOURCE)
    executable = directory / "demo-app-window-observer"
    build = runner.capture(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-module-cache-path",
                            str(directory / "module-cache"), str(source), "-o", str(executable)])
    if build.returncode:
        raise RuntimeError("Window observer compilation failed: " + redact(build.stderr, runner.ROOT))
    result = runner.capture([str(executable), str(runner.BINARY)], timeout=30)
    if result.returncode:
        raise RuntimeError("Window observer failed: " + redact(result.stderr, runner.ROOT))
    report = json.loads(result.stdout)
    report["experiment_binary_sha256"] = sha256_file(runner.BINARY)
    report["observer_binary_sha256"] = sha256_file(executable)
    save_json(runner.EVIDENCE / "onscreen-visibility.json", report)
    return report


if __name__ == "__main__":
    try:
        print(json.dumps(run_probe()))
    except (RuntimeError, OSError, ValueError) as error:
        print(redact(str(error), runner.ROOT))
        raise SystemExit(1) from None
