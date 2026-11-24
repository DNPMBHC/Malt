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

    func testWindow6ANestedGoldenManifestSchemaDecodesAccurately() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestURL = tempDir.appending(path: "golden-guest-manifest.json")
        try Data(Self.window6AFixture.utf8).write(to: manifestURL)

        let result = GoldenGuestManifestInspector.inspect(explicitURL: manifestURL, environment: [:])
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.manifest?.schemaVersion, "1")
        XCTAssertEqual(result.manifest?.guestID, "golden-win11-arm64-v1")
        XCTAssertEqual(result.manifest?.status, "sealed_readonly")
        XCTAssertEqual(result.manifest?.driverVersion, "100.6.101.58000")
        XCTAssertEqual(result.manifest?.featureLevel, "11_1")
        XCTAssertEqual(result.manifest?.whqlReady, true)
        XCTAssertEqual(result.manifest?.optimizerProfileID, "anticheat-minimal-win11-arm64")
        XCTAssertEqual(result.manifest?.securityInvariantsPassed, true)
        XCTAssertEqual(result.manifest?.imageSHA256, "784ba01e")
        XCTAssertEqual(result.manifest?.goldenTotalBytes, 29_547_908_107)
    }

    private static let window6AFixture = """
    {
      "schema_version": 1,
      "owner": "@DNPMBHC",
      "golden_id": "golden-win11-arm64-v1",
      "status": "sealed_readonly",
      "captured_at_utc": "2026-11-24T11:00:57.709563+00:00",
      "qemu_profile": {
        "backend": "QEMU",
        "display_hardware": "virtio-ramfb-gl",
        "cpu_count": 6,
        "memory_mib": 6144
      },
      "graphics_driver": {
        "driver_version": "100.6.101.58000",
        "whql_ready": true,
        "feature_level": "11_1"
      },
      "security_invariants": {
        "qga_service_running": true,
        "prism_signatures_valid": true,
        "tpm_ready": true,
        "secure_boot_enabled": true,
        "bcd_safe": true,
        "test_signing_disabled": true
      },
      "optimizer": {
        "profile_id": "anticheat-minimal-win11-arm64"
      },
      "fingerprints": {
        "golden_bundle_sha256": "784ba01e",
        "golden_total_bytes": 29547908107
      }
    }
    """

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
        XCTAssertTrue(report.advisoryLocalizationKeys.isEmpty)
        XCTAssertFalse(report.guestSurfaceGate.supportsRealGuestScanout)
        XCTAssertFalse(report.guestSurfaceGate.supportsVirtualHIDSink)
        XCTAssertFalse(report.guestSurfaceGate.gameShellEntryEnabled)

        let goldenURL = tempDir.appending(path: "golden-guest-manifest.json")
        try Data(Self.window6AFixture.utf8).write(to: goldenURL)
        let readyReport = UnifiedRuntimeBaselineReport.collect(
            libraryFolder: tempDir,
            runtimeManifestURL: runtimeURL,
            goldenManifestURL: goldenURL,
            environment: [:]
        )
        XCTAssertEqual(readyReport.goldenGuestState, .ready)
        XCTAssertEqual(readyReport.advisoryLocalizationKeys, [
            "settings.goldenGuest.advisory.viogpu3dResize",
            "settings.goldenGuest.advisory.doNotReplaceSignedDLL",
            "settings.goldenGuest.advisory.pointerModeCheck"
        ])
    }
}
