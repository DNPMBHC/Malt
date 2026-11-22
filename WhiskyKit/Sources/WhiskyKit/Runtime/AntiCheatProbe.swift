// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum ProbeArchitecture: String, Decodable, Equatable, Sendable {
    case arm64
    case x64
    case x86
    case arm64ec
    case unknown
}

public enum ProbeSecurityState: String, Decodable, Equatable, Sendable {
    case enabled
    case disabled
    case unknown
}

public enum ProbeSignatureState: String, Decodable, Equatable, Sendable {
    case trustedAuthenticode
    case unsignedOrNoSignature
    case untrusted
    case unknown
}

public enum ProbeDriverLoadState: String, Decodable, Equatable, Sendable {
    case loaded
    case notLoaded
    case unknown
}

public enum ProbeFailureStage: String, Decodable, Equatable, Sendable {
    case none
    case open
    case ioctl
    case response
    case notification
}

public struct AntiCheatProbeProcessNotification: Decodable, Equatable, Sendable {
    public let attempted: Bool
    public let createObserved: Bool
    public let exitObserved: Bool
    public let childCleanupComplete: Bool
    public let childPIDMatched: Bool
    public let boundChildPID: UInt64

    var isVerified: Bool {
        attempted && createObserved && exitObserved && childCleanupComplete
            && childPIDMatched && boundChildPID != 0
    }
}

public struct AntiCheatProbeReport: Decodable, Equatable, Sendable {
    public struct Guest: Decodable, Equatable, Sendable {
        public let kernelArchitecture: ProbeArchitecture
        public let processArchitecture: ProbeArchitecture
        public let windowsBuild: UInt32
        public let secureBoot: ProbeSecurityState
        public let codeIntegrity: ProbeSecurityState
        public let testSigning: ProbeSecurityState
        public let kernelDebugger: ProbeSecurityState
        public let memoryIntegrity: ProbeSecurityState
    }

    public struct Driver: Decodable, Equatable, Sendable {
        // Candidate-file facts are kept separate from the response of the
        // driver that actually answered the IOCTL. A candidate image is not
        // evidence that the same image was loaded.
        public let candidateImageArchitecture: ProbeArchitecture
        public let loadedProbeArchitecture: ProbeArchitecture
        public let candidateImageAuthenticode: ProbeSignatureState
        public let loadState: ProbeDriverLoadState
        public let protocolVersion: UInt32
    }

    public struct Observation: Decodable, Equatable, Sendable {
        public let scope: String
        public let requestorPID: UInt64
        public let observedPID: UInt64
        public let dispatchAttachedContextPID: UInt64
        public let requestorMatchesCurrentContext: Bool
        public let sameProcessObject: Bool
        public let deviceControlSucceeded: Bool
        public let failureStage: ProbeFailureStage
        public let win32Error: UInt32
        public let bytesReturned: UInt32
        public let notification: AntiCheatProbeProcessNotification
    }

    public let schemaVersion: UInt32
    public let nonce: String
    public let capturedAtUnixSeconds: Int64
    public let guest: Guest
    public let driver: Driver
    public let observation: Observation
}

public enum AntiCheatProbeIssue: String, Sendable, Equatable {
    case unknownKernelArchitecture
    case driverArchitectureMismatch
    case candidateImageArchitectureMismatch
    case candidateImageSignatureUnsigned
    case candidateImageSignatureUntrusted
    case candidateImageSignatureUnknown
    case driverNotLoaded
    case driverLoadUnknown
    case unsupportedProtocolVersion
    case unsupportedObservationScope
    case deviceOpenFailed
    case deviceAccessDenied
    case deviceControlFailed
    case protocolRejected
    case invalidDeviceResponse
    case processNotificationNotVerified
    case requestorProcessMismatch
    case requestorProcessNotVerified
}

public struct AntiCheatProbeAssessment: Sendable, Equatable {
    public let report: AntiCheatProbeReport
    public let issues: [AntiCheatProbeIssue]

    // Candidate image signature findings do not invalidate the runtime
    // self-probe: they describe a file supplied for comparison only.
    public var selfProbeVerified: Bool {
        issues.allSatisfy {
            switch $0 {
            case .candidateImageArchitectureMismatch, .candidateImageSignatureUnsigned,
                 .candidateImageSignatureUntrusted, .candidateImageSignatureUnknown:
                return true
            default:
                return false
            }
        }
    }

    // This probe is deliberately scoped to its own client and never authorizes a game.
    public var protectedGameLaunchAuthorized: Bool { false }
}

public enum AntiCheatProbeReportError: Error, Equatable {
    case payloadTooLarge
    case invalidJSON
    case invalidReportFields
    case duplicateObjectKey
    case excessiveNesting
    case unsupportedSchemaVersion
    case invalidNonce
    case challengeMismatch
    case invalidCaptureTime
    case staleReport
}

public enum AntiCheatProbeReportValidator {
    public static let schemaVersion: UInt32 = 2
    public static let driverProtocolVersion: UInt32 = 2
    public static let maximumPayloadSize = 16 * 1024

    public static func assess(
        _ data: Data,
        expectedNonce: String,
        now: Date = .now,
        maximumAge: TimeInterval = 120
    ) throws -> AntiCheatProbeAssessment {
        guard data.count <= maximumPayloadSize else {
            throw AntiCheatProbeReportError.payloadTooLarge
        }
        guard isNonce(expectedNonce) else {
            throw AntiCheatProbeReportError.invalidNonce
        }

        let report = try decodeReport(data)
        try validateEnvelope(report, expectedNonce: expectedNonce, now: now, maximumAge: maximumAge)
        return AntiCheatProbeAssessment(report: report, issues: issues(for: report))
    }

