// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import AppKit
import Foundation
import ModuleC

struct ProbeInput: Decodable {
  let configuration: RuntimeGuestConfiguration
  let executableURL: URL
  let helperURL: URL
  let guestHelperPath: String
  let arguments: [String]
  let journalURL: URL
  let timeoutSeconds: Int
  let scaleAutomationID: String?
  let operation: String?
  let dynamicWindowWidth: Int?
  let dynamicWindowHeight: Int?
}

private struct ProbeScaleControl: Encodable {
  let automationID: String
  let selectedPercent: Int?
  let enabled: Bool
  let ownerMatches: Bool
}

private struct ProbeDiscovery: Encodable {
  let owner = "@DNPMBHC"
  let scope = "actual_session_one_standard_settings_control_discovery"
  let currentPercent: Int?
  let settingsWindowClosed: Bool?
  let controls: [ProbeScaleControl]
  let passed: Bool
}

struct ProbeProcessReport: Encodable {
  let owner = "@DNPMBHC"
  let scope = "actual_session_one_frozen_d3d_probe"
  let sessionID: UInt32
  let exitCode: Int32
  let rootExitCode: Int32?
  let activeProcessCount: UInt32
  let cancelled: Bool
  let passed: Bool
}

struct ProbeJournal: Codable {
  let owner: String
  let configurationID: String
  let baseline: GuestDisplaySyncSnapshot
  var restoreVerified: Bool
}

struct ProbeRun: Encodable {
  let preset: GuestDisplayResolutionPreset
  let requestedMode: GuestDisplayMode
  let actualMode: GuestDisplayMode
  let snapshot: GuestDisplaySyncSnapshot?
  let state: String
  let exitCode: Int32
  let rootExitCode: Int32?
  let exitReason: String
  let displayRestored: Bool
  let guestSuspendedOnExit: Bool
  let frameCount: UInt64
  let liveWindowMode: GuestDisplayMode?
  let dynamicWindowFollowVerified: Bool
}

struct ProbeFailure: Encodable {
  let preset: GuestDisplayResolutionPreset
  let errorCode: String
  let baselineRestored: Bool
}

struct ProbeDPIRoundTrip: Encodable {
  let owner = "@DNPMBHC"
  let scope = "actual_supported_mode_dpi_apply_and_restore"
  let snapshot: GuestDisplaySyncSnapshot
  let restored: GuestDisplayMode
  let passed: Bool
}

private struct ProbeReport: Encodable {
  let owner = "@DNPMBHC"
  var scope = "headless_guest_display_and_lifecycle_only"
  var coldHeadlessStartVerified = false
  let nativeGuestScanoutVerified = false
  let virtualHIDVerified = false
  let targetGameVerified = false
  let systemDPIScalingImplemented = true
  let hostDisplay: HostDisplayDescriptor
  var runs: [ProbeRun] = []
  var failures: [ProbeFailure] = []
  var baselineRestored = false
  var passed = false
  var errorCode: String?
}

enum ProbeError: Error {
  case guardedExecutionRequired, invalidInput, pendingRecoveryJournal, baselineMismatch
  case sessionIncomplete, hiddenPreparedGuestRequired
}

@main
struct GuestRuntimeProbe {
  static func main() async {
    do {
      guard CommandLine.arguments.dropFirst().elementsEqual(["--guarded-execution"]),
        let permit = ProcessInfo.processInfo.environment["GUEST_SHELL_EXECUTION_PERMIT"],
        UUID(uuidString: permit) != nil
      else { throw ProbeError.guardedExecutionRequired }
      let inputData = FileHandle.standardInput.readDataToEndOfFile()
      guard inputData.count <= 65536 else { throw ProbeError.invalidInput }
      let input = try JSONDecoder().decode(ProbeInput.self, from: inputData)
      try validate(input)
      if input.operation == "discover" {
        try emit(try await discover(input))
        exit(0)
      }
      if input.operation == "fingerprint" {
        let result = try await probe(input)
        try emit(result)
        exit(result.passed ? 0 : 1)
      }
      if input.operation == "dpiRoundTrip" {
        let result = try await dpiRoundTrip(input)
        try emit(result)
        exit(result.passed ? 0 : 1)
      }
      guard input.operation == nil || input.operation == "supportedLifecycle" else { throw ProbeError.invalidInput }
      let initialStatus = try inspectedGuestStatus(input.configuration.identifier)
      var report = await execute(input)
      report.coldHeadlessStartVerified = initialStatus == "stopped" && report.passed
      try emit(report)
      exit(report.passed ? 0 : 1)
    } catch {
      let response = ["owner": "@DNPMBHC", "errorCode": code(error)]
      let data = (try? JSONEncoder().encode(response)) ?? Data()
      FileHandle.standardOutput.write(data + Data([10]))
      exit(1)
    }
  }

