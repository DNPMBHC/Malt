// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Metal
import MetalFX
import XCTest
@testable import WhiskyKit

final class HostMetalFXBenchmarkTests: XCTestCase {
    func testNoDeviceProducesDeterministicCPUFallbackAndSerializableReport() throws {
        let benchmark = HostMetalFXBenchmark(deviceProvider: { nil })
        let configuration = smallConfiguration()
        let first = try benchmark.run(configuration: configuration)
        let second = try benchmark.run(configuration: configuration)
        XCTAssertFalse(first.metalDeviceAvailable)
        XCTAssertTrue(first.comparisons.isEmpty)
        XCTAssertEqual(first.paths.count, 4)
        for (path, repeated) in zip(first.paths, second.paths) {
            XCTAssertEqual(path.executedRoute, .cpuReference)
            XCTAssertNil(path.capabilitySupported)
            XCTAssertNil(path.scalerCreationSucceeded)
            XCTAssertFalse(path.gpuEncodingCompleted)
            XCTAssertFalse(path.requestedGPUEncodingCompleted)
            XCTAssertEqual(path.fallbackReason, "metal_device_unavailable")
            XCTAssertTrue(path.opaqueOutput)
            XCTAssertTrue(path.nonzeroColorOutput)
            XCTAssertEqual(path.outputChecksum, repeated.outputChecksum)
        }
        let bytes = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(HostMetalFXBenchmarkReport.self, from: bytes)
        XCTAssertEqual(decoded.paths.map(\.outputChecksum), first.paths.map(\.outputChecksum))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        XCTAssertFalse(text.contains("file://"))
    }

    func testUnsupportedAndCreationFailureExecuteActualNearestFallback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device is available.") }
        var factories = HostMetalFXFactories()
        factories.supportsSpatial = { _ in false }
        factories.supportsTemporal = { _ in true }
        factories.makeTemporal = { _, _ in nil }
        let benchmark = HostMetalFXBenchmark(deviceProvider: { device }, factories: factories)
        let report = try benchmark.run(configuration: smallConfiguration())
        let spatial = try XCTUnwrap(report.paths.first { $0.requestedRoute == .spatial })
        let temporal = try XCTUnwrap(report.paths.first { $0.requestedRoute == .temporal })
        XCTAssertEqual(spatial.capabilitySupported, false)
        XCTAssertNil(spatial.scalerCreationSucceeded)
        XCTAssertEqual(spatial.fallbackReason, "device_unsupported")
        XCTAssertEqual(temporal.capabilitySupported, true)
        XCTAssertEqual(temporal.scalerCreationSucceeded, false)
        XCTAssertEqual(temporal.fallbackReason, "scaler_creation_failed")
        for path in [spatial, temporal] {
            XCTAssertEqual(path.executedRoute, .nearest)
            XCTAssertFalse(path.requestedGPUEncodingCompleted)
            XCTAssertTrue(path.gpuEncodingCompleted)
            XCTAssertTrue(path.opaqueOutput)
            XCTAssertTrue(path.nonzeroColorOutput)
        }
        let nearest = try XCTUnwrap(report.paths.first { $0.requestedRoute == .nearest })
        XCTAssertEqual(spatial.outputChecksum, nearest.outputChecksum)
        XCTAssertEqual(temporal.outputChecksum, nearest.outputChecksum)
        assertAlternatingSamples(report, configuration: smallConfiguration())
    }

    func testInvalidConfigurationFailsBeforeCreatingDevice() {
        var configuration = smallConfiguration()
        configuration.outputSize = 0
        let benchmark = HostMetalFXBenchmark(deviceProvider: {
            XCTFail("An invalid experiment must not initialize the GPU.")
            return nil
        })
        XCTAssertThrowsError(try benchmark.run(configuration: configuration))
    }

    func testReproducibleMetalFXABWritesSanitizedJSON() throws {
        guard ProcessInfo.processInfo.environment["HOST_RUN_METALFX_AB"] == "1" else {
            throw XCTSkip("Set HOST_RUN_METALFX_AB=1 to run and persist the GPU A/B experiment.")
        }
        let configuration = HostMetalFXBenchmarkConfiguration()
        let report = try HostMetalFXBenchmark().run(configuration: configuration)
        try report.writeJSON(to: reportURL())
        print("HOST_METALFX_AB_REPORT_WRITTEN=1")
        guard report.metalDeviceAvailable else {
            throw XCTSkip("The persisted report records CPU fallback because no Metal device is available.")
        }
        for path in report.paths {
            XCTAssertTrue(path.gpuEncodingCompleted,
                          "Expected the selected GPU route or its nearest fallback to finish.")
            XCTAssertTrue(path.nonzeroColorOutput)
            XCTAssertTrue(path.opaqueOutput)
            XCTAssertLessThan(try XCTUnwrap(path.meanAbsoluteErrorAgainstNative), 0.2)
            if path.scalerCreationSucceeded == true {
                XCTAssertEqual(path.executedRoute, path.requestedRoute)
                XCTAssertNil(path.fallbackReason)
            }
        }
        let native = try XCTUnwrap(report.paths.first { $0.requestedRoute == .native })
        XCTAssertLessThan(try XCTUnwrap(native.meanAbsoluteErrorAgainstCPUReference), 0.002)
        assertAlternatingSamples(report, configuration: configuration)
    }

    private func smallConfiguration() -> HostMetalFXBenchmarkConfiguration {
        HostMetalFXBenchmarkConfiguration(outputSize: 32, warmupFrames: 2, sampleRounds: 2, framesPerSample: 1)
    }

    private func assertAlternatingSamples(
        _ report: HostMetalFXBenchmarkReport, configuration: HostMetalFXBenchmarkConfiguration,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(report.comparisons.count, 3, file: file, line: line)
        for pair in report.comparisons {
            XCTAssertEqual(pair.referenceSamples.count, configuration.sampleRounds * configuration.framesPerSample,
                           file: file, line: line)
            XCTAssertEqual(pair.candidateSamples.count, pair.referenceSamples.count, file: file, line: line)
            for sample in pair.referenceSamples {
                XCTAssertEqual(sample.position, sample.round % 2, file: file, line: line)
                XCTAssertEqual(sample.executedRoute, pair.reference, file: file, line: line)
                XCTAssertGreaterThan(sample.cpuEncodeAndCommitMilliseconds, 0, file: file, line: line)
            }
            for sample in pair.candidateSamples {
                XCTAssertEqual(sample.position, 1 - sample.round % 2, file: file, line: line)
                XCTAssertGreaterThan(sample.cpuEncodeAndCommitMilliseconds, 0, file: file, line: line)
            }
        }
    }

    private func reportURL() -> URL {
        if let output = ProcessInfo.processInfo.environment["HOST_METALFX_AB_REPORT"] {
            return URL(fileURLWithPath: output)
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory.appendingPathComponent("Documentation/host-metalfx-ab.json")
            }
            directory.deleteLastPathComponent()
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("host-metalfx-ab.json")
    }
}