    private static func decodeReport(_ data: Data) throws -> AntiCheatProbeReport {
        var scanner = JSONKeyUniquenessScanner(data: data)
        do {
            try scanner.validate()
        } catch let error as AntiCheatProbeReportError {
            throw error
        } catch {
            throw AntiCheatProbeReportError.invalidJSON
        }

        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            throw AntiCheatProbeReportError.invalidJSON
        }
        do {
            return try JSONDecoder().decode(AntiCheatProbeReport.self, from: data)
        } catch {
            throw AntiCheatProbeReportError.invalidReportFields
        }
    }

    private static func validateEnvelope(
        _ report: AntiCheatProbeReport,
        expectedNonce: String,
        now: Date,
        maximumAge: TimeInterval
    ) throws {
        guard report.schemaVersion == schemaVersion else {
            throw AntiCheatProbeReportError.unsupportedSchemaVersion
        }
        guard isNonce(report.nonce) else { throw AntiCheatProbeReportError.invalidNonce }
        guard report.nonce == expectedNonce else { throw AntiCheatProbeReportError.challengeMismatch }
        try validateCaptureTime(report, now: now, maximumAge: maximumAge)
    }

    private static func validateCaptureTime(
        _ report: AntiCheatProbeReport,
        now: Date,
        maximumAge: TimeInterval
    ) throws {
        guard maximumAge.isFinite, maximumAge > 0,
              let capturedAt = TimeInterval(exactly: report.capturedAtUnixSeconds),
              capturedAt <= now.timeIntervalSince1970 + 30 else {
            throw AntiCheatProbeReportError.invalidCaptureTime
        }
        guard now.timeIntervalSince1970 - capturedAt <= maximumAge else {
            throw AntiCheatProbeReportError.staleReport
        }
    }

    private static func isNonce(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func issues(for report: AntiCheatProbeReport) -> [AntiCheatProbeIssue] {
        architectureIssues(for: report) + signatureIssues(for: report.driver)
            + loadIssues(for: report.driver) + protocolIssues(for: report)
            + deviceControlIssues(for: report.observation, loadState: report.driver.loadState)
            + notificationIssues(for: report.observation)
            + requestorIssues(for: report.observation)
    }

    private static func architectureIssues(for report: AntiCheatProbeReport) -> [AntiCheatProbeIssue] {
        let kernel = report.guest.kernelArchitecture
        var issues: [AntiCheatProbeIssue] = []
        if kernel == .unknown {
            issues.append(.unknownKernelArchitecture)
        } else if report.driver.loadedProbeArchitecture != kernel {
            issues.append(.driverArchitectureMismatch)
        }
        if report.driver.candidateImageArchitecture != .unknown,
           report.driver.candidateImageArchitecture != report.driver.loadedProbeArchitecture {
            issues.append(.candidateImageArchitectureMismatch)
        }
        return issues
    }

    private static func signatureIssues(for driver: AntiCheatProbeReport.Driver) -> [AntiCheatProbeIssue] {
        var issues: [AntiCheatProbeIssue] = []
        switch driver.candidateImageAuthenticode {
        case .trustedAuthenticode: break
        case .unsignedOrNoSignature: issues.append(.candidateImageSignatureUnsigned)
        case .untrusted: issues.append(.candidateImageSignatureUntrusted)
        case .unknown: issues.append(.candidateImageSignatureUnknown)
        }
        return issues
    }

    private static func loadIssues(for driver: AntiCheatProbeReport.Driver) -> [AntiCheatProbeIssue] {
        switch driver.loadState {
        case .loaded: []
        case .notLoaded: [.driverNotLoaded]
        case .unknown: [.driverLoadUnknown]
        }
    }

    private static func protocolIssues(for report: AntiCheatProbeReport) -> [AntiCheatProbeIssue] {
        var issues: [AntiCheatProbeIssue] = []
        if report.driver.protocolVersion != 0,
           report.driver.protocolVersion != driverProtocolVersion {
            issues.append(.unsupportedProtocolVersion)
        }
        if report.observation.scope != "selfProbe" { issues.append(.unsupportedObservationScope) }
        return issues
    }

    private static func deviceControlIssues(
        for observation: AntiCheatProbeReport.Observation,
        loadState: ProbeDriverLoadState
    ) -> [AntiCheatProbeIssue] {
        var issues: [AntiCheatProbeIssue] = []
        switch observation.failureStage {
        case .none:
            if !observation.deviceControlSucceeded { issues.append(.deviceControlFailed) }
        case .open:
            if observation.win32Error == 5 {
                issues.append(.deviceAccessDenied)
            } else if loadState != .notLoaded {
                issues.append(.deviceOpenFailed)
            }
        case .ioctl:
            issues.append(observation.win32Error == 1306 ? .protocolRejected : .deviceControlFailed)
        case .response:
            issues.append(.invalidDeviceResponse)
        case .notification:
            issues.append(.processNotificationNotVerified)
        }
        return issues
    }

    private static func notificationIssues(
        for observation: AntiCheatProbeReport.Observation
    ) -> [AntiCheatProbeIssue] {
        guard observation.failureStage != .notification,
              !observation.notification.isVerified else { return [] }
        return [.processNotificationNotVerified]
    }

    private static func requestorIssues(
        for observation: AntiCheatProbeReport.Observation
    ) -> [AntiCheatProbeIssue] {
        var issues: [AntiCheatProbeIssue] = []
        if observation.requestorPID == 0 || observation.dispatchAttachedContextPID == 0
            || observation.requestorPID != observation.observedPID
            || observation.requestorPID != observation.dispatchAttachedContextPID {
            issues.append(.requestorProcessMismatch)
        }
        if !observation.requestorMatchesCurrentContext || !observation.sameProcessObject {
            issues.append(.requestorProcessNotVerified)
        }
        return issues
    }
}
