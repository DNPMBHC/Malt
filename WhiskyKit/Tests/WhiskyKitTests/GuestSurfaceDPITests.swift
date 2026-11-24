// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import XCTest

@testable import WhiskyKit

final class GuestSurfaceDPITests: XCTestCase {
  private let config = RuntimeGuestConfiguration(
    identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", architecture: "arm64",
    fileMappings: [], startupTimeoutSeconds: 30)
  private let target = GuestDisplayMode(width: 1920, height: 1200, refreshRateHz: 60, dpiScalePercent: 150)

  func testAppliedDPIIsReadBackAndRetainedUntilExplicitRestore() async throws {
    let events = DPIRecoveryEvents()
    let base = DPIBaseDisplay(events: events)
    let settings = DPISettingsDouble(events: events)
    let display = try GuestSurfaceDPIAwareDisplaySync(
      base: base, settings: settings, scaleAutomationID: "scale-control")
    let snapshot = try await display.applyGuestDisplayMode(target, configuration: config)
    XCTAssertEqual(snapshot.dpiSynchronizationStatus, .applied)
    XCTAssertEqual(snapshot.appliedMode.dpiScalePercent, 150)
    XCTAssertEqual(snapshot.previousMode, DPIBaseDisplay.baseline)
    let beforeRestore = await events.values
    XCTAssertEqual(beforeRestore, ["resolution_query", "dpi_Query", "resolution_apply", "dpi_Apply"])
    let restored = try await display.restoreGuestDisplayMode(snapshot, configuration: config)
    XCTAssertEqual(restored, DPIBaseDisplay.baseline)
    let afterRestore = await events.values
    XCTAssertEqual(Array(afterRestore.suffix(2)), ["dpi_Restore", "resolution_restore"])
  }

  func testApplyFailureRollsBackDPIBeforeResolution() async throws {
    let events = DPIRecoveryEvents()
    let display = try GuestSurfaceDPIAwareDisplaySync(
      base: DPIBaseDisplay(events: events),
      settings: DPISettingsDouble(events: events, failApply: true), scaleAutomationID: "scale-control")
    do {
      _ = try await display.applyGuestDisplayMode(target, configuration: config)
      XCTFail("Expected Settings failure")
    } catch let error as GuestSurfaceDPIError {
      XCTAssertEqual(error, .operationFailed("settings_probe_failed"))
    }
    let recorded = await events.values
    XCTAssertEqual(Array(recorded.suffix(2)), ["dpi_Restore", "resolution_restore"])
  }

  func testWrongAppliedPercentCannotBeReportedAsApplied() async throws {
    let events = DPIRecoveryEvents()
    let display = try GuestSurfaceDPIAwareDisplaySync(
      base: DPIBaseDisplay(events: events),
      settings: DPISettingsDouble(events: events, wrongAppliedPercent: true), scaleAutomationID: "scale-control")
    do {
      _ = try await display.applyGuestDisplayMode(target, configuration: config)
      XCTFail("Expected readback mismatch")
    } catch let error as GuestSurfaceDPIError { XCTAssertEqual(error, .invalidResponse) }
    let recorded = await events.values
    XCTAssertEqual(Array(recorded.suffix(2)), ["dpi_Restore", "resolution_restore"])
  }

  func testMissingDiscoveredControlReturnsUnsupportedWithoutApplyingDPI() async throws {
    let events = DPIRecoveryEvents()
    let display = try GuestSurfaceDPIAwareDisplaySync(
      base: DPIBaseDisplay(events: events), settings: DPISettingsDouble(events: events), scaleAutomationID: nil)
    let snapshot = try await display.applyGuestDisplayMode(target, configuration: config)
    XCTAssertEqual(snapshot.dpiSynchronizationStatus, .unsupported)
    XCTAssertEqual(snapshot.appliedMode.dpiScalePercent, 100)
    let recorded = await events.values
    XCTAssertFalse(recorded.contains("dpi_Apply"))
  }

  func testUnconfirmedDPIRestoreStillAttemptsResolutionAndReportsFailure() async throws {
    let events = DPIRecoveryEvents()
    let display = try GuestSurfaceDPIAwareDisplaySync(
      base: DPIBaseDisplay(events: events),
      settings: DPISettingsDouble(events: events, failRestore: true), scaleAutomationID: "scale-control")
    let snapshot = try await display.applyGuestDisplayMode(target, configuration: config)
    do {
      _ = try await display.restoreGuestDisplayMode(snapshot, configuration: config)
      XCTFail("Expected recovery failure")
    } catch let error as GuestSurfaceDPIError { XCTAssertEqual(error, .restoreMismatch) }
    let recorded = await events.values
    XCTAssertEqual(Array(recorded.suffix(2)), ["dpi_Restore", "resolution_restore"])
  }

  func testWrongRestoredResolutionCannotBeReportedAsRestored() async throws {
    let events = DPIRecoveryEvents()
    let display = try GuestSurfaceDPIAwareDisplaySync(
      base: DPIBaseDisplay(events: events, wrongRestore: true),
      settings: DPISettingsDouble(events: events), scaleAutomationID: "scale-control")
    let snapshot = try await display.applyGuestDisplayMode(target, configuration: config)
    do {
      _ = try await display.restoreGuestDisplayMode(snapshot, configuration: config)
      XCTFail("Expected resolution mismatch")
    } catch let error as GuestSurfaceDPIError { XCTAssertEqual(error, .restoreMismatch) }
  }

