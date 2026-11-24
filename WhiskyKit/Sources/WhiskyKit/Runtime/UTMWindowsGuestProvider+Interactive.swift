// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension UTMWindowsGuestProvider {
  /// Starts the selected executable on the active Windows login desktop.
  /// Background QGA control and preflight processes never stand in for the target.
  public func startInteractive(
    _ request: RuntimeLaunchRequest
  ) async throws -> WindowsGuestInteractiveSession {
    if let config = request.guestConfiguration ?? configuration {
      try GuestConfigurationValidator.validate(config)
    }
    let timeout = (request.guestConfiguration ?? configuration)?.startupTimeoutSeconds ?? 60
    let localDeadline = ContinuousClock.now + .seconds(timeout)
    let deadline = min(localDeadline, UTMGuestOperationDeadline.value ?? localDeadline)
    return try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      try await startInteractiveUnderDeadline(request)
    }
  }

  private func startInteractiveUnderDeadline(
    _ request: RuntimeLaunchRequest
  ) async throws -> WindowsGuestInteractiveSession {
    guard let config = request.guestConfiguration ?? configuration else {
      throw RuntimeLaunchError.issue(.guestUnconfigured)
    }
    guard installed else { throw UTMGuestError.utmNotInstalled }
    try GuestConfigurationValidator.validate(config)
    let helper = try resolveInteractiveConfiguration(configuration: config)
    let program = try GuestFileMapping.resolve(request.executableURL, configuration: config)
    try GuestFileMapping.validate(arguments: request.arguments, environment: request.environment)
    guard program.guestPath.caseInsensitiveCompare(helper.guestHelperPath) != .orderedSame else {
      throw WindowsGuestInteractiveError.invalidConfiguration
    }
    let storage = preflightStorage(
      targetDirectory: program.storageDirectory, installerURL: program.hostURL,
      configuration: config)
    await storageStatus.update(storage)
    try storage.validateHostReadiness()
    let initial = try await transport.inspect(config.identifier)
    guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
    try validate(initial, config: config)
    let deadline =
      UTMGuestOperationDeadline.value ?? (.now + .seconds(config.startupTimeoutSeconds))
    let launchedVM = try await prepareVM(initial, config: config, until: deadline)
    do {
      try await waitForAgent(config, until: deadline)
      try await ensureInteractiveHelper(helper, configuration: config, until: deadline)
      guard
        try await verifyGuestFile(
          config.identifier, guestPath: helper.guestHelperPath, until: deadline)
      else { throw UTMGuestError.guestFileNotVisible }
      try await pushAndVerify(program, configuration: config, storage: storage, until: deadline)
      let launchRequest = WindowsGuestInteractiveLaunchRequest(
        helperGuestPath: helper.guestHelperPath, executable: program.guestPath,
        arguments: request.arguments, environment: request.environment)
      let timing = WindowsGuestInteractiveTiming(deadline: deadline, pollInterval: pollInterval)
      let handle = try await transport.executeInteractive(
        config.identifier, request: launchRequest, timing: timing)
      return WindowsGuestInteractiveSession(
        transport: transport, vmID: config.identifier, handle: handle, interval: pollInterval)
    } catch {
      if launchedVM {
        do { try await rollbackGuest(config.identifier) } catch {
          throw UTMGuestError.rollbackFailed
        }
      }
      throw error
    }
  }

  func resolveInteractiveConfiguration(
    configuration config: RuntimeGuestConfiguration
  ) throws -> WindowsGuestInteractiveConfiguration {
    let helper: WindowsGuestInteractiveConfiguration
    if let interactiveConfiguration {
      helper = interactiveConfiguration
    } else {
      guard let mapping = config.fileMappings.first else {
        throw WindowsGuestInteractiveError.invalidConfiguration
      }
      let guestRoot = mapping.guestDirectory.replacingOccurrences(of: "/", with: "\\")
      helper = WindowsGuestInteractiveConfiguration(
        helperURL: mapping.hostDirectory.appendingPathComponent("desktop-helper.exe"),
        guestHelperPath: guestRoot + (guestRoot.hasSuffix("\\") ? "" : "\\") + "desktop-helper.exe")
    }
    guard helper.helperURL.isFileURL, helper.helperURL.pathExtension.lowercased() == "exe",
      FileManager.default.isReadableFile(atPath: helper.helperURL.path),
      helper.guestHelperPath.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil,
      !helper.guestHelperPath.contains("\0")
    else { throw WindowsGuestInteractiveError.invalidConfiguration }
    return helper
  }
}

public enum UTMGuestError: LocalizedError, Sendable, Equatable {
  case utmNotInstalled, invalidConfiguration, architectureMismatch, unsupportedBackend
  case vmUnavailable, vmStopped, agentUnavailable, fileMappingUnavailable, unsupportedExecutable
  case invalidArguments, automationFailed, stopTimedOut, invalidResult, cancelFailed
  case storageNotWritable, insufficientHostSpace, storagePreflightUnavailable, guestFileNotVisible
  case rollbackFailed

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
    case .rollbackFailed: "The Windows guest launch failed and VM cleanup could not be confirmed."
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

enum GuestFileMapping {
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
