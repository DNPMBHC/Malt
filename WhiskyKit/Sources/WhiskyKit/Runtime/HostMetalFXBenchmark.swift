// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import MetalFX

enum HostMetalFXRoute: String, Codable, CaseIterable {
    case native, nearest, spatial, temporal, cpuReference
}

struct HostMetalFXBenchmarkConfiguration: Codable {
    var outputSize = 512
    var warmupFrames = 8
    var sampleRounds = 12
    var framesPerSample = 4

    var inputSize: Int { outputSize / 2 }

    func validate() throws {
        guard outputSize >= 16, outputSize <= 4096, outputSize.isMultiple(of: 2),
              warmupFrames > 0, sampleRounds > 1, framesPerSample > 0 else {
            throw HostMetalFXBenchmarkError.invalidConfiguration
        }
    }
}

struct HostMetalFXFrameSample: Codable {
    let round: Int
    let position: Int
    let frame: Int
    let executedRoute: HostMetalFXRoute
    let cpuEncodeAndCommitMilliseconds: Double
    let gpuMilliseconds: Double?
}

struct HostMetalFXPathReport: Codable {
    let requestedRoute: HostMetalFXRoute
    let executedRoute: HostMetalFXRoute
    let capabilitySupported: Bool?
    let scalerCreationSucceeded: Bool?
    let gpuEncodingCompleted: Bool
    let requestedGPUEncodingCompleted: Bool
    let fallbackReason: String?
    let shadedPixelsPerFrame: Int
    let outputChecksum: String
    let opaqueOutput: Bool
    let nonzeroColorOutput: Bool
    let meanAbsoluteErrorAgainstNative: Double?
    let meanAbsoluteErrorAgainstCPUReference: Double?
}

struct HostMetalFXComparisonReport: Codable {
    let reference: HostMetalFXRoute
    let candidate: HostMetalFXRoute
    let referenceSamples: [HostMetalFXFrameSample]
    let candidateSamples: [HostMetalFXFrameSample]
    let referenceMedianGPUMilliseconds: Double?
    let candidateMedianGPUMilliseconds: Double?
    let referenceMedianCPUMilliseconds: Double
    let candidateMedianCPUMilliseconds: Double
}

struct HostMetalFXBenchmarkReport: Codable {
    let schemaVersion: Int
    let scene: String
    let configuration: HostMetalFXBenchmarkConfiguration
    let metalDeviceAvailable: Bool
    let metalAPIValidationEnabled: Bool
    let paths: [HostMetalFXPathReport]
    let comparisons: [HostMetalFXComparisonReport]
    let limitations: [String]

    func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}

enum HostMetalFXBenchmarkError: Error {
    case invalidConfiguration, allocationFailed, encoderUnavailable, commandFailed, shaderUnavailable
}

struct HostMetalFXFactories {
    var supportsSpatial: (any MTLDevice) -> Bool = { MTLFXSpatialScalerDescriptor.supportsDevice($0) }
    var supportsTemporal: (any MTLDevice) -> Bool = { MTLFXTemporalScalerDescriptor.supportsDevice($0) }
    var makeSpatial: (MTLFXSpatialScalerDescriptor, any MTLDevice) -> (any MTLFXSpatialScaler)? = {
        $0.makeSpatialScaler(device: $1)
    }
    var makeTemporal: (MTLFXTemporalScalerDescriptor, any MTLDevice) -> (any MTLFXTemporalScaler)? = {
        $0.makeTemporalScaler(device: $1)
    }
}

/// Internal experiment runner; it does not alter the shared host snapshot or any renderer policy.
struct HostMetalFXBenchmark {
    var deviceProvider: () -> (any MTLDevice)? = { MTLCreateSystemDefaultDevice() }
    var factories = HostMetalFXFactories()

    func run(
        configuration: HostMetalFXBenchmarkConfiguration = .init()
    ) throws -> HostMetalFXBenchmarkReport {
        try configuration.validate()
        guard let device = deviceProvider() else {
            return cpuFallback(configuration, reason: "metal_device_unavailable", hasDevice: false)
        }
        do {
            let context = try HostMetalFXGPUContext(device: device)
            return try runGPU(configuration, context: context)
        } catch {
            return cpuFallback(configuration, reason: "gpu_setup_or_command_failed", hasDevice: true)
        }
    }

    private func runGPU(
        _ configuration: HostMetalFXBenchmarkConfiguration, context: HostMetalFXGPUContext
    ) throws -> HostMetalFXBenchmarkReport {
        let routes: [HostMetalFXRoute] = [.native, .nearest, .spatial, .temporal]
        let paths = try routes.map {
            try HostMetalFXGPUPath(route: $0, configuration: configuration, context: context, factories: factories)
        }
        for path in paths {
            for _ in 0..<configuration.warmupFrames { _ = try path.frame() }
        }
        let pairs = [(0, 1), (1, 2), (1, 3)]
        let comparisons = try pairs.map { reference, candidate in
            try compare(paths[reference], paths[candidate], configuration: configuration)
        }
        let nativePixels = try paths[0].readPixels()
        let cpuReference = Self.syntheticScenePixels(size: configuration.outputSize)
        let results = try paths.map { path in
            path.report(pixels: try path.readPixels(), reference: nativePixels, cpuReference: cpuReference)
        }
        return makeReport(configuration, hasDevice: true, paths: results, comparisons: comparisons)
    }

