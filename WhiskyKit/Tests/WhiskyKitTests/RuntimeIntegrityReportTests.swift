// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

final class RuntimeIntegrityReportTests: XCTestCase {
    func testMissingTrustedAnchorNeverReportsOfficialBuild() {
        let report = RuntimeIntegrityAttestor.evaluate(
            csrutilOutput: "System Integrity Protection status: enabled.",
            signatureState: .validTeamSigned,
            teamIdentifier: "TEAM123456",
            hardenedRuntimeEnabled: true,
            hvVmmPresent: 0
        )

        XCTAssertTrue(report.hasValidCodeSignature)
        XCTAssertTrue(report.hasHardenedRuntime)
        XCTAssertFalse(report.isTrustedOfficialTeam)
        XCTAssertFalse(report.isOfficialBuild)
        XCTAssertEqual(report.hostSIPStatus, .enabled)
        XCTAssertEqual(report.sipStatus, .enabled)
    }

    func testUntrustedTeamWithDisabledSIPIsNotOfficialBuild() {
        let report = RuntimeIntegrityAttestor.evaluate(
            csrutilOutput: "System Integrity Protection status: disabled.",
            signatureState: .validTeamSigned,
            teamIdentifier: "THIRD99999",
            hardenedRuntimeEnabled: true,
            hvVmmPresent: 0,
            trustedOfficialTeamIdentifiers: ["OFFICIAL01"]
        )

        XCTAssertTrue(report.hasValidCodeSignature)
        XCTAssertTrue(report.hasHardenedRuntime)
        XCTAssertFalse(report.isTrustedOfficialTeam)
        XCTAssertFalse(report.isOfficialBuild)
        XCTAssertEqual(report.hostSIPStatus, .disabled)
        XCTAssertEqual(report.hostExecutionNature, .physicalHardware)
    }

    func testTrustedTeamWithoutHardenedRuntimeIsNotOfficialBuild() {
        let report = RuntimeIntegrityAttestor.evaluate(
            csrutilOutput: "System Integrity Protection status: enabled.",
            signatureState: .validTeamSigned,
            teamIdentifier: "OFFICIAL01",
            hardenedRuntimeEnabled: false,
            hvVmmPresent: 0,
            trustedOfficialTeamIdentifiers: ["OFFICIAL01"]
        )

        XCTAssertTrue(report.hasValidCodeSignature)
        XCTAssertFalse(report.hasHardenedRuntime)
        XCTAssertTrue(report.isTrustedOfficialTeam)
        XCTAssertFalse(report.isOfficialBuild)
    }

    func testTrustedTeamWithValidSignatureAndHardenedRuntimeReportsFactsSeparately() throws {
        let report = RuntimeIntegrityAttestor.evaluate(
            csrutilOutput: "System Integrity Protection status: disabled.",
            signatureState: .validTeamSigned,
            teamIdentifier: " OFFICIAL01 ",
            hardenedRuntimeEnabled: true,
            hvVmmPresent: 1,
            trustedOfficialTeamIdentifiers: ["OFFICIAL01", "   "]
        )

        XCTAssertTrue(report.hasValidCodeSignature)
        XCTAssertTrue(report.hasHardenedRuntime)
        XCTAssertTrue(report.isTrustedOfficialTeam)
        XCTAssertTrue(report.isOfficialBuild)
        XCTAssertEqual(report.hostSIPStatus, .disabled)
        XCTAssertEqual(report.hostExecutionNature, .virtualMachine)

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(RuntimeIntegrityReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
