// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import ModuleC

extension GuestRuntimeProbe {
  static func probe(_ input: ProbeInput) async throws -> ProbeProcessReport {
    let helper = WindowsGuestInteractiveConfiguration(
      helperURL: input.helperURL, guestHelperPath: input.guestHelperPath)
    let provider = UTMWindowsGuestProvider(
      configuration: input.configuration, executionMode: .interactiveDesktop,
      interactiveConfiguration: helper)
    let request = RuntimeLaunchRequest(
      executableURL: input.executableURL, bottle: nil, arguments: input.arguments,
      selection: .ordinary, backend: .windowsGuest, guestConfiguration: input.configuration,
      guestExecutionMode: .interactiveDesktop)
    let session = try await provider.startInteractive(request)
    let watchdog = Task {
      do {
        try await Task.sleep(for: .seconds(input.timeoutSeconds))
        await session.cancel()
      } catch {}
    }
    defer { watchdog.cancel() }
    let exit = try await session.wait()
    let final = try await session.latestSnapshot()
    return ProbeProcessReport(
      sessionID: final.sessionID, exitCode: exit.status, rootExitCode: final.rootExitCode,
      activeProcessCount: final.activeProcessCount, cancelled: final.cancelled,
      passed: final.sessionID == 1 && final.rootExitCode == 0 && final.activeProcessCount == 0
        && !final.cancelled && exit.status == 0)
  }

  static func dpiRoundTrip(_ input: ProbeInput) async throws -> ProbeDPIRoundTrip {
    let helper = WindowsGuestInteractiveConfiguration(
      helperURL: input.helperURL, guestHelperPath: input.guestHelperPath)
    let provider = UTMWindowsGuestProvider(
      configuration: input.configuration, executionMode: .interactiveDesktop,
      interactiveConfiguration: helper)
    let display = try GuestSurfaceDPIAwareDisplaySync(
      provider: provider, scaleAutomationID: input.scaleAutomationID)
    let baseline = try await display.queryGuestDisplaySnapshot(configuration: input.configuration)
    let journal = ProbeJournal(
      owner: "@DNPMBHC", configurationID: input.configuration.identifier,
      baseline: baseline, restoreVerified: false)
    try save(journal, at: input.journalURL)
    do {
      let target = GuestDisplayMode(width: 1920, height: 1200, refreshRateHz: 120, dpiScalePercent: 150)
      let applied = try await display.applyGuestDisplayMode(target, configuration: input.configuration)
      let restored = try await display.restoreGuestDisplayMode(applied, configuration: input.configuration)
      var finalJournal = journal
      finalJournal.restoreVerified = restored == baseline.previousMode
      try save(finalJournal, at: input.journalURL)
      return ProbeDPIRoundTrip(
        snapshot: applied, restored: restored,
        passed: applied.dpiSynchronizationStatus == .applied && applied.appliedMode.dpiScalePercent == 150
          && restored == baseline.previousMode)
    } catch {
      let restored = try await display.restoreGuestDisplayMode(baseline, configuration: input.configuration)
      var finalJournal = journal
      finalJournal.restoreVerified = restored == baseline.previousMode
      try save(finalJournal, at: input.journalURL)
      throw error
    }
  }

  static func runAll(
    _ input: ProbeInput, provider: UTMWindowsGuestProvider,
    display: GuestSurfaceDPIAwareDisplaySync, host: HostDisplayDescriptor, baseline: GuestDisplaySyncSnapshot
  ) async throws -> ([ProbeRun], [ProbeFailure]) {
    var runs: [ProbeRun] = []
    var failures: [ProbeFailure] = []
    let presets: [GuestDisplayResolutionPreset] =
      input.operation == "supportedLifecycle"
      ? [.followWindow] : GuestDisplayResolutionPreset.allCases
    for preset in presets {
      do {
        let run = try await runOne(input, provider: provider, display: display, host: host, preset: preset)
        runs.append(run)
        guard run.displayRestored, run.state == GuestSurfaceSessionState.finished.rawValue,
          run.exitReason == RuntimeExitReason.exit.rawValue, run.exitCode == 0
        else { throw ProbeError.sessionIncomplete }
      } catch {
        guard let baseline = Optional(baseline) else { throw ProbeError.baselineMismatch }
        let restored = try await display.restoreGuestDisplayMode(baseline, configuration: input.configuration)
        guard restored == baseline.previousMode else { throw ProbeError.baselineMismatch }
        failures.append(ProbeFailure(preset: preset, errorCode: code(error), baselineRestored: true))
      }
    }
    return (runs, failures)
  }
}
