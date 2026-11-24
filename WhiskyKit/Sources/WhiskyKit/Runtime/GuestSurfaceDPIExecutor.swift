// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

private struct GuestDPISettingsRequest {
  let operation: GuestSurfaceDPISettingsOperation
  let percent: Int
  let scaleAutomationID: String?
  let helper: WindowsGuestInteractiveConfiguration
  let configuration: RuntimeGuestConfiguration
  let deadline: ContinuousClock.Instant
}

struct GuestSurfaceDPISettingsExecutor: GuestSurfaceDPISettingsExecuting {
  let provider: UTMWindowsGuestProvider

  func execute(
    _ operation: GuestSurfaceDPISettingsOperation, percent: Int,
    scaleAutomationID: String?, configuration config: RuntimeGuestConfiguration
  ) async throws -> GuestSurfaceDPISettingsResult {
    try GuestConfigurationValidator.validate(config)
    try GuestSurfaceDPISettingsResult.validateControlID(scaleAutomationID)
    guard GuestSurfaceDPISettingsResult.supportedPercents.contains(percent) else {
      throw GuestSurfaceDPIError.invalidPercent
    }
    if operation == .apply || operation == .roundTrip {
      guard scaleAutomationID != nil else { throw GuestSurfaceDPIError.controlDiscoveryRequired }
    }
    guard provider.installed else { throw UTMGuestError.utmNotInstalled }
    let deadline = ContinuousClock.now + .seconds(config.startupTimeoutSeconds)
    return try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      let helper = try provider.resolveInteractiveConfiguration(configuration: config)
      let initial = try await provider.transport.inspect(config.identifier)
      guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
      try provider.validate(initial, config: config)
      let launched = try await provider.prepareVM(initial, config: config, until: deadline)
      do {
        return try await run(
          GuestDPISettingsRequest(
            operation: operation, percent: percent, scaleAutomationID: scaleAutomationID,
            helper: helper, configuration: config, deadline: deadline))
      } catch {
        if launched {
          let cleanup = Task {
            try await UTMGuestOperationDeadline.$value.withValue(nil) {
              if initial.status == .paused {
                try await provider.suspendGuest(configuration: config)
              } else {
                try await provider.rollbackGuest(config.identifier)
              }
            }
          }
          do { try await cleanup.value } catch { throw UTMGuestError.rollbackFailed }
        }
        throw error
      }
    }
  }

  private func run(_ request: GuestDPISettingsRequest) async throws -> GuestSurfaceDPISettingsResult {
    let config = request.configuration
    let operation = request.operation
    let percent = request.percent
    let scaleAutomationID = request.scaleAutomationID
    let helper = request.helper
    let deadline = request.deadline
    try await provider.waitForAgent(config, until: deadline)
    let token = UUID().uuidString.lowercased()
    let localScript = FileManager.default.temporaryDirectory
      .appendingPathComponent("guest-shell-settings-\(token).ps1")
    try guestSurfaceDPISettingsScriptBody.write(to: localScript, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: localScript) }
    let guestScript = #"C:\guest-shell-lab\settings-"# + token + ".ps1"
    try await provider.ensureInteractiveHelper(helper, configuration: config, until: deadline)
    try await provider.transport.pushCreatingParentDirectory(
      config.identifier, hostURL: localScript, guestPath: guestScript,
      until: deadline, pollInterval: provider.pollInterval)
    // This local script uses process-scoped RemoteSigned; enforced and persistent policies retain precedence.
    var arguments = [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned",
      "-File", guestScript, "-Mode", operation.rawValue,
      "-DesiredPercent", String(percent), "-RuntimeManaged"
    ]
    if let scaleAutomationID { arguments += ["-ScaleAutomationId", scaleAutomationID] }
    if operation == .restore { arguments.append("-AllowMissingJournal") }
    let handle = try await provider.transport.executeInteractive(
      config.identifier,
      request: WindowsGuestInteractiveLaunchRequest(
        helperGuestPath: helper.guestHelperPath,
        executable: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#,
        arguments: arguments, environment: [:]),
      timing: WindowsGuestInteractiveTiming(deadline: deadline, pollInterval: provider.pollInterval))
    let session = WindowsGuestInteractiveSession(
      transport: provider.transport, vmID: config.identifier, handle: handle,
      interval: provider.pollInterval)
    guard handle.sessionID == 1 else {
      await session.cancel()
      throw GuestDisplaySyncError.interactiveDesktopRequired
    }
    return try await withTaskCancellationHandler {
      let exit = try await session.wait()
      let output = try await session.latestSnapshot()
      let result = try GuestSurfaceDPISettingsResult.decode(output.standardOutput, operation: operation)
      guard exit.status == 0 else { throw GuestSurfaceDPIError.invalidResponse }
      return result
    } onCancel: {
      Task { await session.cancel() }
    }
  }
}