  private static func validate(_ input: ProbeInput) throws {
    guard UUID(uuidString: input.configuration.identifier) != nil,
      input.configuration.architecture == "aarch64",
      (10...600).contains(input.timeoutSeconds), input.arguments.count <= 256,
      input.executableURL.isFileURL, input.helperURL.isFileURL, input.journalURL.isFileURL,
      input.journalURL.pathExtension == "json",
      !input.configuration.fileMappings.isEmpty
    else { throw ProbeError.invalidInput }
    if FileManager.default.fileExists(atPath: input.journalURL.path) {
      let journal = try JSONDecoder().decode(
        ProbeJournal.self, from: Data(contentsOf: input.journalURL))
      guard journal.owner == "@DNPMBHC", journal.configurationID == input.configuration.identifier,
        journal.restoreVerified
      else {
        throw ProbeError.pendingRecoveryJournal
      }
    }
  }

  private static func discover(_ input: ProbeInput) async throws -> ProbeDiscovery {
    let helper = WindowsGuestInteractiveConfiguration(
      helperURL: input.helperURL, guestHelperPath: input.guestHelperPath)
    let provider = UTMWindowsGuestProvider(
      configuration: input.configuration, executionMode: .interactiveDesktop,
      interactiveConfiguration: helper)
    let display = try GuestSurfaceDPIAwareDisplaySync(provider: provider)
    let result = try await display.discoverScaleControls(configuration: input.configuration)
    return ProbeDiscovery(
      currentPercent: result.currentPercent, settingsWindowClosed: result.settingsWindowClosed,
      controls: result.controls.map {
        ProbeScaleControl(
          automationID: $0.automationID, selectedPercent: $0.selectedPercent,
          enabled: $0.enabled, ownerMatches: $0.ownerMatches)
      }, passed: result.succeeded && result.settingsWindowClosed == true)
  }

  private static func execute(_ input: ProbeInput) async -> ProbeReport {
    let host = await HostDisplayDescriptor.primaryOrFallback()
    var report = ProbeReport(hostDisplay: host)
    let helper = WindowsGuestInteractiveConfiguration(
      helperURL: input.helperURL, guestHelperPath: input.guestHelperPath)
    let provider = UTMWindowsGuestProvider(
      configuration: input.configuration, executionMode: .interactiveDesktop,
      interactiveConfiguration: helper)
    if input.operation == "supportedLifecycle" { report.scope = "supported_window_follow_headless_lifecycle_only" }
    var journal: ProbeJournal?
    do {
      let display = try GuestSurfaceDPIAwareDisplaySync(
        provider: provider, scaleAutomationID: input.scaleAutomationID)
      let baseline = try await display.queryGuestDisplaySnapshot(configuration: input.configuration)
      journal = ProbeJournal(
        owner: "@DNPMBHC", configurationID: input.configuration.identifier, baseline: baseline, restoreVerified: false)
      try save(journal, at: input.journalURL)
      let observations = try await runAll(input, provider: provider, display: display, host: host, baseline: baseline)
      report.runs = observations.0
      report.failures = observations.1
      guard let journal else { throw ProbeError.baselineMismatch }
      // The final run suspends. Querying here would resume the Guest, so compare its recorded baseline.
      guard report.runs.allSatisfy({ $0.snapshot?.previousMode == journal.baseline.previousMode }) else {
        throw ProbeError.baselineMismatch
      }
      report.baselineRestored = true
      report.passed =
        report.failures.isEmpty && report.runs.count == (input.operation == "supportedLifecycle" ? 1 : 3)
        && report.runs.last?.guestSuspendedOnExit == true
        && report.runs.last?.dynamicWindowFollowVerified == true
    } catch {
      report.errorCode = code(error)
      if let baseline = journal?.baseline {
        do {
          let display = try GuestSurfaceDPIAwareDisplaySync(
            provider: provider, scaleAutomationID: input.scaleAutomationID)
          let restored = try await display.restoreGuestDisplayMode(
            baseline, configuration: input.configuration)
          report.baselineRestored = restored == baseline.previousMode
        } catch { report.errorCode = "baseline_recovery_failed" }
      }
    }
    if var journal {
      journal.restoreVerified = report.baselineRestored
      do { try save(journal, at: input.journalURL) } catch {
        report.errorCode = "recovery_journal_write_failed"
        report.passed = false
      }
    }
    return report
  }

