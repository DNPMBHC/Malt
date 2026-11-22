// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// UTM provider for a configured Windows QEMU guest with the guest agent enabled.
/// UTM is selected for VM control, guest execution, PID/exit reporting, and file push via its scripting API.
/// Only the selected executable is pushed; configured directories are not copied recursively.
/// Performance and game compatibility remain unmeasured.
/// Guest CPU translation and graphics limits require workload benchmarks.
public struct UTMWindowsGuestProvider: WindowsGuestProvider {
  let configuration: RuntimeGuestConfiguration?
  let transport: any UTMGuestTransport
  let installed: Bool
  let pollInterval: Duration
  let activeGuest = UTMActiveGuest()
  private let storageStatus = UTMGuestStorageStatus()

  public init(configuration: RuntimeGuestConfiguration? = nil) {
    self.configuration = configuration
    transport = makeWindowsGuestTransport()
    installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.utmapp.UTM") != nil
    pollInterval = .milliseconds(250)
  }

  init(
    configuration: RuntimeGuestConfiguration?, transport: any UTMGuestTransport,
    installed: Bool = true, pollInterval: Duration = .milliseconds(1)
  ) {
    self.configuration = configuration
    self.transport = transport
    self.installed = installed
    self.pollInterval = pollInterval
  }

  public var storageGuestConfiguration: RuntimeGuestConfiguration? { configuration }

  public var availability: WindowsGuestAvailability {
    guard let configuration else { return .unconfigured }
    guard installed else { return .unavailable("UTM is not installed.") }
    do { try GuestConfigurationValidator.validate(configuration) } catch {
      return .unavailable("The Windows guest configuration is invalid.")
    }
    return .ready
  }

  public func preflightStorage(
    targetDirectory: URL?, installerURL: URL? = nil,
    installerBytes: Int64? = nil,
    configuration requestedConfiguration: RuntimeGuestConfiguration? = nil
  ) -> UTMGuestStoragePreflight {
    UTMGuestStoragePreflightChecker().check(
      targetDirectory: targetDirectory,
      installerURL: installerURL,
      installerBytes: installerBytes,
      configuration: requestedConfiguration ?? configuration
    )
  }

  public func latestStoragePreflight() async -> UTMGuestStoragePreflight? {
    await storageStatus.value()
  }

  public func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
    guard let config = request.guestConfiguration ?? configuration else {
      throw RuntimeLaunchError.issue(.guestUnconfigured)
    }
    guard installed else { throw UTMGuestError.utmNotInstalled }
    try GuestConfigurationValidator.validate(config)
    let program = try GuestFileMapping.resolve(request.executableURL, configuration: config)
    try GuestFileMapping.validate(arguments: request.arguments, environment: request.environment)
    let storage = preflightStorage(
      targetDirectory: program.storageDirectory,
      installerURL: program.hostURL,
      configuration: config
    )
    await storageStatus.update(storage)
    try storage.validateHostReadiness()

    let initial = try await transport.inspect(config.identifier)
    guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
    try validate(initial, config: config)
    let deadline = ContinuousClock.now + .seconds(config.startupTimeoutSeconds)
    let launchedVM = try await prepareVM(initial, config: config, until: deadline)

