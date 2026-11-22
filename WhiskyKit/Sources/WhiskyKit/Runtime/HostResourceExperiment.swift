// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation

struct HostResourceExperimentSample: Codable, Sendable {
    let operation: Int
    let waitMilliseconds: Double
    let workMilliseconds: Double
    let observedQoS: UInt32
    let checksum: UInt8
}

struct HostResourceExperimentRound: Codable, Sendable {
    let round: Int
    let treatment: String
    let configuredConcurrency: Int
    let peakConcurrency: Int
    let wallMilliseconds: Double
    let samples: [HostResourceExperimentSample]
}

struct HostResourcePauseObservation: Codable, Sendable {
    let trigger: String
    let observationMilliseconds: Double
    let completedWhilePaused: Int
    let completedAfterRecovery: Int
    let baselineRestored: Bool
}

struct HostResourceExperimentReport: Codable, Sendable {
    let schemaVersion: Int
    let scenario: String
    let stateSource: String
    let consumer: String
    let recordedAtUTC: String
    let baseline: String
    let jobsPerRound: Int
    let bytesPerHash: Int
    let hashesPerJob: Int
    let expectedChecksum: UInt8
    let warmupRounds: Int
    let rounds: [HostResourceExperimentRound]
    let pauseObservations: [HostResourcePauseObservation]
    let limitations: [String]
}

/// A real optional diagnostic consumer. Its measurements describe this workload only.
enum HostResourceExperiment {
    private static let jobs = 16
    private static let iterations = 128
    private static let payload = Data(repeating: 90, count: 16 * 1_024)

    static func run() -> HostResourceExperimentReport {
        let digest = SHA256.hash(data: payload)
        let expected = UInt8(truncatingIfNeeded: Int(digest.withUnsafeBytes { $0[0] }) * iterations)
        _ = measure(round: -1, treatment: "control")
        _ = measure(round: -1, treatment: "nominal")
        _ = measure(round: -1, treatment: "serious")
        var results: [HostResourceExperimentRound] = []
        for round in 0..<4 {
            // Rotate order and reverse alternating rounds to avoid a fixed first/last treatment.
            let orders = [["control", "nominal", "serious"], ["serious", "nominal", "control"],
                          ["nominal", "control", "serious"], ["serious", "control", "nominal"]]
            for treatment in orders[round] {
                results.append(measure(round: round, treatment: treatment))
            }
        }
        return HostResourceExperimentReport(
            schemaVersion: 1, scenario: "fixed-sha256-optional-diagnostics", stateSource: "injected",
            consumer: "SHA256 diagnostic operations on a dedicated OperationQueue",
            recordedAtUTC: ISO8601DateFormatter().string(from: Date()),
            baseline: "utility QoS, concurrency 4, unsuspended",
            jobsPerRound: jobs,
            bytesPerHash: payload.count, hashesPerJob: iterations, expectedChecksum: expected, warmupRounds: 3,
            rounds: results,
            pauseObservations: [pauseAndRecover(trigger: "low-power"), pauseAndRecover(trigger: "critical-thermal")],
            limitations: [
                "Thermal and power states are injected; no hardware transition is claimed.",
                "This is a scheduling experiment, not evidence of game FPS, energy, or temperature improvements.",
                "Observed thread QoS is recorded; the OS can adjust scheduling and running work is not preempted.",
                "No Wine, guest, renderer, UI, or production launch consumer is connected by this task."
            ]
        )
    }

    private static func measure(round: Int, treatment: String) -> HostResourceExperimentRound {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        let controller = HostResourceController(optionalWorkQueue: queue)
        if treatment != "control" {
            controller.apply(snapshot: snapshot(thermal: treatment == "serious" ? .serious : .nominal))
        }
        defer { controller.stopMonitoringAndRestore() }
        let recording = HostWorkRecording()
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<jobs {
            let submitted = DispatchTime.now().uptimeNanoseconds
            queue.addOperation {
                let began = DispatchTime.now().uptimeNanoseconds
                recording.begin()
                let checksum = hashPayload()
                let ended = DispatchTime.now().uptimeNanoseconds
                recording.finish(HostResourceExperimentSample(
                    operation: index, waitMilliseconds: milliseconds(began - submitted),
                    workMilliseconds: milliseconds(ended - began), observedQoS: qos_class_self().rawValue,
                    checksum: checksum
                ))
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return HostResourceExperimentRound(
            round: round, treatment: treatment, configuredConcurrency: queue.maxConcurrentOperationCount,
            peakConcurrency: recording.peak,
            wallMilliseconds: milliseconds(DispatchTime.now().uptimeNanoseconds - started),
            samples: recording.samples.sorted { $0.operation < $1.operation }
        )
    }

    private static func pauseAndRecover(trigger: String) -> HostResourcePauseObservation {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        let controller = HostResourceController(optionalWorkQueue: queue)
        controller.apply(snapshot: snapshot(
            thermal: trigger == "critical-thermal" ? .critical : .nominal, lowPower: trigger == "low-power"
        ))
        let recording = HostWorkRecording()
        for index in 0..<4 {
            queue.addOperation {
                recording.begin()
                recording.finish(HostResourceExperimentSample(
                    operation: index, waitMilliseconds: 0, workMilliseconds: 0,
                    observedQoS: qos_class_self().rawValue, checksum: hashPayload()
                ))
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.03)
        let whilePaused = recording.samples.count
        let elapsed = milliseconds(DispatchTime.now().uptimeNanoseconds - started)
        controller.apply(snapshot: snapshot())
        queue.waitUntilAllOperationsAreFinished()
        controller.stopMonitoringAndRestore()
        return HostResourcePauseObservation(
            trigger: trigger, observationMilliseconds: elapsed, completedWhilePaused: whilePaused,
            completedAfterRecovery: recording.samples.count,
            baselineRestored: queue.qualityOfService == .utility &&
                queue.maxConcurrentOperationCount == 4 && !queue.isSuspended
        )
    }

    private static func hashPayload() -> UInt8 {
        var checksum: UInt8 = 0
        for _ in 0..<iterations {
            let digest = SHA256.hash(data: payload)
            checksum &+= digest.withUnsafeBytes { $0[0] }
        }
        return checksum
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

    private static func snapshot(thermal: HostThermalState = .nominal, lowPower: Bool = false) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 27, minor: 0, patch: 0), architecture: "arm64",
            isAppleSilicon: true, gameModePlatformAvailable: false, thermalState: thermal,
            isLowPowerModeEnabled: lowPower, metalDeviceName: nil, metalFXSpatialScalingAvailable: false,
            metalFXTemporalScalingAvailable: false, gpuDeveloperToolsAvailable: false
        )
    }
}

private final class HostWorkRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var storedPeak = 0
    private var storedSamples: [HostResourceExperimentSample] = []

    func begin() {
        lock.lock()
        active += 1
        storedPeak = max(storedPeak, active)
        lock.unlock()
    }

    func finish(_ sample: HostResourceExperimentSample) {
        lock.lock()
        storedSamples.append(sample)
        active -= 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPeak
    }

    var samples: [HostResourceExperimentSample] {
        lock.lock()
        defer { lock.unlock() }
        return storedSamples
    }
}
