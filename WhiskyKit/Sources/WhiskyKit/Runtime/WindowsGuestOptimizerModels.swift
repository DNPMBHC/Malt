// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

public enum WindowsGuestOptimizerAction: String, Codable, Equatable, Sendable {
  case apply
  case dryRun = "dry_run"
  case rollback
}

public struct WindowsGuestOptimizerTargetOS: Codable, Equatable, Sendable {
  public let product: String
  public let displayVersion: String
  public let minimumBuild: Int
  public let architecture: String

  enum CodingKeys: String, CodingKey {
    case product
    case displayVersion = "display_version"
    case minimumBuild = "minimum_build"
    case architecture
  }
}

public struct WindowsGuestOptimizerCompliance: Codable, Equatable, Sendable {
  public let forbidVirtualizationHiding: Bool
  public let forbidHardwareSpoofing: Bool
  public let forbidBCDOrCIWeakening: Bool
  public let forbidKernelDriverTampering: Bool
  public let preserveOfficialSignatures: Bool

  enum CodingKeys: String, CodingKey {
    case forbidVirtualizationHiding = "forbid_virtualization_hiding"
    case forbidHardwareSpoofing = "forbid_hardware_spoofing"
    case forbidBCDOrCIWeakening = "forbid_bcd_or_ci_weakening"
    case forbidKernelDriverTampering = "forbid_kernel_driver_tampering"
    case preserveOfficialSignatures = "preserve_official_signatures"
  }
}

public struct WindowsGuestOptimizerAllowlist: Codable, Equatable, Sendable {
  public let services: [String]
  public let prismFiles: [String]
  public let appxPrefixes: [String]
  public let taskPrefixes: [String]
  public let securityInvariants: [String]

  enum CodingKeys: String, CodingKey {
    case services
    case prismFiles = "prism_files"
    case appxPrefixes = "appx_prefixes"
    case taskPrefixes = "task_prefixes"
    case securityInvariants = "security_invariants"
  }
}

public struct WindowsGuestOptimizerServiceTarget: Codable, Equatable, Sendable {
  public let name: String
  public let targetStartType: String
  public let stopRunning: Bool
  public let reason: String

  enum CodingKeys: String, CodingKey {
    case name
    case targetStartType = "target_start_type"
    case stopRunning = "stop_running"
    case reason
  }
}

public struct WindowsGuestOptimizerScheduledTaskTarget: Codable, Equatable, Sendable {
  public let taskPath: String
  public let taskName: String
  public let reason: String

  enum CodingKeys: String, CodingKey {
    case taskPath = "task_path"
    case taskName = "task_name"
    case reason
  }
}

public struct WindowsGuestOptimizerRegistryTweak: Codable, Equatable, Sendable {
  public let path: String
  public let name: String
  public let kind: String
  public let reason: String
}

public struct WindowsGuestOptimizerPruningTargets: Codable, Equatable, Sendable {
  public let services: [WindowsGuestOptimizerServiceTarget]
  public let scheduledTasks: [WindowsGuestOptimizerScheduledTaskTarget]
  public let uwpPackages: [String]
  public let registryTweaks: [WindowsGuestOptimizerRegistryTweak]

  enum CodingKeys: String, CodingKey {
    case services
    case scheduledTasks = "scheduled_tasks"
    case uwpPackages = "uwp_packages"
    case registryTweaks = "registry_tweaks"
  }
}

public struct WindowsGuestOptimizerProfile: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let profileID: String
  public let owner: String
  public let targetOS: WindowsGuestOptimizerTargetOS
  public let compliance: WindowsGuestOptimizerCompliance
  public let protectedAllowlist: WindowsGuestOptimizerAllowlist
  public let pruningTargets: WindowsGuestOptimizerPruningTargets

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case profileID = "profile_id"
    case owner
    case targetOS = "target_os"
    case compliance
    case protectedAllowlist = "protected_whitelist"
    case pruningTargets = "optimization_blacklist"
  }
}

public enum WindowsGuestOptimizerValidationError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(Int)
  case invalidTargetOS
  case complianceRequirementDisabled(String)
  case missingCoreAllowlistEntries
  case missingPrismProtection
  case protectedServiceInPruningTargets(String)
  case duplicatePruningService(String)
  case invalidServiceStartType(String)
  case protectedUWPPackageInPruningTargets(String)
  case protectedScheduledTaskInPruningTargets(String)
  case unsafeRegistryScope(String)
  case unsupportedRegistryKind(String)
}