    private func compare(
        _ reference: HostMetalFXGPUPath, _ candidate: HostMetalFXGPUPath,
        configuration: HostMetalFXBenchmarkConfiguration
    ) throws -> HostMetalFXComparisonReport {
        var referenceSamples: [HostMetalFXFrameSample] = []
        var candidateSamples: [HostMetalFXFrameSample] = []
        for round in 0..<configuration.sampleRounds {
            for position in 0..<2 {
                let isReference = (round + position).isMultiple(of: 2)
                let path = isReference ? reference : candidate
                for frame in 0..<configuration.framesPerSample {
                    let timing = try path.frame()
                    let sample = HostMetalFXFrameSample(
                        round: round, position: position, frame: frame, executedRoute: path.executedRoute,
                        cpuEncodeAndCommitMilliseconds: timing.cpu, gpuMilliseconds: timing.gpu
                    )
                    if isReference { referenceSamples.append(sample) } else { candidateSamples.append(sample) }
                }
            }
        }
        return HostMetalFXComparisonReport(
            reference: reference.requestedRoute, candidate: candidate.requestedRoute,
            referenceSamples: referenceSamples, candidateSamples: candidateSamples,
            referenceMedianGPUMilliseconds: Self.median(referenceSamples.compactMap(\.gpuMilliseconds)),
            candidateMedianGPUMilliseconds: Self.median(candidateSamples.compactMap(\.gpuMilliseconds)),
            referenceMedianCPUMilliseconds: Self.median(
                referenceSamples.map(\.cpuEncodeAndCommitMilliseconds)
            ) ?? 0,
            candidateMedianCPUMilliseconds: Self.median(
                candidateSamples.map(\.cpuEncodeAndCommitMilliseconds)
            ) ?? 0
        )
    }

    private func cpuFallback(
        _ configuration: HostMetalFXBenchmarkConfiguration, reason: String, hasDevice: Bool
    ) -> HostMetalFXBenchmarkReport {
        let size = configuration.outputSize
        let checksum = Self.checksum(Self.syntheticScenePixels(size: size))
        let reports: [HostMetalFXPathReport] = [.native, .nearest, .spatial, .temporal].map { route in
            HostMetalFXPathReport(
                requestedRoute: route, executedRoute: .cpuReference, capabilitySupported: nil,
                scalerCreationSucceeded: nil, gpuEncodingCompleted: false, requestedGPUEncodingCompleted: false,
                fallbackReason: reason,
                shadedPixelsPerFrame: size * size, outputChecksum: checksum, opaqueOutput: true,
                nonzeroColorOutput: true, meanAbsoluteErrorAgainstNative: nil,
                meanAbsoluteErrorAgainstCPUReference: 0
            )
        }
        return makeReport(configuration, hasDevice: hasDevice, paths: reports, comparisons: [])
    }

    private func makeReport(
        _ configuration: HostMetalFXBenchmarkConfiguration, hasDevice: Bool,
        paths: [HostMetalFXPathReport], comparisons: [HostMetalFXComparisonReport]
    ) -> HostMetalFXBenchmarkReport {
        HostMetalFXBenchmarkReport(
            schemaVersion: 1, scene: "synthetic_static_plane_v1", configuration: configuration,
            metalDeviceAvailable: hasDevice,
            metalAPIValidationEnabled: ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] == "1",
            paths: paths, comparisons: comparisons, limitations: [
                "GPU interval covers synthetic scene shading and the selected reconstruction; "
                    + "readback is outside timing.",
                "CPU interval covers command allocation, encoding, and commit; GPU waiting is excluded.",
                "Native shades four times as many pixels as every low-resolution route. These timings "
                    + "do not prove game speedup.",
                "Temporal uses a static plane, depth=0.5, zero non-jitter motion, matched Halton "
                    + "jitter, and persistent history.",
                "Temporal output error includes jitter phase and filter history; no moving geometry "
                    + "or disocclusion is exercised.",
                "Nearest is a compute resample because Metal blit does not resize textures.",
                "No process names, local paths, device names, registry IDs, or personal identifiers are collected.",
                "API validation changes timing overhead; use a separate validation-disabled run for "
                    + "performance conclusions.",
                "Game Mode activation, guest rendering, presentation, frame pacing, and thermal "
                    + "steady state are outside this experiment."
            ]
        )
    }

    static func syntheticScenePixels(size: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let offset = (row * size + column) * 4
                let horizontal = (Float(column) + 0.5) / Float(size)
                let vertical = (Float(row) + 0.5) / Float(size)
                var phase = horizontal * 3 + vertical * 7
                for index in 0..<24 { phase = sin(phase + Float(index) * 0.03125) }
                let grid = Float((Int(floor(horizontal * 8)) + Int(floor(vertical * 8))) & 1)
                let values = [horizontal, vertical, 0.25 + 0.5 * horizontal * vertical]
                for (channel, value) in values.enumerated() {
                    let color = min(1, max(0, (value + 0.025 * phase) * 0.8 + 0.1 * grid))
                    pixels[offset + channel] = UInt8((color * 255).rounded())
                }
            }
        }
        return pixels
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let values = values.sorted()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    static func checksum(_ bytes: [UInt8]) -> String {
        let value = bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(value, radix: 16)
    }
}
