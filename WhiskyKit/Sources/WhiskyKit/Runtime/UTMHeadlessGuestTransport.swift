// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Keeps VM control behind the runtime boundary without activating a VM display window.
struct UTMHeadlessGuestTransport: UTMGuestTransport {
  let base: any UTMGuestTransport

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    try await base.inspect(identifier)
  }

  func start(_ identifier: String) async throws {
    guard
      let application = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.utmapp.UTM"
      )
    else { throw UTMGuestError.utmNotInstalled }
    let executable = application.appendingPathComponent("Contents/MacOS/utmctl")
    let result = try await UTMHostProcessRunner.run(
      executable: executable, arguments: ["start", "--hide", identifier],
      until: UTMGuestOperationDeadline.value ?? (.now + .seconds(60)), maximumOutputBytes: 65536
    )
    guard result.terminationReason == .exit, result.terminationStatus == 0 else {
      throw UTMGuestError.automationFailed
    }
  }

  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {
    try await base.push(identifier, hostURL: hostURL, guestPath: guestPath)
  }

  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    try await base.execute(
      identifier, executable: executable, arguments: arguments, environment: environment)
  }

  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    try await base.result(identifier, pid: pid)
  }

  func terminate(_ identifier: String, pid: Int32) async throws {
    try await base.terminate(identifier, pid: pid)
  }

  func stop(_ identifier: String) async throws { try await base.stop(identifier) }

  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    let authenticatedOutput = arguments.count == 2 && ["status", "cancel", "force-cancel"].contains(arguments[0])
    if base is UTMAppleScriptTransport, authenticatedOutput {
      return try await UTMGuestCommandBridge.authenticatedOutput(
        identifier, executable: executable, arguments: arguments, until: deadline)
    }
    return try await base.collectOutput(
      identifier, executable: executable, arguments: arguments,
      until: deadline, pollInterval: pollInterval)
  }

  func suspend(_ identifier: String) async throws {
    let script = """
      on run argv
        tell application id "com.utmapp.UTM"
          suspend (virtual machine id (item 1 of argv)) without saving
        end tell
      end run
      """
    let result = try await UTMHostProcessRunner.run(
      executable: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-e", script, "--", identifier],
      until: .now + .seconds(30), maximumOutputBytes: 65536)
    guard result.terminationReason == .exit, result.terminationStatus == 0 else {
      throw UTMGuestError.automationFailed
    }
  }
}

extension UTMWindowsGuestProvider {
  func headlessSurfaceProvider() -> UTMWindowsGuestProvider {
    let headlessTransport: any UTMGuestTransport =
      transport is UTMAppleScriptTransport ? UTMHeadlessGuestTransport(base: transport) : transport
    return UTMWindowsGuestProvider(
      configuration: configuration, transport: headlessTransport, installed: installed,
      pollInterval: pollInterval, executionMode: .interactiveDesktop,
      minimumFreeBytes: minimumFreeBytes,
      interactiveConfiguration: interactiveConfiguration)
  }

  public func suspendGuest(configuration config: RuntimeGuestConfiguration) async throws {
    try GuestConfigurationValidator.validate(config)
    let initial = try await transport.inspect(config.identifier)
    guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
    try validate(initial, config: config)
    if initial.status == .paused { return }
    guard initial.status == .started else { throw UTMGuestError.vmUnavailable }
    let headless: UTMHeadlessGuestTransport
    if let existing = transport as? UTMHeadlessGuestTransport {
      headless = existing
    } else if transport is UTMAppleScriptTransport {
      headless = UTMHeadlessGuestTransport(base: transport)
    } else {
      throw GuestSurfaceSessionError.idlePolicyUnsupported
    }
    try await headless.suspend(config.identifier)
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
      let status = try await transport.inspect(config.identifier).status
      if status == .paused { return }
      if status == .stopped { throw UTMGuestError.vmStopped }
      try await Task.sleep(for: pollInterval)
    }
    throw UTMGuestError.stopTimedOut
  }
}