public enum WindowsGuestOptimizerProfileValidator {
  public static let hardProtectedServices: Set<String> = [
    "bfe", "coremessagingregistrar", "cryptsvc", "dcomlaunch", "dhcp", "dnscache",
    "eventlog", "keyiso", "lsm", "mpssvc", "netman", "nlasvc", "nsi", "plugplay",
    "power", "qemu-ga", "rpceptmapper", "rpcss", "samss", "schedule",
    "securityhealthservice", "sense", "systemeventsbroker", "tbs",
    "trustedinstaller", "usermanager", "vaultsvc", "virtiofssvc", "windefend",
    "winmgmt", "audiosrv", "audioendpointbuilder", "wuauserv",
    "vgc", "vgk", "ace-base", "ace-game", "anticheatexpert service",
    "anticheatexpert protection", "easyanticheat", "easyanticheat_eos", "beservice"
  ]

  public static let requiredPrismFiles: Set<String> = [
    #"system32\xtajit.dll"#,
    #"system32\xtajit64.dll"#,
    #"system32\wow64.dll"#,
    #"system32\wow64win.dll"#
  ]

  public static let hardProtectedAppxPrefixes: [String] = [
    "microsoft.vclibs", "microsoft.ui.xaml", "microsoft.net", "microsoft.directx",
    "microsoft.windows.shellexperiencehost", "microsoft.windows.startmenuexperiencehost",
    "microsoft.windows.sechealthui", "microsoft.aad.brokerplugin",
    "microsoft.accountscontrol", "microsoft.lockapp", "microsoft.desktopappinstaller",
    "microsoft.services.store.engagement", "microsoft.storepurchaseapp",
    "microsoft.windowsstore"
  ]

  public static let hardProtectedTaskPrefixes: [String] = [
    #"\microsoft\windows\windows defender\"#,
    #"\microsoft\windows\tpm\"#,
    #"\microsoft\windows\device information\"#,
    #"\microsoft\windows\certificateservicesclient\"#,
    #"\microsoft\windows\servicing\"#,
    #"\microsoft\windows\taskscheduler\"#
  ]

  private static let forbiddenRegistryTokens = [
    "deviceguard", "codeintegrity", "lsa", #"policies\system"#, "currentcontrolset"
  ]

  public static func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func validate(_ profile: WindowsGuestOptimizerProfile) throws {
    guard profile.schemaVersion == 1 else {
      throw WindowsGuestOptimizerValidationError.unsupportedSchemaVersion(profile.schemaVersion)
    }
    guard profile.targetOS.architecture.uppercased() == "ARM64",
      profile.targetOS.displayVersion.uppercased() == "24H2",
      profile.targetOS.minimumBuild >= 26100
    else {
      throw WindowsGuestOptimizerValidationError.invalidTargetOS
    }
    try validateCompliance(profile.compliance)
    try validateAllowlist(profile.protectedAllowlist)
    try validateServices(profile.pruningTargets.services, allowlist: profile.protectedAllowlist)
    try validateUWPPackages(profile.pruningTargets.uwpPackages, allowlist: profile.protectedAllowlist)
    try validateTasks(profile.pruningTargets.scheduledTasks, allowlist: profile.protectedAllowlist)
    try validateRegistryTweaks(profile.pruningTargets.registryTweaks)
  }

  private static func validateCompliance(_ compliance: WindowsGuestOptimizerCompliance) throws {
    let flags: [(String, Bool)] = [
      ("forbid_virtualization_hiding", compliance.forbidVirtualizationHiding),
      ("forbid_hardware_spoofing", compliance.forbidHardwareSpoofing),
      ("forbid_bcd_or_ci_weakening", compliance.forbidBCDOrCIWeakening),
      ("forbid_kernel_driver_tampering", compliance.forbidKernelDriverTampering),
      ("preserve_official_signatures", compliance.preserveOfficialSignatures)
    ]
    for (name, enabled) in flags where !enabled {
      throw WindowsGuestOptimizerValidationError.complianceRequirementDisabled(name)
    }
  }

  private static func validateAllowlist(_ allowlist: WindowsGuestOptimizerAllowlist) throws {
    let declaredServices = Set(allowlist.services.map { $0.lowercased() })
    guard hardProtectedServices.isSubset(of: declaredServices) else {
      throw WindowsGuestOptimizerValidationError.missingCoreAllowlistEntries
    }
    let declaredPrism = Set(allowlist.prismFiles.map { $0.lowercased() })
    guard requiredPrismFiles.isSubset(of: declaredPrism) else {
      throw WindowsGuestOptimizerValidationError.missingPrismProtection
    }
  }

  private static func validateServices(
    _ services: [WindowsGuestOptimizerServiceTarget],
    allowlist: WindowsGuestOptimizerAllowlist
  ) throws {
    let protectedServices = hardProtectedServices.union(allowlist.services.map { $0.lowercased() })
    var seenServices: Set<String> = []
    for entry in services {
      let lowered = entry.name.lowercased()
      if protectedServices.contains(lowered) {
        throw WindowsGuestOptimizerValidationError.protectedServiceInPruningTargets(entry.name)
      }
      if !seenServices.insert(lowered).inserted {
        throw WindowsGuestOptimizerValidationError.duplicatePruningService(entry.name)
      }
      guard entry.targetStartType == "Disabled" || entry.targetStartType == "Manual" else {
        throw WindowsGuestOptimizerValidationError.invalidServiceStartType(entry.targetStartType)
      }
    }
  }