    do {
      try await waitForAgent(config, until: deadline)
      try await pushAndVerify(program, configuration: config, storage: storage, until: deadline)
      let pid = try await transport.execute(
        config.identifier, executable: program.guestPath,
        arguments: request.arguments, environment: request.environment)
      let session = UTMGuestSession(
        transport: transport, vmID: config.identifier, pid: pid,
        interval: pollInterval)
      return RuntimeSession(wait: { try await session.wait() }, cancel: { await session.cancel() })
    } catch {
      if launchedVM {
        try? await transport.stop(config.identifier)
        await activeGuest.clear(ifMatching: config.identifier)
      }
      throw error
    }
  }

  private func pushAndVerify(
    _ program: MappedGuestFile, configuration: RuntimeGuestConfiguration,
    storage: UTMGuestStoragePreflight, until deadline: ContinuousClock.Instant
  ) async throws {
    let identifier = configuration.identifier
    do {
      try await transport.pushCreatingParentDirectory(
        identifier, hostURL: program.hostURL, guestPath: program.guestPath,
        until: deadline, pollInterval: pollInterval)
    } catch { throw UTMGuestError.fileMappingUnavailable }
    guard try await verifyGuestFile(identifier, guestPath: program.guestPath, until: deadline)
    else {
      await storageStatus.update(storage.recordingGuestFileVisibility(.notVisible))
      throw UTMGuestError.guestFileNotVisible
    }
    let verified = storage.recordingGuestFileVisibility(.visible)
    guard verified.canExecuteGuestFile else { throw UTMGuestError.guestFileNotVisible }
    await storageStatus.update(verified)
  }

  public func launch(_ request: RuntimeLaunchRequest) async throws {
    let result = try await start(request).wait()
    if result.reason == .signal { throw RuntimeLaunchError.processSignal(result.status) }
    if result.status != 0 { throw RuntimeLaunchError.processExit(result.status) }
  }

  public func stop() async throws {
    guard let identifier = await activeGuest.get() ?? configuration?.identifier else {
      throw RuntimeLaunchError.issue(.guestUnconfigured)
    }
    if let configuration, configuration.identifier == identifier {
      try GuestConfigurationValidator.validate(configuration)
    }
    if try await transport.inspect(identifier).status == .stopped {
      await activeGuest.clear(ifMatching: identifier)
      return
    }
    try await transport.stop(identifier)
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
      if try await transport.inspect(identifier).status == .stopped {
        await activeGuest.clear(ifMatching: identifier)
        return
      }
      try await Task.sleep(for: pollInterval)
    }
    throw UTMGuestError.stopTimedOut
  }

  func prepareVM(
    _ initial: UTMVMSnapshot, config: RuntimeGuestConfiguration,
    until deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    let launchedVM = initial.status == .stopped || initial.status == .paused
    switch initial.status {
    case .started, .starting, .resuming:
      await activeGuest.set(config.identifier)
    case .stopped, .paused:
      try await transport.start(config.identifier)
      await activeGuest.set(config.identifier)
    case .pausing, .stopping, .unavailable:
      throw UTMGuestError.vmUnavailable
    }
    if initial.status != .started {
      do {
        try await waitForVM(config, until: deadline)
      } catch {
        if launchedVM { try? await transport.stop(config.identifier) }
        if launchedVM { await activeGuest.clear(ifMatching: config.identifier) }
        throw error
      }
    }

    return launchedVM
  }

  func validate(_ snapshot: UTMVMSnapshot, config: RuntimeGuestConfiguration) throws {
    guard snapshot.backend.lowercased() == "qemu" else { throw UTMGuestError.unsupportedBackend }
    guard
      RuntimeGuestConfiguration.canonicalArchitecture(snapshot.architecture)
        == RuntimeGuestConfiguration.canonicalArchitecture(config.architecture)
    else {
      throw UTMGuestError.architectureMismatch
    }
  }

  private func waitForVM(
    _ config: RuntimeGuestConfiguration, until deadline: ContinuousClock.Instant
  ) async throws {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      let snapshot = try await transport.inspect(config.identifier)
      try validate(snapshot, config: config)
      if snapshot.status == .started { return }
      if snapshot.status == .stopped { throw UTMGuestError.vmStopped }
      try await Task.sleep(for: pollInterval)
    }
    throw RuntimeLaunchError.issue(.guestTimeout)
  }

  func waitForAgent(
    _ config: RuntimeGuestConfiguration, until deadline: ContinuousClock.Instant
  ) async throws {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard try await transport.inspect(config.identifier).status == .started else {
        throw UTMGuestError.vmStopped
      }
      do {
        let pid = try await transport.execute(
          config.identifier, executable: "cmd.exe",
          arguments: ["/d", "/c", "exit", "0"], environment: [:])
        while ContinuousClock.now < deadline {
          try Task.checkCancellation()
          guard try await transport.inspect(config.identifier).status == .started else {
            throw UTMGuestError.vmStopped
          }
          if let result = try await transport.result(config.identifier, pid: pid) {
            guard result.signal == 0, result.exitCode == 0 else {
              throw UTMGuestError.agentUnavailable
            }
            return
          }
          try await Task.sleep(for: pollInterval)
        }
      } catch is CancellationError { throw CancellationError() } catch UTMGuestError.vmStopped {
        throw UTMGuestError.vmStopped
      } catch UTMGuestError.agentUnavailable { throw UTMGuestError.agentUnavailable } catch {
        // Retry while the guest agent finishes starting.
      }
      try await Task.sleep(for: pollInterval)
    }
    throw RuntimeLaunchError.issue(.guestTimeout)
  }

  private func verifyGuestFile(
    _ identifier: String, guestPath: String, until deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    let pid = try await transport.execute(
      identifier, executable: #"C:\Windows\System32\attrib.exe"#,
      arguments: ["/L", guestPath], environment: [:]
    )
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard try await transport.inspect(identifier).status == .started else {
        throw UTMGuestError.vmStopped
      }
      if let result = try await transport.result(identifier, pid: pid) {
        return result.signal == 0 && result.exitCode == 0
      }
      try await Task.sleep(for: pollInterval)
    }
    throw RuntimeLaunchError.issue(.guestTimeout)
  }
}
public enum UTMGuestError: LocalizedError, Sendable, Equatable {
  case utmNotInstalled, invalidConfiguration, architectureMismatch, unsupportedBackend
  case vmUnavailable, vmStopped, agentUnavailable, fileMappingUnavailable, unsupportedExecutable
  case invalidArguments, automationFailed, stopTimedOut, invalidResult, cancelFailed
  case storageNotWritable, insufficientHostSpace, storagePreflightUnavailable, guestFileNotVisible

