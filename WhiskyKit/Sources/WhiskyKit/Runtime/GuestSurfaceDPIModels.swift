// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

public enum GuestSurfaceDPISettingsOperation: String, Sendable {
  case query = "Query"
  case discover = "Discover"
  case apply = "Apply"
  case restore = "Restore"
  case roundTrip = "RoundTrip"
}

public enum GuestSurfaceDPIError: Error, Equatable, Sendable {
  case invalidControlID, invalidResponse, invalidPercent, controlDiscoveryRequired
  case operationFailed(String)
  case restoreMismatch
}

public struct GuestSurfaceDPIScaleControl: Decodable, Equatable, Sendable {
  public let automationID: String
  public let selectedPercent: Int?
  public let enabled: Bool
  public let ownerMatches: Bool

  enum CodingKeys: String, CodingKey {
    case automationID = "automation_id"
    case selectedPercent = "selected_percent"
    case enabled
    case ownerMatches = "owner_matches"
  }
}

public struct GuestSurfaceDPISettingsResult: Decodable, Equatable, Sendable {
  public let owner: String
  public let schemaVersion: Int
  public let mode: String
  public let executed: Bool
  public let succeeded: Bool
  public let currentPercent: Int?
  public let baselinePercent: Int?
  public let appliedPercent: Int?
  public let restoredPercent: Int?
  public let restoreRequired: Bool
  public let restoreVerified: Bool?
  public let settingsWindowClosed: Bool?
  public let errorCode: String?
  public let controls: [GuestSurfaceDPIScaleControl]

  enum CodingKeys: String, CodingKey {
    case owner, mode, executed, succeeded, controls
    case schemaVersion = "schema_version"
    case currentPercent = "current_percent"
    case baselinePercent = "baseline_percent"
    case appliedPercent = "applied_percent"
    case restoredPercent = "restored_percent"
    case restoreRequired = "restore_required"
    case restoreVerified = "restore_verified"
    case settingsWindowClosed = "settings_window_closed"
    case errorCode = "error_code"
  }

  static let supportedPercents: Set<Int> = [100, 125, 150, 175, 200, 225, 250, 300]

  static func validateControlID(_ value: String?) throws {
    guard let value else { return }
    guard value.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil else {
      throw GuestSurfaceDPIError.invalidControlID
    }
  }

  static func decode(
    _ data: Data, operation: GuestSurfaceDPISettingsOperation
  ) throws -> GuestSurfaceDPISettingsResult {
    guard data.count <= 65536,
      let result = try? JSONDecoder().decode(Self.self, from: data),
      result.owner == "@DNPMBHC", result.schemaVersion == 1, result.mode == operation.rawValue,
      result.controls.count <= 40
    else { throw GuestSurfaceDPIError.invalidResponse }
    let percents = [result.currentPercent, result.baselinePercent, result.appliedPercent, result.restoredPercent]
      .compactMap { $0 }
    for value in percents {
      guard (100...300).contains(value) else { throw GuestSurfaceDPIError.invalidResponse }
    }
    try validateControls(result.controls)
    if let code = result.errorCode {
      guard code.range(of: #"^[a-z0-9_]{1,80}$"#, options: .regularExpression) != nil else {
        throw GuestSurfaceDPIError.invalidResponse
      }
    }
    guard result.succeeded, result.executed, result.currentPercent != nil else {
      throw GuestSurfaceDPIError.operationFailed(result.errorCode ?? "settings_operation_failed")
    }
    try validateOperation(result, operation: operation)
    return result
  }
  private static func validateControls(_ controls: [GuestSurfaceDPIScaleControl]) throws {
    for control in controls {
      if control.automationID != "[unavailable]" { try validateControlID(control.automationID) }
      if let percent = control.selectedPercent, !supportedPercents.contains(percent) {
        throw GuestSurfaceDPIError.invalidResponse
      }
    }
  }

  private static func validateOperation(
    _ result: Self, operation: GuestSurfaceDPISettingsOperation
  ) throws {
    switch operation {
    case .query: break
    case .discover:
      guard result.settingsWindowClosed == true else { throw GuestSurfaceDPIError.invalidResponse }
    case .apply:
      guard result.settingsWindowClosed == true, result.appliedPercent == result.currentPercent,
        result.baselinePercent != nil,
        result.baselinePercent == result.currentPercent || result.restoreRequired
      else { throw GuestSurfaceDPIError.invalidResponse }
    case .restore:
      guard result.restoreVerified == true, result.restoredPercent == result.currentPercent else {
        throw GuestSurfaceDPIError.restoreMismatch
      }
    case .roundTrip:
      guard result.restoreVerified == true, result.settingsWindowClosed == true,
        result.restoredPercent == result.currentPercent, result.baselinePercent == result.currentPercent
      else { throw GuestSurfaceDPIError.restoreMismatch }
    }
  }

}

protocol GuestSurfaceDPISettingsExecuting: Sendable {
  func execute(
    _ operation: GuestSurfaceDPISettingsOperation, percent: Int,
    scaleAutomationID: String?, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestSurfaceDPISettingsResult
}