  private static func validateUWPPackages(
    _ packages: [String],
    allowlist: WindowsGuestOptimizerAllowlist
  ) throws {
    let protectedAppx = hardProtectedAppxPrefixes + allowlist.appxPrefixes.map { $0.lowercased() }
    for pkg in packages {
      let lowered = pkg.lowercased()
      if protectedAppx.contains(where: { lowered.hasPrefix($0) }) {
        throw WindowsGuestOptimizerValidationError.protectedUWPPackageInPruningTargets(pkg)
      }
    }
  }

  private static func validateTasks(
    _ tasks: [WindowsGuestOptimizerScheduledTaskTarget],
    allowlist: WindowsGuestOptimizerAllowlist
  ) throws {
    let protectedTasks = hardProtectedTaskPrefixes + allowlist.taskPrefixes.map { $0.lowercased() }
    for task in tasks {
      let fullPath = (task.taskPath + task.taskName).lowercased()
      if protectedTasks.contains(where: { fullPath.hasPrefix($0) }) {
        throw WindowsGuestOptimizerValidationError.protectedScheduledTaskInPruningTargets(
          task.taskPath + task.taskName
        )
      }
    }
  }

  private static func validateRegistryTweaks(
    _ tweaks: [WindowsGuestOptimizerRegistryTweak]
  ) throws {
    for tweak in tweaks {
      let loweredPath = tweak.path.lowercased()
      guard loweredPath.hasPrefix(#"hkcu:\"#),
        !forbiddenRegistryTokens.contains(where: { loweredPath.contains($0) })
      else {
        throw WindowsGuestOptimizerValidationError.unsafeRegistryScope(tweak.path)
      }
      guard tweak.kind == "DWord" || tweak.kind == "String" || tweak.kind == "QWord" else {
        throw WindowsGuestOptimizerValidationError.unsupportedRegistryKind(tweak.kind)
      }
    }
  }
}

public struct WindowsGuestOptimizerSecurityInvariants: Codable, Equatable, Sendable {
  public let secureBootEnabled: Bool
  public let tpmPresent: Bool
  public let tpmEnabled: Bool
  public let bcdSafe: Bool
  public let prismFilesVerified: Bool
  public let prismSignaturesValid: Bool
  public let qgaServiceRunning: Bool

  enum CodingKeys: String, CodingKey {
    case secureBootEnabled = "secure_boot_enabled"
    case tpmPresent = "tpm_present"
    case tpmEnabled = "tpm_enabled"
    case bcdSafe = "bcd_safe"
    case prismFilesVerified = "prism_files_verified"
    case prismSignaturesValid = "prism_signatures_valid"
    case qgaServiceRunning = "qga_service_running"
  }
}

public struct WindowsGuestOptimizerMetrics: Codable, Equatable, Sendable {
  public let processCount: Int
  public let runningServiceCount: Int
  public let systemDriveTotalBytes: Int64
  public let systemDriveUsedBytes: Int64
  public let systemDriveFreeBytes: Int64

  enum CodingKeys: String, CodingKey {
    case processCount = "process_count"
    case runningServiceCount = "running_service_count"
    case systemDriveTotalBytes = "system_drive_total_bytes"
    case systemDriveUsedBytes = "system_drive_used_bytes"
    case systemDriveFreeBytes = "system_drive_free_bytes"
  }
}

public struct WindowsGuestOptimizerReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let owner: String
  public let action: WindowsGuestOptimizerAction
  public let capturedAtUTC: String
  public let profileID: String
  public let profileSHA256: String
  public let scriptSHA256: String
  public let snapshotReused: Bool?
  public let allowlistGuardPassed: Bool?
  public let rollbackConsistent: Bool?
  public let mismatchCount: Int?
  public let securityInvariantsPassed: Bool
  public let securityInvariants: WindowsGuestOptimizerSecurityInvariants
  public let metricsBefore: WindowsGuestOptimizerMetrics?
  public let metricsAfter: WindowsGuestOptimizerMetrics

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case owner
    case action
    case capturedAtUTC = "captured_at_utc"
    case profileID = "profile_id"
    case profileSHA256 = "profile_sha256"
    case scriptSHA256 = "script_sha256"
    case snapshotReused = "snapshot_reused"
    case allowlistGuardPassed = "whitelist_guard_passed"
    case rollbackConsistent = "rollback_consistent"
    case mismatchCount = "mismatch_count"
    case securityInvariantsPassed = "security_invariants_passed"
    case securityInvariants = "security_invariants"
    case metricsBefore = "metrics_before"
    case metricsAfter = "metrics_after"
  }
}
