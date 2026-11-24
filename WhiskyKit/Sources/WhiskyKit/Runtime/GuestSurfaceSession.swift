// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum GuestSurfaceSessionState: String, Equatable, Sendable {
  case idle
  case preparingDisplay = "preparing_display"
  case running
  case tearingDown = "tearing_down"
  case finished, failed
}

public struct GuestSurfaceSessionResult: Equatable, Sendable {
  public let exitResult: RuntimeExitResult
  public let targetDisplayMode: GuestDisplayMode
  public let displaySnapshot: GuestDisplaySyncSnapshot?
  public let displayRestored: Bool
  public let guestSuspendedOnExit: Bool
  public let framesPresented: UInt64
  public let cursorReleaseVerified: Bool
}

public protocol GuestSurfacePresentationHooks: Sendable {
  func onSessionStarted(mode: GuestDisplayMode, backend: GuestSurfaceBackendKind) async
  func onFrameReceived(_ frame: GuestSurfaceFrame) async -> Bool
  func onSessionEnded() async -> Bool
}

public protocol GuestLifecycleSuspending: Sendable {
  func suspendGuest(configuration: RuntimeGuestConfiguration) async throws
}

extension UTMWindowsGuestProvider: GuestLifecycleSuspending {}

public enum GuestSurfaceSessionError: Error, Equatable, Sendable {
  case guestConfigurationMissing, sessionAlreadyRunning, idlePolicyUnsupported, frameSourceUnavailable
}

