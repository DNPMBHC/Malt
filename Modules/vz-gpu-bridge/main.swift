// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

struct CLIOptions {
    var regionBytes: UInt64 = 256 * 1024 * 1024
    var fixtureDisk = ""
    var mode = "validate"
    var width = 1280
    var height = 720
    var drawCalls = 2048
    var frames = 300
    var warmupFrames = 60
    var socketPath = "/tmp/demo-app-gpu-ipc.sock"
}

private func assignArgument(_ key: String, value: String, options: inout CLIOptions) throws {
    switch key {
    case "--mode": options.mode = value
    case "--width": options.width = Int(value) ?? -1
    case "--height": options.height = Int(value) ?? -1
    case "--draws": options.drawCalls = Int(value) ?? -1
    case "--frames": options.frames = Int(value) ?? -1
    case "--warmup": options.warmupFrames = Int(value) ?? -1
    case "--socket": options.socketPath = value
    default: try assignFixtureArgument(key, value: value, options: &options)
    }
}

private func assignFixtureArgument(_ key: String, value: String, options: inout CLIOptions) throws {
    switch key {
    case "--region-bytes":
        guard let bytes = UInt64(value), bytes > 0 else { throw NSError(domain: "CLI", code: 6) }
        options.regionBytes = bytes
    case "--fixture-disk": options.fixtureDisk = value
    default: throw NSError(domain: "CLI", code: 2)
    }
}

private func parseArgs(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 1
    while index < arguments.count {
        guard index + 1 < arguments.count else { throw NSError(domain: "CLI", code: 1) }
        let value = arguments[index + 1]
        try assignArgument(arguments[index], value: value, options: &options)
        index += 2
    }
    guard (1...8192).contains(options.width), (1...8192).contains(options.height),
          (1...65536).contains(options.drawCalls), (1...10000).contains(options.frames),
          (0...10000).contains(options.warmupFrames), options.socketPath.utf8.count < 104 else {
        throw NSError(domain: "CLI", code: 3)
    }
    return options
}

func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let text = String(data: data, encoding: .utf8) { print(text) }
}

private func runVZDiagnostic(_ options: CLIOptions) throws -> Bool {
    switch options.mode {
    case "live-capacity-case": try printJSON(VZRuntimeProbe.runCapacityCase(bytes: options.regionBytes))
    case "shared-memory-capacity-case": try printJSON(VZMemoryCapacityProbe.run(bytes: options.regionBytes))
    case "efi-guest-probe":
        guard !options.fixtureDisk.isEmpty else { throw NSError(domain: "CLI", code: 5) }
        try printJSON(EFIGuestProbe.run(disk: URL(fileURLWithPath: options.fixtureDisk),
                                      width: options.width, height: options.height,
                                      sharedMemoryBytes: options.regionBytes))
    case "validate": try printJSON(VZValidationProbe.runFullProbe())
    case "secure-boot-probe": try printJSON(SecureBootProbe.run())
    case "runtime-case": try printJSON(VZRuntimeProbe.run(caseIndex: options.frames - 1))
    case "runtime-probe": try printJSON(VZRuntimeProbe.run())
    default: return false
    }
    return true
}

private func runDiagnostic(_ options: CLIOptions) throws -> Bool {
    switch options.mode {
    case "serve": try HostExperimentServer.run()
    case "producer-probe": try printJSON(SurfaceProducerProbe.run())
    case "virgl-probe": try printJSON(VirglFFIProbe.runProbe())
    case "present-smoke":
        let report = try NativePresentationProbe.run(width: options.width, height: options.height,
                                                     draws: options.drawCalls)
        try printJSON(report)
    case "protocol-self-test":
        let checks = VirtioGPUCommandProcessor.selfTest()
        try printJSON(checks)
        if checks.values.contains(false) { exit(1) }
    default: return try runVZDiagnostic(options)
    }
    return true
}

private func runBenchmark(_ options: CLIOptions) throws {
    var config = IPCBenchConfig(socketPath: options.socketPath, width: options.width, height: options.height,
                                drawCalls: options.drawCalls, frames: options.frames,
                                warmupFrames: options.warmupFrames)
    config.copyFrames = !options.mode.contains("control")
    switch options.mode {
    case "bench-zerocopy":
        let renderer = try InProcessZeroCopyRenderer(width: options.width, height: options.height,
                                                   maxDraws: options.drawCalls)
        try printJSON(renderer.runZeroCopyBenchmark(drawCalls: options.drawCalls, frames: options.frames,
                                                    warmupFrames: options.warmupFrames))
    case "bench-ipc-worker", "bench-ipc-control-worker":
        try printJSON(MultiProcessIPCBaseline.runWorker(config: config))
    case "bench-ipc-client", "bench-ipc-control-client":
        try printJSON(MultiProcessIPCBaseline.runClient(config: config))
    default: throw NSError(domain: "CLI", code: 4)
    }
}

do {
    let options = try parseArgs(CommandLine.arguments)
    if try !runDiagnostic(options) { try runBenchmark(options) }
} catch {
    let native = error as NSError
    fputs("error: \(native.domain):\(native.code)\n", stderr)
    exit(1)
}