  public var errorDescription: String? {
    switch self {
    case .utmNotInstalled: "UTM is not installed or cannot be automated."
    case .invalidConfiguration: "The Windows guest configuration is invalid."
    case .architectureMismatch:
      "The configured guest architecture does not match the UTM virtual machine."
    case .unsupportedBackend: "The configured virtual machine is not using UTM's QEMU backend."
    case .vmUnavailable: "The configured UTM virtual machine is unavailable."
    case .vmStopped: "The Windows guest stopped before completing the operation."
    case .agentUnavailable: "The UTM guest agent is not ready in the Windows guest."
    case .fileMappingUnavailable:
      "The selected program is outside the configured guest file mappings or cannot be read."
    case .unsupportedExecutable: "The UTM guest backend currently runs .exe and .com programs."
    case .invalidArguments: "A guest argument or environment entry is invalid."
    case .automationFailed: "UTM automation failed. Check macOS Automation permissions."
    case .stopTimedOut: "The Windows guest did not stop within the requested time."
    case .invalidResult: "UTM returned an invalid guest process result."
    case .cancelFailed: "The Windows guest could not terminate the selected program."
    case .storageNotWritable: "The selected guest storage target is not writable or creatable."
    case .insufficientHostSpace:
      "The selected guest storage target does not have enough free space."
    case .storagePreflightUnavailable: "The selected guest storage target could not be preflighted."
    case .guestFileNotVisible: "The pushed program is not visible in the Windows guest."
    }
  }
}
enum UTMVMStatus: String, Sendable {
  case stopped, starting, started, pausing, paused, resuming, stopping, unavailable
}
struct UTMVMSnapshot: Sendable {
  let identifier: String
  let backend: String
  let status: UTMVMStatus
  let architecture: String
}
struct UTMProcessResult: Sendable {
  let exitCode: Int32
  let signal: Int32
}

protocol UTMGuestTransport: Sendable {
  func inspect(_ identifier: String) async throws -> UTMVMSnapshot
  func start(_ identifier: String) async throws
  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws
  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32
  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult?
  func terminate(_ identifier: String, pid: Int32) async throws
  func stop(_ identifier: String) async throws
  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data
}
enum GuestConfigurationValidator {
  static func validate(_ config: RuntimeGuestConfiguration) throws {
    guard config.isValidForGuestProvider else { throw UTMGuestError.invalidConfiguration }
  }
}
struct MappedGuestFile {
  let hostURL: URL
  let storageDirectory: URL
  let guestPath: String
}
private enum GuestFileMapping {
  static func resolve(
    _ url: URL, configuration: RuntimeGuestConfiguration
  ) throws -> MappedGuestFile {
    guard ["exe", "com"].contains(url.pathExtension.lowercased()) else {
      throw UTMGuestError.unsupportedExecutable
    }
    let file = url.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard file.isFileURL,
      FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
      !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: file.path)
    else {
      throw UTMGuestError.fileMappingUnavailable
    }
    guard let match = configuration.guestPath(for: file, allowsMappingRoot: false) else {
      throw UTMGuestError.fileMappingUnavailable
    }
    return MappedGuestFile(hostURL: file, storageDirectory: match.directory, guestPath: match.path)
  }

  static func validate(arguments: [String], environment: [String: String]) throws {
    guard arguments.allSatisfy({ !$0.contains("\0") }),
      environment.allSatisfy({ key, value in
        !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
      })
    else { throw UTMGuestError.invalidArguments }
  }
}
enum UTMGuestResultParser {
  static func windowsStatusCode(_ value: String) throws -> Int32 {
    if let signed = Int32(value) { return signed }
    guard let raw = UInt64(value), raw <= UInt64(UInt32.max) else {
      throw UTMGuestError.invalidResult
    }
    return Int32(bitPattern: UInt32(raw))
  }
}
