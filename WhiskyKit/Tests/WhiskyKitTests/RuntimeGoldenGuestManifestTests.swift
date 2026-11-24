// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC

import Foundation
import XCTest
@testable import WhiskyKit

final class RuntimeGoldenGuestManifestTests: XCTestCase {
    func testMissingGoldenManifestReturnsGracefulUninitialized() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingURL = tempDir.appending(path: "golden-guest-manifest.json")
        let result = GoldenGuestManifestInspector.inspect(
            explicitURL: missingURL,
            environment: [:]
        )
        XCTAssertEqual(result.state, .uninitialized)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.sha256)
    }

    func testValidGoldenManifestDecodesFieldsAndDigest() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestURL = tempDir.appending(path: "golden-guest-manifest.json")
        let payload = """
        {
          "schema_version": "1.0.0",
          "guest_id": "golden-win11-arm64-v1",
          "driver_version": "v100.6.101.58000",
          "qemu_profile": "virtio-ramfb-gl+swtpm+secureboot",
          "security_invariants_passed": true,
          "image_sha256": "deadbeef",
          "captured_at": "2026-11-24T00:00:00Z"
        }
        """
        try Data(payload.utf8).write(to: manifestURL)

        let result = GoldenGuestManifestInspector.inspect(explicitURL: manifestURL, environment: [:])
        XCTAssertEqual(result.state, .ready)
        XCTAssertNotNil(result.sha256)
        XCTAssertEqual(result.manifest?.guestID, "golden-win11-arm64-v1")
        XCTAssertEqual(result.manifest?.driverVersion, "v100.6.101.58000")
        XCTAssertEqual(result.manifest?.securityInvariantsPassed, true)
    }

    func testInvalidGoldenManifestReturnsInvalidStateWithoutCrashing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let invalidURL = tempDir.appending(path: "golden-guest-manifest.json")
        try Data("not-json".utf8).write(to: invalidURL)

        let result = GoldenGuestManifestInspector.inspect(explicitURL: invalidURL, environment: [:])
        XCTAssertEqual(result.state, .invalid)
        XCTAssertNil(result.manifest)
        XCTAssertNotNil(result.sha256)
    }

    func testUnifiedBaselineReportReflects5CSafeGateAndRuntimeDigest() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runtimeURL = tempDir.appending(path: "runtime-manifest.json")
        let runtimePayload = """
        {
          "schemaVersion": "1.0.0",
          "owner": "@DNPMBHC",
          "capturedAt": "2026-11-24",
          "baselineSource": "test",
          "components": []
        }
        """
        try Data(runtimePayload.utf8).write(to: runtimeURL)

        let report = UnifiedRuntimeBaselineReport.collect(
            libraryFolder: tempDir,
            runtimeManifestURL: runtimeURL,
            goldenManifestURL: tempDir.appending(path: "missing.json"),
            environment: [:]
        )
        XCTAssertNotNil(report.runtimeManifestSHA256)
        XCTAssertEqual(report.goldenGuestState, .uninitialized)
        XCTAssertFalse(report.guestSurfaceGate.supportsRealGuestScanout)
        XCTAssertFalse(report.guestSurfaceGate.supportsVirtualHIDSink)
        XCTAssertFalse(report.guestSurfaceGate.gameShellEntryEnabled)
    }
}
