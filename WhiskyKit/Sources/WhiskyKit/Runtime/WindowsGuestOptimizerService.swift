// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public protocol WindowsGuestOptimizing: WindowsGuestProvider {
  func runGuestOptimizer(
    action: WindowsGuestOptimizerAction,
    profileURL: URL,
    scriptURL: URL,
    stateDirectory: String
  ) async throws -> Data
}

public enum WindowsGuestOptimizerServiceError: Error, Equatable, Sendable {
  case guestUnavailable(String)
  case providerDoesNotSupportOptimizer
  case unreadableArtifact(String)
  case invalidReportFormat
  case reportActionMismatch(
    expected: WindowsGuestOptimizerAction,
    actual: WindowsGuestOptimizerAction
  )
  case reportProfileDigestMismatch
  case allowlistGuardDidNotPass
  case securityInvariantsViolated
  case rollbackInconsistent(Int)
}

public struct WindowsGuestOptimizerService: Sendable {
  public static let defaultGuestStateDirectory = #"C:\graphics-lab\guest-optimizer"#

  private let provider: any WindowsGuestProvider
  private let profileURL: URL
  private let applyScriptURL: URL
  private let rollbackScriptURL: URL
  private let stateDirectory: String

  public init(
    provider: any WindowsGuestProvider,
    profileURL: URL,
    applyScriptURL: URL,
    rollbackScriptURL: URL,
    stateDirectory: String = WindowsGuestOptimizerService.defaultGuestStateDirectory
  ) {
    self.provider = provider
    self.profileURL = profileURL
    self.applyScriptURL = applyScriptURL
    self.rollbackScriptURL = rollbackScriptURL
    self.stateDirectory = stateDirectory
  }

  public func apply(dryRun: Bool = false) async throws -> WindowsGuestOptimizerReport {
    try await execute(action: dryRun ? .dryRun : .apply, scriptURL: applyScriptURL)
  }

  public func rollback() async throws -> WindowsGuestOptimizerReport {
    try await execute(action: .rollback, scriptURL: rollbackScriptURL)
  }

  private func execute(
    action: WindowsGuestOptimizerAction,
    scriptURL: URL
  ) async throws -> WindowsGuestOptimizerReport {
    guard provider.availability.isReady else {
      if case .unavailable(let reason) = provider.availability {
        throw WindowsGuestOptimizerServiceError.guestUnavailable(reason)
      }
      throw WindowsGuestOptimizerServiceError.guestUnavailable("Windows guest is not configured.")
    }
    guard let optimizerProvider = provider as? any WindowsGuestOptimizing else {
      throw WindowsGuestOptimizerServiceError.providerDoesNotSupportOptimizer
    }

    let profileData: Data
    do {
      profileData = try Data(contentsOf: profileURL)
    } catch {
      throw WindowsGuestOptimizerServiceError.unreadableArtifact(profileURL.lastPathComponent)
    }
    guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
      throw WindowsGuestOptimizerServiceError.unreadableArtifact(scriptURL.lastPathComponent)
    }

    let profile = try JSONDecoder().decode(WindowsGuestOptimizerProfile.self, from: profileData)
    try WindowsGuestOptimizerProfileValidator.validate(profile)
    let expectedDigest = WindowsGuestOptimizerProfileValidator.sha256Hex(of: profileData)