  private static func inspectedGuestStatus(_ identifier: String) throws -> String {
    // Read only. The runtime display wrapper performs hidden cold startup.
    let script = """
      on run argv
        with timeout of 10 seconds
          tell application id "com.utmapp.UTM"
            return status of (virtual machine id (item 1 of argv)) as text
          end tell
        end timeout
      end run
      """
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script, "--", identifier]
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
      let status = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      ["started", "paused", "stopped"].contains(status)
    else { throw ProbeError.hiddenPreparedGuestRequired }
    return status
  }

  static func runOne(
    _ input: ProbeInput, provider: UTMWindowsGuestProvider,
    display: GuestSurfaceDPIAwareDisplaySync, host: HostDisplayDescriptor, preset: GuestDisplayResolutionPreset
  ) async throws -> ProbeRun {
    let configuration = GuestSurfaceSessionConfiguration(
      resolutionPreset: preset, hostDisplay: host,
      idlePolicy: preset == .followWindow ? .suspendOnExit : .keepWarm,
      enableRawInputOnFocus: false, showOverlayHUD: false)
    // No synthetic frame source stands in for unavailable real Guest scanout.
    let session = GuestSurfaceSession(
      provider: provider, displaySync: display, configuration: configuration)
    let windowSize = CGSize(width: 1280, height: 720)
    if preset == .followWindow { await session.updateWindowPixelSize(windowSize) }
    let requested = try GuestDisplayResolutionPolicy.resolve(
      preset: preset, hostDisplay: host,
      windowPixelSize: preset == .followWindow ? windowSize : nil)
    let request = RuntimeLaunchRequest(
      executableURL: input.executableURL, bottle: nil, arguments: input.arguments,
      selection: .ordinary, backend: .windowsGuest, guestConfiguration: input.configuration,
      guestExecutionMode: .interactiveDesktop)
    let watchdog = watch(session, seconds: input.timeoutSeconds)
    let liveSize = CGSize(width: input.dynamicWindowWidth ?? 1600, height: input.dynamicWindowHeight ?? 900)
    let resize = Task { try await liveResize(session, preset: preset, size: liveSize, seconds: input.timeoutSeconds) }
    defer {
      watchdog.cancel()
      resize.cancel()
    }
    let result = try await session.run(request)
    let resized = try await resize.value
    return await ProbeRun(
      preset: preset, requestedMode: requested, actualMode: result.targetDisplayMode,
      snapshot: result.displaySnapshot, state: session.state.rawValue,
      exitCode: result.exitResult.status, rootExitCode: result.exitResult.rootExitCode,
      exitReason: result.exitResult.reason.rawValue, displayRestored: result.displayRestored,
      guestSuspendedOnExit: result.guestSuspendedOnExit, frameCount: result.framesPresented,
      liveWindowMode: resized,
      dynamicWindowFollowVerified: resized?.width == Int(liveSize.width) && resized?.height == Int(liveSize.height))
  }

  private static func liveResize(
    _ session: GuestSurfaceSession, preset: GuestDisplayResolutionPreset, size: CGSize, seconds: Int
  ) async throws -> GuestDisplayMode? {
    guard preset == .followWindow else { return nil }
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      let state = await session.state
      if state == .running {
        return try await session.synchronizeWindowPixelSize(size)
      }
      if state == .finished || state == .failed { throw ProbeError.sessionIncomplete }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ProbeError.sessionIncomplete
  }

  private static func watch(_ session: GuestSurfaceSession, seconds: Int) -> Task<Void, Never> {
    Task {
      do {
        try await Task.sleep(for: .seconds(seconds))
        await session.cancel()
      } catch {
        // Completed runs cancel only this watchdog.
      }
    }
  }

  static func save(_ journal: ProbeJournal?, at url: URL) throws {
    guard let journal else { throw ProbeError.baselineMismatch }
    try JSONEncoder().encode(journal).write(to: url, options: .atomic)
  }

  static func code(_ error: any Error) -> String {
    // Associated paths and process output are excluded from this public diagnostic envelope.
    if let error = error as? ProbeError { return String(describing: error) }
    if let error = error as? GuestDisplaySyncError { return String(describing: error) }
    if let error = error as? GuestSurfaceDPIError { return String(describing: error) }
    if let error = error as? WindowsGuestInteractiveError { return String(describing: error) }
    if let error = error as? UTMGuestError { return String(describing: error) }
    if error is CancellationError { return "cancelled" }
    return "runtime_operation_failed"
  }

  private static func emit(_ report: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
  }
}