  func testDTORejectsWrongOwnerOperationAndSchema() throws {
    for mutation: [String: Any] in [["owner": "unknown"], ["mode": "Restore"], ["schema_version": 2]] {
      var payload = validDPIResponse(.query)
      payload.merge(mutation) { _, new in new }
      XCTAssertThrowsError(
        try GuestSurfaceDPISettingsResult.decode(
          JSONSerialization.data(withJSONObject: payload), operation: .query))
    }
  }

  func testDTORejectsInjectedControlIDsAndPrivateDiagnostics() throws {
    for id in ["scale;exit", "../scale", "scale\ncontrol", String(repeating: "x", count: 129)] {
      XCTAssertThrowsError(try GuestSurfaceDPISettingsResult.validateControlID(id))
    }
    var payload = validDPIResponse(.query)
    payload["error_code"] = "C:\\private\\detail"
    XCTAssertThrowsError(
      try GuestSurfaceDPISettingsResult.decode(
        JSONSerialization.data(withJSONObject: payload), operation: .query))
    payload = validDPIResponse(.discover)
    payload["controls"] = [["automation_id": "scale;exit", "enabled": true, "owner_matches": true]]
    XCTAssertThrowsError(
      try GuestSurfaceDPISettingsResult.decode(
        JSONSerialization.data(withJSONObject: payload), operation: .discover))
  }

  func testDTORequiresPendingRecoveryForChangedDPIAndVerifiedRestore() throws {
    var payload = validDPIResponse(.apply, percent: 150)
    payload["restore_required"] = false
    XCTAssertThrowsError(
      try GuestSurfaceDPISettingsResult.decode(
        JSONSerialization.data(withJSONObject: payload), operation: .apply))
    payload = validDPIResponse(.restore)
    payload["restore_verified"] = false
    XCTAssertThrowsError(
      try GuestSurfaceDPISettingsResult.decode(
        JSONSerialization.data(withJSONObject: payload), operation: .restore))
    payload = validDPIResponse(.apply, percent: 150)
    payload["settings_window_closed"] = false
    XCTAssertThrowsError(
      try GuestSurfaceDPISettingsResult.decode(
        JSONSerialization.data(withJSONObject: payload), operation: .apply))
  }
}

private func validDPIResponse(
  _ operation: GuestSurfaceDPISettingsOperation, percent: Int = 100
) -> [String: Any] {
  [
    "owner": "@DNPMBHC", "schema_version": 1, "mode": operation.rawValue,
    "executed": true, "succeeded": true, "current_percent": percent,
    "baseline_percent": 100, "applied_percent": percent, "restored_percent": percent,
    "restore_required": operation == .apply && percent != 100,
    "restore_verified": true, "settings_window_closed": true, "controls": []
  ]
}

private actor DPIRecoveryEvents {
  private(set) var values: [String] = []
  func record(_ value: String) { values.append(value) }
}

private actor DPISettingsDouble: GuestSurfaceDPISettingsExecuting {
  let events: DPIRecoveryEvents
  let failApply: Bool
  let failRestore: Bool
  let wrongAppliedPercent: Bool

  init(
    events: DPIRecoveryEvents, failApply: Bool = false, failRestore: Bool = false,
    wrongAppliedPercent: Bool = false
  ) {
    self.events = events
    self.failApply = failApply
    self.failRestore = failRestore
    self.wrongAppliedPercent = wrongAppliedPercent
  }

  func execute(
    _ operation: GuestSurfaceDPISettingsOperation, percent: Int,
    scaleAutomationID: String?, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestSurfaceDPISettingsResult {
    await events.record("dpi_" + operation.rawValue)
    if operation == .apply && failApply { throw GuestSurfaceDPIError.operationFailed("settings_probe_failed") }
    if operation == .restore && failRestore { throw GuestSurfaceDPIError.restoreMismatch }
    let current = operation == .apply ? (wrongAppliedPercent ? 125 : percent) : 100
    return try GuestSurfaceDPISettingsResult.decode(
      JSONSerialization.data(withJSONObject: validDPIResponse(operation, percent: current)), operation: operation)
  }
}

private actor DPIBaseDisplay: GuestDisplaySynchronizing {
  static let baseline = GuestDisplayMode(width: 1280, height: 720, refreshRateHz: 60)
  let events: DPIRecoveryEvents
  let wrongRestore: Bool

  init(events: DPIRecoveryEvents, wrongRestore: Bool = false) {
    self.events = events
    self.wrongRestore = wrongRestore
  }

  func queryGuestDisplayMode(configuration: RuntimeGuestConfiguration) async throws -> GuestDisplayMode {
    await events.record("resolution_query")
    return Self.baseline
  }

  func applyGuestDisplayMode(
    _ mode: GuestDisplayMode, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    await events.record("resolution_apply")
    return GuestDisplaySyncSnapshot(previousMode: Self.baseline, appliedMode: mode, displayDeviceName: "display-1")
  }

  func restoreGuestDisplayMode(
    _ snapshot: GuestDisplaySyncSnapshot, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplayMode {
    await events.record("resolution_restore")
    return wrongRestore ? GuestDisplayMode(width: 1920, height: 1200, refreshRateHz: 60) : snapshot.previousMode
  }
}
