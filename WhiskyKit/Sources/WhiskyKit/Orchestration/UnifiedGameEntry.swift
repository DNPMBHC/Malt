// SPDX-License-Identifier: GPL-3.0-or-later
// Unified game library data models shared across Wine and Anti-Cheat VM engines.

import Foundation

/// Execution backend selected for a game entry.
public enum UnifiedEngineKind: String, Codable, CaseIterable, Sendable {
  case nativeWine
  case antiCheatVM

  public var displayName: String {
    switch self {
    case .nativeWine:
      return "原生转译模式"
    case .antiCheatVM:
      return "硬件加速容器模式"
    }
  }
}

/// Performance preset tier recommended by HardwareAutoTuner or selected by the user.
/// Converged to 3 intuitive tiers while preserving full backward compatibility with legacy JSON keys.
public enum PerformancePresetTier: String, Codable, CaseIterable, Sendable {
  case maxPerformance
  case balanced
  case lowSpecCompatible

  public var displayName: String {
    switch self {
    case .maxPerformance:
      return "最高性能"
    case .balanced:
      return "平衡"
    case .lowSpecCompatible:
      return "低配置兼容"
    }
  }

  public var isDefaultRecommended: Bool {
    self == .balanced
  }

  public static func from(rawOrLegacy value: String) -> PerformancePresetTier? {
    switch value {
    case Self.maxPerformance.rawValue, "nativeQuality":
      return .maxPerformance
    case Self.balanced.rawValue, "balancedRecommended":
      return .balanced
    case Self.lowSpecCompatible.rawValue, "competitiveHighFPS":
      return .lowSpecCompatible
    default:
      return nil
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let tier = Self.from(rawOrLegacy: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unknown PerformancePresetTier value: \(rawValue)"
      )
    }
    self = tier
  }
}

/// Unified card representation for both Wine bottle games and persistent Anti-Cheat VM games.
public struct UnifiedGameEntry: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var executablePath: String
  public var launchArguments: String?
  public var launchWorkingDirectory: String?
  public var engineKind: UnifiedEngineKind
  public var presetTier: PerformancePresetTier
  public var iconPath: String?
  public var lastPlayedAt: Date?
  public var bottleURL: URL?
  public var vmBundlePath: String?
  public var installationState: UnifiedInstallationState?
  public var inheritsGlobalPerformanceSettings: Bool?

  public init(
    id: UUID = UUID(),
    name: String,
    executablePath: String,
    launchArguments: String? = nil,
    launchWorkingDirectory: String? = nil,
    engineKind: UnifiedEngineKind,
    presetTier: PerformancePresetTier = .balanced,
    iconPath: String? = nil,
    lastPlayedAt: Date? = nil,
    bottleURL: URL? = nil,
    vmBundlePath: String? = nil,
    installationState: UnifiedInstallationState? = nil,
    inheritsGlobalPerformanceSettings: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.executablePath = executablePath
    self.launchArguments = launchArguments
    self.launchWorkingDirectory = launchWorkingDirectory
    self.engineKind = engineKind
    self.presetTier = presetTier
    self.iconPath = iconPath
    self.lastPlayedAt = lastPlayedAt
    self.bottleURL = bottleURL
    self.vmBundlePath = vmBundlePath
    self.installationState = installationState
    self.inheritsGlobalPerformanceSettings = inheritsGlobalPerformanceSettings
  }
}

/// Errors raised by UnifiedRuntimeOrchestrator during launch or installation.
public enum UnifiedOrchestrationError: LocalizedError, Equatable, Sendable {
  case missingExecutable(String)
  case missingBottleURL(String)
  case missingVMBundle(String)
  case missingInstaller(String)
  case backendUnavailable(String)
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .missingExecutable(let path):
      return "Executable not found: \(path)"
    case .missingBottleURL(let name):
      return "Wine bottle URL missing for game: \(name)"
    case .missingVMBundle(let path):
      return "Container VM bundle not found: \(path)"
    case .missingInstaller(let path):
      return "Installer not found: \(path)"
    case .backendUnavailable(let detail):
      return "Runtime backend unavailable: \(detail)"
    case .commandFailed(let detail):
      return "Runtime command failed: \(detail)"
    }
  }
}

/// Result of executing an external or embedded runtime helper command.
public struct OrchestratorCommandResult: Equatable, Sendable {
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String

  public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}
