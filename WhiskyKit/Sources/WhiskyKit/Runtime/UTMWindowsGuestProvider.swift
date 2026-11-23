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
  public let executionMode: WindowsGuestExecutionMode
  let interactiveConfiguration: WindowsGuestInteractiveConfiguration?
  private let minimumFreeBytes: Int64
  let activeGuest = UTMActiveGuest()
  let storageStatus = UTMGuestStorageStatus()

  public init(
    configuration: RuntimeGuestConfiguration? = nil,
    executionMode: WindowsGuestExecutionMode = .interactiveDesktop,
    interactiveConfiguration: WindowsGuestInteractiveConfiguration? = nil
  ) {
    self.configuration = configuration
    minimumFreeBytes = 4 * 1024 * 1024 * 1024
    self.executionMode = executionMode
    self.interactiveConfiguration = interactiveConfiguration
    transport = makeWindowsGuestTransport()
    installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.utmapp.UTM") != nil
    pollInterval = .milliseconds(250)
  }

  init(
    configuration: RuntimeGuestConfiguration?, transport: any UTMGuestTransport,
    installed: Bool = true, pollInterval: Duration = .milliseconds(1),
    executionMode: WindowsGuestExecutionMode = .background, minimumFreeBytes: Int64 = 0,
    interactiveConfiguration: WindowsGuestInteractiveConfiguration? = nil
  ) {
    self.configuration = configuration
    self.minimumFreeBytes = minimumFreeBytes
    self.executionMode = executionMode
    self.interactiveConfiguration = interactiveConfiguration
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
    if executionMode == .interactiveDesktop {
      do { _ = try resolveInteractiveConfiguration(configuration: configuration) } catch {
        return .unavailable("The interactive desktop helper is not configured or readable.")
      }
    }
    return .ready
  }

  public func preflightStorage(
    targetDirectory: URL?, installerURL: URL? = nil,
    installerBytes: Int64? = nil,
    configuration requestedConfiguration: RuntimeGuestConfiguration? = nil
  ) -> UTMGuestStoragePreflight {
    UTMGuestStoragePreflightChecker(minimumFreeBytes: minimumFreeBytes).check(
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
    if executionMode == .interactiveDesktop {
      return try await startInteractive(request).asRuntimeSession()
    }
    if let config = request.guestConfiguration ?? configuration {
      try GuestConfigurationValidator.validate(config)
    }
    let timeout = (request.guestConfiguration ?? configuration)?.startupTimeoutSeconds ?? 60
    let localDeadline = ContinuousClock.now + .seconds(timeout)
    let deadline = min(localDeadline, UTMGuestOperationDeadline.value ?? localDeadline)
    return try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      try await startBackground(request)
    }
  }

  private func startBackground(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
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
    let deadline =
      UTMGuestOperationDeadline.value ?? (.now + .seconds(config.startupTimeoutSeconds))
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
        do { try await rollbackGuest(config.identifier) } catch {
          throw UTMGuestError.rollbackFailed
        }
      }
      throw error
    }
  }

  func pushAndVerify(
    _ program: MappedGuestFile, configuration: RuntimeGuestConfiguration,
    storage: UTMGuestStoragePreflight, until deadline: ContinuousClock.Instant
  ) async throws {
    let identifier = configuration.identifier
    do {
      try await transport.pushCreatingParentDirectory(
        identifier, hostURL: program.hostURL, guestPath: program.guestPath,
        until: deadline, pollInterval: pollInterval)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RuntimeLaunchError where error == .issue(.guestTimeout) {
      throw error
    } catch {
      throw UTMGuestError.fileMappingUnavailable
    }
    guard try await verifyGuestFile(identifier, guestPath: program.guestPath, until: deadline)
    else {
      await storageStatus.update(storage.recordingGuestFileVisibility(.notVisible))
      throw UTMGuestError.guestFileNotVisible
    }
    let verified = storage.recordingGuestFileVisibility(.visible)
    guard verified.canExecuteGuestFile else { throw UTMGuestError.guestFileNotVisible }
    await storageStatus.update(verified)
  }

  /// Cleanup owns a fresh cancellation scope, so an expired launch can still roll back its VM.
  func rollbackGuest(_ identifier: String) async throws {
    let transport = transport
    let activeGuest = activeGuest
    let cleanup = Task {
      let deadline = ContinuousClock.now + .seconds(10)
      try await UTMGuestOperationDeadline.$value.withValue(deadline) {
        if try await transport.inspect(identifier).status == .stopped {
          await activeGuest.clear(ifMatching: identifier)
          return
        }
        try await transport.stop(identifier)
        while ContinuousClock.now < deadline {
          if try await transport.inspect(identifier).status == .stopped {
            await activeGuest.clear(ifMatching: identifier)
            return
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        throw UTMGuestError.stopTimedOut
      }
    }
    try await cleanup.value
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
}

extension UTMWindowsGuestProvider {
  func prepareVM(
    _ initial: UTMVMSnapshot, config: RuntimeGuestConfiguration,
    until deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    let launchedVM = initial.status == .stopped || initial.status == .paused
    do {
      switch initial.status {
      case .started, .starting, .resuming:
        await activeGuest.set(config.identifier)
      case .stopped, .paused:
        try await transport.start(config.identifier)
        await activeGuest.set(config.identifier)
      case .pausing, .stopping, .unavailable:
        throw UTMGuestError.vmUnavailable
      }
      if initial.status != .started { try await waitForVM(config, until: deadline) }
      return launchedVM
    } catch {
      if launchedVM {
        do { try await rollbackGuest(config.identifier) } catch {
          throw UTMGuestError.rollbackFailed
        }
      }
      throw error
    }
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

  func verifyGuestFile(
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
