// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class AntiCheatProbeTests: XCTestCase {
    private let nonce = String(repeating: "a", count: 64)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOversizedPayloadIsRejectedBeforeParsing() {
        let data = Data(repeating: 0x20, count: AntiCheatProbeReportValidator.maximumPayloadSize + 1)

        assertReportError(.payloadTooLarge, data: data)
    }

    func testTruncatedPayloadIsRejectedAsInvalidJSON() {
        assertReportError(.invalidJSON, data: Data("{".utf8))
    }

    func testExcessiveNestingIsRejected() {
        let nested = String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)
        assertReportError(.excessiveNesting, data: Data(nested.utf8))
    }

    func testDuplicateObjectKeysAreRejected() {
        let data = Data(#"{"schemaVersion":1,"schemaVersion":1}"#.utf8)

        assertReportError(.duplicateObjectKey, data: data)
    }

    func testWrongFieldTypeIsRejected() {
        assertReportError(.invalidReportFields, data: makeAntiCheatPayload(protocolVersion: "one"))
    }

    func testPreviousReportSchemaVersionIsRejected() {
        assertReportError(.unsupportedSchemaVersion, data: makeAntiCheatPayload(schemaVersion: 1))
    }

    func testUnknownEnumValueIsRejected() {
        assertReportError(.invalidReportFields, data: makeAntiCheatPayload(kernelArchitecture: "riscv"))
    }

    func testMismatchedNonceIsRejected() {
        assertReportError(
            .challengeMismatch,
            data: makeAntiCheatPayload(reportNonce: String(repeating: "b", count: 64))
        )
    }

    func testStaleReportHasDistinctError() {
        assertReportError(.staleReport, data: makeAntiCheatPayload(capturedAt: 1_699_999_000))
    }

    func testDriverArchitectureMismatchFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(loadedProbeArchitecture: "x64"))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.driverArchitectureMismatch))
    }

    func testRequestorAndObservedPIDMismatchFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(observedPID: 101))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.requestorProcessMismatch))
    }

    func testZeroRequestorPIDFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(requestorPID: 0))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.requestorProcessMismatch))
    }

    func testMismatchedCurrentContextPIDFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(dispatchAttachedContextPID: 101))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.requestorProcessMismatch))
    }

    func testRequestorContextMismatchFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(requestorMatchesCurrentContext: false))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.requestorProcessNotVerified))
    }

    func testDeviceControlFailureFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(deviceControlSucceeded: false))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.deviceControlFailed))
    }

    func testAccessDeniedDoesNotMasqueradeAsDriverNotLoaded() throws {
        let assessment = try assess(makeAntiCheatPayload(
            loadState: "unknown",
            deviceControlSucceeded: false,
            failureStage: "open",
            win32Error: 5,
            bytesReturned: 0
        ))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.deviceAccessDenied))
        XCTAssertTrue(assessment.issues.contains(.driverLoadUnknown))
        XCTAssertFalse(assessment.issues.contains(.driverNotLoaded))
    }

    func testMissingDeviceIsReportedAsNotLoaded() throws {
        let assessment = try assess(makeAntiCheatPayload(
            loadState: "notLoaded",
            deviceControlSucceeded: false,
            failureStage: "open",
            win32Error: 2,
            bytesReturned: 0
        ))

        XCTAssertTrue(assessment.issues.contains(.driverNotLoaded))
        XCTAssertFalse(assessment.issues.contains(.driverLoadUnknown))
        XCTAssertFalse(assessment.issues.contains(.deviceAccessDenied))
    }

    func testProtocolRejectionPreservesNativeFailureStage() throws {
        let assessment = try assess(makeAntiCheatPayload(
            loadState: "unknown",
            protocolVersion: 0,
            deviceControlSucceeded: false,
            failureStage: "ioctl",
            win32Error: 1306,
            bytesReturned: 0
        ))

        XCTAssertTrue(assessment.issues.contains(.protocolRejected))
        XCTAssertTrue(assessment.issues.contains(.driverLoadUnknown))
        XCTAssertFalse(assessment.issues.contains(.unsupportedProtocolVersion))
    }

    func testInvalidResponseHasDistinctFailure() throws {
        let assessment = try assess(makeAntiCheatPayload(
            loadState: "unknown",
            failureStage: "response",
            win32Error: 0,
            bytesReturned: 12
        ))

        XCTAssertTrue(assessment.issues.contains(.invalidDeviceResponse))
    }

    func testMissingProcessCreateOrExitNotificationFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(notificationExitObserved: false))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.processNotificationNotVerified))
    }

    func testNotificationFailureStageIsMappedSeparately() throws {
        let assessment = try assess(makeAntiCheatPayload(
            failureStage: "notification",
            bytesReturned: 32,
            notificationCreateObserved: true,
            notificationExitObserved: false,
            notificationCleanupComplete: true
        ))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.processNotificationNotVerified))
    }

    func testSuccessfulProbeUsesNotificationResponseByteCount() throws {
        let assessment = try assess(makeAntiCheatPayload(bytesReturned: 32))

        XCTAssertTrue(assessment.selfProbeVerified)
        XCTAssertEqual(assessment.report.observation.bytesReturned, 32)
    }

    func testIncompleteChildCleanupFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(notificationCleanupComplete: false))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.processNotificationNotVerified))
    }

    func testUnmatchedChildPIDFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(notificationChildPIDMatched: false))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.processNotificationNotVerified))
    }

    func testMissingBoundChildPIDFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(notificationBoundChildPID: 0))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.processNotificationNotVerified))
    }

    func testUnsupportedDriverProtocolFailsSelfProbe() throws {
        let assessment = try assess(makeAntiCheatPayload(protocolVersion: 3))

        XCTAssertFalse(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.unsupportedProtocolVersion))
    }

    func testCandidateImageSignatureIsReportedSeparately() throws {
        let cases: [(String, AntiCheatProbeIssue)] = [
            ("unsignedOrNoSignature", .candidateImageSignatureUnsigned),
            ("untrusted", .candidateImageSignatureUntrusted),
            ("unknown", .candidateImageSignatureUnknown)
        ]

        for (signature, expectedIssue) in cases {
            let assessment = try assess(makeAntiCheatPayload(candidateImageAuthenticode: signature))

            XCTAssertTrue(assessment.selfProbeVerified, "signature=\(signature)")
            XCTAssertTrue(assessment.issues.contains(expectedIssue), "signature=\(signature)")
        }
    }

    func testCandidateArchitectureMismatchDoesNotClaimRuntimeProbeFailure() throws {
        let assessment = try assess(makeAntiCheatPayload(candidateImageArchitecture: "x64"))

        XCTAssertTrue(assessment.selfProbeVerified)
        XCTAssertTrue(assessment.issues.contains(.candidateImageArchitectureMismatch))
    }

    func testSuccessfulProbeDoesNotAuthorizeProtectedGame() throws {
        let assessment = try assess(makeAntiCheatPayload())

        XCTAssertTrue(assessment.selfProbeVerified)
        XCTAssertFalse(assessment.protectedGameLaunchAuthorized)
    }

    func testGuestProbeServiceBindsChallengeToGuestReport() async throws {
        let capturedAt = Int64(now.timeIntervalSince1970) - 50
        let provider = SelfProbeGuest { nonce in
            SelfProbeFixtures.report(nonce: nonce, capturedAt: capturedAt)
        }
        let backend = WindowsGuestRuntimeBackend(
            provider: provider,
            evidence: { _, _ in RuntimeEvidence(kernelDiagnostics: .selfProbeVerified) }
        )

        let assessment = try await backend.assessSelfProbe(now: now)

        XCTAssertEqual(assessment.report.nonce.utf8.count, 64)
        XCTAssertTrue(assessment.selfProbeVerified)
        XCTAssertFalse(assessment.protectedGameLaunchAuthorized)

        let protectedURL = URL(fileURLWithPath: "/tmp/VALORANT.exe")
        let profile = try XCTUnwrap(GameCompatibilityDatabase.profile(for: protectedURL))
        let capability = backend.capability(for: profile, host: .current())
        XCTAssertEqual(capability.kernelDiagnostics, .selfProbeVerified)
        XCTAssertEqual(capability.vendorSupport, .unknown)
        XCTAssertFalse(capability.canLaunch)
    }

    private func assertReportError(
        _ expected: AntiCheatProbeReportError,
        data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AntiCheatProbeReportValidator.assess(
                data,
                expectedNonce: nonce,
                now: now
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? AntiCheatProbeReportError, expected, file: file, line: line)
        }
    }

    private func assess(_ data: Data) throws -> AntiCheatProbeAssessment {
        try AntiCheatProbeReportValidator.assess(data, expectedNonce: nonce, now: now)
    }
}
