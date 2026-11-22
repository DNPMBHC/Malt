// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Compile this executable alongside HostGameModeEvidence.swift; no application module import is required.
@main
struct HostGameModeEvidenceChecks {
    private enum CheckFailure: Error { case failed(String) }
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let eligible = HostGameModePlatform(operatingSystemMajorVersion: 27, isAppleSilicon: true)

    static func main() {
        do {
            try declarationsAndEligibilityDoNotActivate()
            try invalidDeclarationsAreRejected()
            try manualObservationDoesNotProveChildBenefit()
            try invalidOrExpiredObservationsRemainUnknown()
            try olderOrIneligiblePlatformsRemainUnknown()
            try observationsCannotBeReusedForAnotherProcess()
            print("host_game_mode_checks_passed=6")
        } catch {
            print("host_game_mode_checks_failed: \(error)")
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure.failed(label) }
    }

    private static func declarationsAndEligibilityDoNotActivate() throws {
        for declarations: [String: Any] in [[:], ["LSSupportsGameMode": true], ["GCSupportsGameMode": true]] {
            let result = HostGameModeEvidence.capture(infoDictionary: declarations, platform: eligible)
            try check(result.platformEligible, "platform prerequisite")
            try check(result.activation == .unknown, "declaration must not imply activation")
            try check(result.wineChildBenefit == .unmeasured, "Wine effect is independent")
            try check(result.windowsGuestBenefit == .unmeasured, "guest effect is independent")
        }
    }

    private static func invalidDeclarationsAreRejected() throws {
        for value: Any in ["true", NSNumber(value: 1), [true]] {
            let result = HostGameModeEvidence.capture(
                infoDictionary: ["LSSupportsGameMode": value], platform: eligible
            )
            try check(result.declaration == .invalid, "only plist Boolean is accepted")
        }
        let result = HostGameModeEvidence.capture(
            infoDictionary: ["LSSupportsGameMode": false, "GCSupportsGameMode": true], platform: eligible
        )
        try check(result.declaration == .disabled, "new declaration is independent")
        try check(result.legacyDeclaration == .enabled, "legacy declaration is preserved as evidence")
    }

    private static func manualObservationDoesNotProveChildBenefit() throws {
        for isEnabled in [true, false] {
            let observation = HostGameModeManualObservation(
                observedProcessID: ProcessInfo.processInfo.processIdentifier,
                isEnabled: isEnabled, nativeFullScreenConfirmed: true, observedAt: now, source: .gameOverlaySettings
            )
            let result = HostGameModeEvidence.capture(
                infoDictionary: ["LSSupportsGameMode": true], platform: eligible, observation: observation, now: now
            )
            try check(result.activation == (isEnabled ? .observedOn : .observedOff), "explicit system UI state")
            try check(result.observationSource == .gameOverlaySettings, "manual provenance is preserved")
            try check(result.wineChildBenefit == .unmeasured, "parent observation does not prove Wine benefit")
            try check(result.windowsGuestBenefit == .unmeasured, "parent observation does not prove guest benefit")
        }
    }

    private static func invalidOrExpiredObservationsRemainUnknown() throws {
        for offset in [-121.0, 1.0] {
            let observation = HostGameModeManualObservation(
                observedProcessID: ProcessInfo.processInfo.processIdentifier,
                isEnabled: true, nativeFullScreenConfirmed: true,
                observedAt: now.addingTimeInterval(offset), source: .gameMenu
            )
            let result = HostGameModeEvidence.capture(
                infoDictionary: [:], platform: eligible, observation: observation, now: now
            )
            try check(result.activation == .unknown, "stale or future evidence is rejected")
            try check(result.observationSource == nil, "rejected observation has no activation provenance")
        }
        let observation = HostGameModeManualObservation(
                observedProcessID: ProcessInfo.processInfo.processIdentifier,
            isEnabled: true, nativeFullScreenConfirmed: false, observedAt: now, source: .gameMenu
        )
        let result = HostGameModeEvidence.capture(
            infoDictionary: [:], platform: eligible, observation: observation, now: now
        )
        try check(result.activation == .unknown, "native full screen must be confirmed")
    }

    private static func observationsCannotBeReusedForAnotherProcess() throws {
        let observation = HostGameModeManualObservation(
            observedProcessID: ProcessInfo.processInfo.processIdentifier,
            isEnabled: true, nativeFullScreenConfirmed: true, observedAt: now, source: .gameMenu
        )
        let otherSubject = HostGameModeEvidence.capture(
            infoDictionary: [:], platform: eligible, subjectProcessID: ProcessInfo.processInfo.processIdentifier + 1,
            observation: observation, now: now
        )
        try check(otherSubject.activation == .unknown, "other process observations cannot be reused")
        try check(otherSubject.activationEvidence == .subjectMismatch, "subject mismatch is explicit")
        let invalid = HostGameModeManualObservation(
            observedProcessID: -1, isEnabled: true, nativeFullScreenConfirmed: true, observedAt: now, source: .gameMenu
        )
        let unavailable = HostGameModeEvidence.capture(
            infoDictionary: [:], platform: eligible, subjectProcessID: -1, observation: invalid, now: now
        )
        try check(unavailable.activation == .unknown, "invalid process cannot be activated")
        try check(unavailable.activationEvidence == .subjectUnavailable, "unavailable subject is explicit")
    }

    private static func olderOrIneligiblePlatformsRemainUnknown() throws {
        let observation = HostGameModeManualObservation(
                observedProcessID: ProcessInfo.processInfo.processIdentifier,
            isEnabled: true, nativeFullScreenConfirmed: true, observedAt: now, source: .gameMenu
        )
        for platform in [HostGameModePlatform(operatingSystemMajorVersion: 13, isAppleSilicon: true),
                         HostGameModePlatform(operatingSystemMajorVersion: 27, isAppleSilicon: false)] {
            let result = HostGameModeEvidence.capture(
                infoDictionary: ["LSSupportsGameMode": true], platform: platform, observation: observation, now: now
            )
            try check(!result.platformEligible, "platform prerequisites")
            try check(result.activation == .unknown, "contradictory observation is rejected")
        }
    }
}
