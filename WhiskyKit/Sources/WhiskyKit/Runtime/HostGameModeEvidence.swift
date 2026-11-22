// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Darwin
import Foundation

/// Declared support is an input to system eligibility, not evidence of activation.
public enum HostGameModeDeclaration: String, Codable, Sendable {
    case missing, enabled, disabled, invalid

    init(_ value: Any?) {
        guard let value else {
            self = .missing
            return
        }
        guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
            self = .invalid
            return
        }
        self = boolean.boolValue ? .enabled : .disabled
    }
}

public struct HostGameModePlatform: Equatable, Sendable {
    public let operatingSystemMajorVersion: Int
    public let isAppleSilicon: Bool

    public init(operatingSystemMajorVersion: Int, isAppleSilicon: Bool) {
        self.operatingSystemMajorVersion = operatingSystemMajorVersion
        self.isAppleSilicon = isAppleSilicon
    }

    public var isEligible: Bool { isAppleSilicon && operatingSystemMajorVersion >= 14 }

    static let current: HostGameModePlatform = {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        return HostGameModePlatform(
            operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            isAppleSilicon: result == 0 && arm64 == 1
        )
    }()
}

/// An explicitly recorded observation from the system UI for the selected application.
/// PID matching is a short-lived consistency check; PID reuse is possible and this is not OS attestation.
public struct HostGameModeManualObservation: Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case gameOverlaySettings, gameMenu
    }

    let observedProcessID: Int32
    public let isEnabled: Bool
    public let nativeFullScreenConfirmed: Bool
    public let observedAt: Date
    public let source: Source

    public init(
        observedProcessID: Int32, isEnabled: Bool, nativeFullScreenConfirmed: Bool,
        observedAt: Date, source: Source
    ) {
        self.observedProcessID = observedProcessID
        self.isEnabled = isEnabled
        self.nativeFullScreenConfirmed = nativeFullScreenConfirmed
        self.observedAt = observedAt
        self.source = source
    }
}

public struct HostGameModeEvidence: Equatable, Sendable {
    public enum Activation: String, Codable, Sendable {
        case unknown, observedOn, observedOff
    }

    public enum ActivationEvidence: String, Codable, Sendable {
        case noSystemUIObservation, observationExpired, observationInFuture
        case fullScreenUnconfirmed, platformIneligible, subjectMismatch, subjectUnavailable, manualSystemUI
    }

    public enum ChildBenefit: String, Codable, Sendable {
        case unmeasured
    }

    public let declaration: HostGameModeDeclaration
    public let legacyDeclaration: HostGameModeDeclaration
    public let platformEligible: Bool
    public let activation: Activation
    public let activationEvidence: ActivationEvidence
    public let observationSource: HostGameModeManualObservation.Source?
    // The system UI describes the selected application; it does not measure another process.
    public let wineChildBenefit: ChildBenefit = .unmeasured
    public let windowsGuestBenefit: ChildBenefit = .unmeasured

    public static func current(
        bundle: Bundle = .main,
        subjectProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        observation: HostGameModeManualObservation? = nil,
        now: Date = .now
    ) -> HostGameModeEvidence {
        capture(
            infoDictionary: bundle.infoDictionary, platform: .current, subjectProcessID: subjectProcessID,
            observation: observation, now: now
        )
    }

    public static func capture(
        infoDictionary: [String: Any]?,
        platform: HostGameModePlatform,
        subjectProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        observation: HostGameModeManualObservation? = nil,
        now: Date = .now,
        maximumObservationAge: TimeInterval = 120
    ) -> HostGameModeEvidence {
        let result = activationEvidence(
            observation: observation, platform: platform, subjectProcessID: subjectProcessID,
            now: now, maximumAge: maximumObservationAge
        )
        return HostGameModeEvidence(
            declaration: HostGameModeDeclaration(infoDictionary?["LSSupportsGameMode"]),
            legacyDeclaration: HostGameModeDeclaration(infoDictionary?["GCSupportsGameMode"]),
            platformEligible: platform.isEligible,
            activation: result.0,
            activationEvidence: result.1,
            observationSource: result.1 == .manualSystemUI ? observation?.source : nil
        )
    }

    private static func activationEvidence(
        observation: HostGameModeManualObservation?, platform: HostGameModePlatform, subjectProcessID: Int32,
        now: Date, maximumAge: TimeInterval
    ) -> (Activation, ActivationEvidence) {
        guard let observation else { return (.unknown, .noSystemUIObservation) }
        guard observation.observedProcessID == subjectProcessID else { return (.unknown, .subjectMismatch) }
        guard subjectProcessID > 0 else { return (.unknown, .subjectUnavailable) }
        guard kill(subjectProcessID, 0) == 0 || errno == EPERM else { return (.unknown, .subjectUnavailable) }
        guard platform.isEligible else { return (.unknown, .platformIneligible) }
        guard observation.nativeFullScreenConfirmed else { return (.unknown, .fullScreenUnconfirmed) }
        let age = now.timeIntervalSince(observation.observedAt)
        guard age >= 0 else { return (.unknown, .observationInFuture) }
        guard maximumAge.isFinite, maximumAge >= 0, age <= maximumAge else {
            return (.unknown, .observationExpired)
        }
        return (observation.isEnabled ? .observedOn : .observedOff, .manualSystemUI)
    }
}