/// Owns one foreground Guest application and a bounded frame stream.
/// Cleanup runs in a fresh cancellation scope and releases the host cursor first.
public actor GuestSurfaceSession {
  public private(set) var state: GuestSurfaceSessionState = .idle
  public private(set) var lastCleanupFailure: String?
  private let provider: any WindowsGuestProvider
  private let displaySync: any GuestDisplaySynchronizing
  private let configuration: GuestSurfaceSessionConfiguration
  private let frameSource: (any GuestSurfaceFrameSource)?
  private let presentationHooks: (any GuestSurfacePresentationHooks)?
  private var activeRuntimeSession: RuntimeSession?
  private var frameConsumer: Task<Void, Never>?
  private var continuation: AsyncStream<GuestSurfaceFrame>.Continuation?
  private var frameCounter: UInt64 = 0
  private var generation: UInt64 = 0
  private var cancellationRequested = false
  private var presentationEnded = false
  private var cursorReleaseVerified = true
  private var windowPixelSize: CGSize?
  private var activeConfiguration: RuntimeGuestConfiguration?
  private var displayUpdate: Task<GuestDisplaySyncSnapshot, Error>?

  public init(
    provider: any WindowsGuestProvider, displaySync: any GuestDisplaySynchronizing,
    configuration: GuestSurfaceSessionConfiguration,
    frameSource: (any GuestSurfaceFrameSource)? = nil,
    presentationHooks: (any GuestSurfacePresentationHooks)? = nil
  ) {
    self.provider = (provider as? UTMWindowsGuestProvider)?.headlessSurfaceProvider() ?? provider
    self.displaySync =
      (displaySync as? UTMWindowsGuestProvider)?.headlessSurfaceProvider() ?? displaySync
    self.configuration = configuration
    self.frameSource = frameSource
    self.presentationHooks = presentationHooks
  }

  public func updateWindowPixelSize(_ size: CGSize) {
    guard size.width.isFinite, size.height.isFinite else { return }
    windowPixelSize = size
  }

  public func synchronizeWindowPixelSize(_ size: CGSize) async throws -> GuestDisplayMode? {
    updateWindowPixelSize(size)
    guard configuration.resolutionPreset == .followWindow, state == .running,
      let config = activeConfiguration, displayUpdate == nil
    else { return nil }
    let mode = try GuestDisplayResolutionPolicy.resolve(
      preset: .followWindow, hostDisplay: configuration.hostDisplay, windowPixelSize: size)
    let task = Task { try await displaySync.applyGuestDisplayMode(mode, configuration: config) }
    displayUpdate = task
    do {
      let snapshot = try await task.value
      displayUpdate = nil
      return state == .running ? snapshot.appliedMode : nil
    } catch {
      displayUpdate = nil
      throw error
    }
  }

  public func run(_ request: RuntimeLaunchRequest) async throws -> GuestSurfaceSessionResult {
    guard state == .idle || state == .finished || state == .failed else {
      throw GuestSurfaceSessionError.sessionAlreadyRunning
    }
    guard let guestConfig = request.guestConfiguration ?? provider.storageGuestConfiguration else {
      throw GuestSurfaceSessionError.guestConfigurationMissing
    }
    try GuestFileMapping.validate(arguments: request.arguments, environment: request.environment)
    try GuestConfigurationValidator.validate(guestConfig)
    let targetMode = try GuestDisplayResolutionPolicy.resolve(
      preset: configuration.resolutionPreset, hostDisplay: configuration.hostDisplay,
      windowPixelSize: windowPixelSize)
    state = .preparingDisplay
    activeConfiguration = guestConfig
    frameCounter = 0
    generation += 1
    cancellationRequested = false
    presentationEnded = false
    lastCleanupFailure = nil
    return try await execute(request: request, guestConfig: guestConfig, targetMode: targetMode)
  }

  private func checkCancellation() throws {
    try Task.checkCancellation()
    if cancellationRequested { throw CancellationError() }
  }

  private func startFrames() async throws {
    guard let frameSource else { return }
    let currentGeneration = generation
    let pair = AsyncStream<GuestSurfaceFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation = pair.continuation
    frameConsumer = Task {
      for await frame in pair.stream {
        await self.recordFrame(frame, generation: currentGeneration)
      }
    }
    try await frameSource.start { frame in
      switch pair.continuation.yield(frame) {
      case .dropped(let discarded): discarded.release()
      case .terminated: frame.release()
      case .enqueued: break
      @unknown default: frame.release()
      }
    }
  }

  private func execute(
    request: RuntimeLaunchRequest, guestConfig: RuntimeGuestConfiguration,
    targetMode: GuestDisplayMode
  ) async throws -> GuestSurfaceSessionResult {
    var snapshot: GuestDisplaySyncSnapshot?
    do {
      let baseline = try await displaySync.queryGuestDisplaySnapshot(configuration: guestConfig)
      try checkCancellation()
      snapshot = GuestDisplaySyncSnapshot(
        previousMode: baseline.previousMode, appliedMode: targetMode,
        displayDeviceName: baseline.displayDeviceName)
      snapshot = try await displaySync.applyGuestDisplayMode(targetMode, configuration: guestConfig)
      try checkCancellation()
      let actualMode = snapshot?.appliedMode ?? targetMode
      let runtimeSession = try await provider.start(request)
      activeRuntimeSession = runtimeSession
      if cancellationRequested { await runtimeSession.cancel() }
      try checkCancellation()
      state = .running
      await presentationHooks?.onSessionStarted(
        mode: actualMode, backend: frameSource?.backendKind ?? .unavailable)
      try await startFrames()
      try checkCancellation()
      let exit = try await runtimeSession.wait()
      let cleanup = await teardown(config: guestConfig, snapshot: snapshot)
      state = lastCleanupFailure == nil ? .finished : .failed
      return GuestSurfaceSessionResult(
        exitResult: exit, targetDisplayMode: actualMode, displaySnapshot: snapshot,
        displayRestored: cleanup.restored, guestSuspendedOnExit: cleanup.suspended,
        framesPresented: frameCounter, cursorReleaseVerified: cursorReleaseVerified)
    } catch {
      await activeRuntimeSession?.cancel()
      _ = await teardown(config: guestConfig, snapshot: snapshot)
      state = .failed
      throw error
    }
  }

  public func cancel() async {
    cancellationRequested = true
    await endPresentation()
    await activeRuntimeSession?.cancel()
  }

  private func endPresentation() async {
    guard !presentationEnded else { return }
    presentationEnded = true
    cursorReleaseVerified = await presentationHooks?.onSessionEnded() ?? true
    if !cursorReleaseVerified { lastCleanupFailure = "cursor_release_failed" }
  }

  private func recordFrame(_ frame: GuestSurfaceFrame, generation expected: UInt64) async {
    guard generation == expected, !presentationEnded,
      state == .preparingDisplay || state == .running
    else {
      frame.release()
      return
    }
    if let presentationHooks {
      if await presentationHooks.onFrameReceived(frame) { frameCounter += 1 }
    } else {
      frame.release()
    }
  }

  private func teardown(
    config: RuntimeGuestConfiguration, snapshot: GuestDisplaySyncSnapshot?
  ) async -> (restored: Bool, suspended: Bool) {
    state = .tearingDown
    activeRuntimeSession = nil
    await endPresentation()
    displayUpdate?.cancel()
    _ = try? await displayUpdate?.value
    displayUpdate = nil
    activeConfiguration = nil
    continuation?.finish()
    continuation = nil
    await frameSource?.stop()
    await frameConsumer?.value
    frameConsumer = nil
    let cleanup = Task {
      await UTMGuestOperationDeadline.$value.withValue(nil) {
        var restored = false
        if let snapshot {
          do {
            let mode = try await self.displaySync.restoreGuestDisplayMode(
              snapshot, configuration: config)
            restored = mode == snapshot.previousMode
            if !restored { self.lastCleanupFailure = "display_restore_mismatch" }
          } catch { self.lastCleanupFailure = "display_restore_failed" }
        }
        var suspended = false
        if self.configuration.idlePolicy == .suspendOnExit, restored {
          do {
            guard let suspender = self.provider as? any GuestLifecycleSuspending else {
              throw GuestSurfaceSessionError.idlePolicyUnsupported
            }
            try await suspender.suspendGuest(configuration: config)
            suspended = true
          } catch { self.lastCleanupFailure = "guest_suspend_failed" }
        }
        return (restored, suspended)
      }
    }
    return await cleanup.value
  }
}
