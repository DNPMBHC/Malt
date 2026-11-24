// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

/// Optional standard Settings automation, configured only with a control ID discovered on this Guest.
public actor GuestSurfaceDPIAwareDisplaySync: GuestDisplaySynchronizing {
  private let base: any GuestDisplaySynchronizing
  private let settings: any GuestSurfaceDPISettingsExecuting
  private let scaleAutomationID: String?

  public init(provider: UTMWindowsGuestProvider, scaleAutomationID: String? = nil) throws {
    try GuestSurfaceDPISettingsResult.validateControlID(scaleAutomationID)
    let headless = provider.headlessSurfaceProvider()
    base = headless
    settings = GuestSurfaceDPISettingsExecutor(provider: headless)
    self.scaleAutomationID = scaleAutomationID
  }

  init(
    base: any GuestDisplaySynchronizing, settings: any GuestSurfaceDPISettingsExecuting,
    scaleAutomationID: String?
  ) throws {
    try GuestSurfaceDPISettingsResult.validateControlID(scaleAutomationID)
    self.base = base
    self.settings = settings
    self.scaleAutomationID = scaleAutomationID
  }

  public func discoverScaleControls(
    configuration: RuntimeGuestConfiguration
  ) async throws -> GuestSurfaceDPISettingsResult {
    try await settings.execute(
      .discover, percent: 100, scaleAutomationID: nil, configuration: configuration)
  }

  public func queryGuestDisplayMode(
    configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplayMode {
    let snapshot = try await queryGuestDisplaySnapshot(configuration: configuration)
    return snapshot.appliedMode
  }

  public func queryGuestDisplaySnapshot(
    configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    let snapshot = try await base.queryGuestDisplaySnapshot(configuration: configuration)
    let dpi = try await settings.execute(
      .query, percent: 100, scaleAutomationID: nil, configuration: configuration)
    guard let percent = dpi.currentPercent else { throw GuestSurfaceDPIError.invalidResponse }
    let mode = withDPI(snapshot.appliedMode, percent)
    return GuestDisplaySyncSnapshot(
      previousMode: mode, appliedMode: mode, displayDeviceName: snapshot.displayDeviceName)
  }

  public func applyGuestDisplayMode(
    _ targetMode: GuestDisplayMode, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    let baseline = try await queryGuestDisplaySnapshot(configuration: configuration)
    do {
      let snapshot = try await base.applyGuestDisplayMode(targetMode, configuration: configuration)
      let operation: GuestSurfaceDPISettingsOperation =
        targetMode.dpiScalePercent != baseline.previousMode.dpiScalePercent && scaleAutomationID != nil
        ? .apply : .query
      let dpi = try await settings.execute(
        operation, percent: targetMode.dpiScalePercent, scaleAutomationID: scaleAutomationID,
        configuration: configuration)
      guard let percent = dpi.currentPercent else { throw GuestSurfaceDPIError.invalidResponse }
      if operation == .apply, percent != targetMode.dpiScalePercent {
        throw GuestSurfaceDPIError.invalidResponse
      }
      let status: GuestDisplayDPIStatus =
        percent != targetMode.dpiScalePercent ? .unsupported : (operation == .apply ? .applied : .unchanged)
      return GuestDisplaySyncSnapshot(
        previousMode: baseline.previousMode, appliedMode: withDPI(snapshot.appliedMode, percent),
        displayDeviceName: snapshot.displayDeviceName, dpiSynchronizationStatus: status)
    } catch {
      let cleanup = Task {
        try await UTMGuestOperationDeadline.$value.withValue(nil) {
          _ = try await self.restoreGuestDisplayMode(baseline, configuration: configuration)
        }
      }
      do { try await cleanup.value } catch { throw GuestSurfaceDPIError.restoreMismatch }
      throw error
    }
  }

  public func restoreGuestDisplayMode(
    _ snapshot: GuestDisplaySyncSnapshot, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplayMode {
    var dpiVerified = false
    do {
      let dpi = try await settings.execute(
        .restore, percent: 100, scaleAutomationID: scaleAutomationID,
        configuration: configuration)
      dpiVerified = dpi.currentPercent == snapshot.previousMode.dpiScalePercent
    } catch {
      // Resolution recovery must still run if Settings recovery cannot be confirmed.
      dpiVerified = false
    }
    let restored = try await base.restoreGuestDisplayMode(snapshot, configuration: configuration)
    guard dpiVerified, restored == snapshot.previousMode else {
      throw GuestSurfaceDPIError.restoreMismatch
    }
    return restored
  }

  private func withDPI(_ mode: GuestDisplayMode, _ percent: Int) -> GuestDisplayMode {
    GuestDisplayMode(
      width: mode.width, height: mode.height, refreshRateHz: mode.refreshRateHz,
      dpiScalePercent: percent)
  }
}