    let rawReport = try await optimizerProvider.runGuestOptimizer(
      action: action,
      profileURL: profileURL,
      scriptURL: scriptURL,
      stateDirectory: stateDirectory
    )
    return try validateReport(
      rawReport,
      expectedAction: action,
      expectedProfileID: profile.profileID,
      expectedDigest: expectedDigest
    )
  }

  private func validateReport(
    _ data: Data,
    expectedAction: WindowsGuestOptimizerAction,
    expectedProfileID: String,
    expectedDigest: String
  ) throws -> WindowsGuestOptimizerReport {
    let report: WindowsGuestOptimizerReport
    do {
      report = try JSONDecoder().decode(WindowsGuestOptimizerReport.self, from: data)
    } catch {
      throw WindowsGuestOptimizerServiceError.invalidReportFormat
    }
    guard report.schemaVersion == 1, report.profileID == expectedProfileID else {
      throw WindowsGuestOptimizerServiceError.invalidReportFormat
    }
    guard report.action == expectedAction else {
      throw WindowsGuestOptimizerServiceError.reportActionMismatch(
        expected: expectedAction, actual: report.action
      )
    }
    guard report.profileSHA256.lowercased() == expectedDigest else {
      throw WindowsGuestOptimizerServiceError.reportProfileDigestMismatch
    }
    if expectedAction != .rollback, report.allowlistGuardPassed != true {
      throw WindowsGuestOptimizerServiceError.allowlistGuardDidNotPass
    }
    let inv = report.securityInvariants
    guard report.securityInvariantsPassed,
      inv.secureBootEnabled, inv.tpmPresent, inv.tpmEnabled,
      inv.bcdSafe, inv.prismFilesVerified, inv.prismSignaturesValid, inv.qgaServiceRunning
    else {
      throw WindowsGuestOptimizerServiceError.securityInvariantsViolated
    }
    if expectedAction == .rollback, report.rollbackConsistent != true {
      throw WindowsGuestOptimizerServiceError.rollbackInconsistent(report.mismatchCount ?? 1)
    }
    return report
  }
}

extension UTMWindowsGuestProvider: WindowsGuestOptimizing {
  public func runGuestOptimizer(
    action: WindowsGuestOptimizerAction,
    profileURL: URL,
    scriptURL: URL,
    stateDirectory: String
  ) async throws -> Data {
    guard let config = configuration else {
      throw WindowsGuestOptimizerServiceError.guestUnavailable("Windows guest is not configured.")
    }
    guard installed else { throw UTMGuestError.utmNotInstalled }
    try GuestConfigurationValidator.validate(config)

    let initial = try await transport.inspect(config.identifier)
    guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
    try validate(initial, config: config)
    let deadline = ContinuousClock.now + .seconds(config.startupTimeoutSeconds)
    let launchedVM = try await prepareVM(initial, config: config, until: deadline)

    do {
      try await waitForAgent(config, until: deadline)
      let staging = OptimizerStagingRequest(
        action: action, profileURL: profileURL,
        scriptURL: scriptURL, stateDirectory: stateDirectory
      )
      let arguments = try await stageAndBuildOptimizerArguments(
        identifier: config.identifier, request: staging, until: deadline
      )
      return try await transport.collectOutput(
        config.identifier, executable: "powershell.exe", arguments: arguments,
        until: deadline, pollInterval: pollInterval
      )
    } catch {
      if launchedVM {
        do { try await rollbackGuest(config.identifier) } catch {
          throw UTMGuestError.rollbackFailed
        }
      }
      throw error
    }
  }

  private struct OptimizerStagingRequest {
    let action: WindowsGuestOptimizerAction
    let profileURL: URL
    let scriptURL: URL
    let stateDirectory: String
  }

  private func stageAndBuildOptimizerArguments(
    identifier: String,
    request: OptimizerStagingRequest,
    until deadline: ContinuousClock.Instant
  ) async throws -> [String] {
    let normalizedDir = request.stateDirectory.replacingOccurrences(of: "/", with: "\\")
    let separator = normalizedDir.hasSuffix("\\") ? "" : "\\"
    let guestProfilePath = normalizedDir + separator + request.profileURL.lastPathComponent
    let guestScriptPath = normalizedDir + separator + request.scriptURL.lastPathComponent

    try await transport.pushCreatingParentDirectory(
      identifier, hostURL: request.profileURL, guestPath: guestProfilePath,
      until: deadline, pollInterval: pollInterval
    )
    try await transport.pushCreatingParentDirectory(
      identifier, hostURL: request.scriptURL, guestPath: guestScriptPath,
      until: deadline, pollInterval: pollInterval
    )

    var arguments = [
      "-NoProfile", "-ExecutionPolicy", "Bypass",
      "-File", guestScriptPath,
      "-ProfilePath", guestProfilePath,
      "-StateDirectory", normalizedDir
    ]
    if request.action == .dryRun {
      arguments.append("-DryRun")
    }
    return arguments
  }
}
