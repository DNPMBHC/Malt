// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

actor MockDisplaySync: GuestSurfaceTestTypes.DisplaySynchronizing {
  private(set) var appliedModes: [GuestSurfaceTestTypes.DisplayMode] = []
  private(set) var restoredSnapshots: [GuestSurfaceTestTypes.DisplaySnapshot] = []
  private let previousMode: GuestSurfaceTestTypes.DisplayMode
  private let failApply: Bool
  private let failRestore: Bool
  private let delayApply: Bool

  init(
    previousMode: GuestSurfaceTestTypes.DisplayMode = GuestSurfaceTestTypes.DisplayMode(
      width: 1280, height: 720, refreshRateHz: 60),
    failApply: Bool = false, failRestore: Bool = false, delayApply: Bool = false
  ) {
    self.failApply = failApply
    self.failRestore = failRestore
    self.delayApply = delayApply
    self.previousMode = previousMode
  }

  func queryGuestDisplayMode(
    configuration: GuestSurfaceTestTypes.GuestConfiguration
  ) async throws -> GuestSurfaceTestTypes.DisplayMode {
    previousMode
  }

  func applyGuestDisplayMode(
    _ targetMode: GuestSurfaceTestTypes.DisplayMode,
    configuration: GuestSurfaceTestTypes.GuestConfiguration
  ) async throws -> GuestSurfaceTestTypes.DisplaySnapshot {
    appliedModes.append(targetMode)
    if delayApply { try await Task.sleep(for: .milliseconds(50)) }
    if failApply { throw GuestSurfaceTestTypes.DisplayError.changeDisplaySettingsFailed(-2) }
    return GuestSurfaceTestTypes.DisplaySnapshot(previousMode: previousMode, appliedMode: targetMode)
  }

  func restoreGuestDisplayMode(
    _ snapshot: GuestSurfaceTestTypes.DisplaySnapshot,
    configuration: GuestSurfaceTestTypes.GuestConfiguration
  ) async throws -> GuestSurfaceTestTypes.DisplayMode {
    restoredSnapshots.append(snapshot)
    if failRestore { throw GuestSurfaceTestTypes.DisplayError.invalidResponsePayload }
    return snapshot.previousMode
  }
}

actor MockGuestProviderForShell: GuestSurfaceTestTypes.Provider, GuestSurfaceTestTypes.Suspending {
  nonisolated let availability: GuestSurfaceTestTypes.Availability = .ready
  nonisolated let storageGuestConfiguration: GuestSurfaceTestTypes.GuestConfiguration?
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private let failStart: Bool
  private let exitStatus: Int32
  private let failSuspend: Bool
  private let exitGate: GuestSurfaceExitGate?

  init(
    configuration: GuestSurfaceTestTypes.GuestConfiguration, failStart: Bool = false, exitStatus: Int32 = 0,
    failSuspend: Bool = false, exitGate: GuestSurfaceExitGate? = nil
  ) {
    self.failSuspend = failSuspend
    self.exitGate = exitGate
    self.storageGuestConfiguration = configuration
    self.failStart = failStart
    self.exitStatus = exitStatus
  }

  func launch(_ request: GuestSurfaceTestTypes.LaunchRequest) async throws {
    _ = try await start(request)
  }

  func start(_ request: GuestSurfaceTestTypes.LaunchRequest) async throws -> GuestSurfaceTestTypes.Session {
    startCount += 1
    if failStart { throw GuestSurfaceTestTypes.ProviderError.automationFailed }
    let status = exitStatus
    let gate = exitGate
    return GuestSurfaceTestTypes.Session(
      wait: {
        if let gate { await gate.wait() }
        return GuestSurfaceTestTypes.ExitResult(status: status, reason: .exit)
      },
      cancel: { await gate?.complete() }
    )
  }

  func suspendGuest(configuration: GuestSurfaceTestTypes.GuestConfiguration) async throws {
    stopCount += 1
    if failSuspend { throw GuestSurfaceTestTypes.ProviderError.automationFailed }
  }
}

actor MockPresentationHooks: GuestSurfaceTestTypes.PresentationHooks {
  private(set) var startedModes: [GuestSurfaceTestTypes.DisplayMode] = []
  private(set) var receivedFrames = 0
  private(set) var endedCount = 0

  func onSessionStarted(mode: GuestSurfaceTestTypes.DisplayMode, backend: GuestSurfaceTestTypes.Backend) async {
    startedModes.append(mode)
  }

  func onFrameReceived(_ frame: GuestSurfaceTestTypes.Frame) async -> Bool {
    receivedFrames += 1
    frame.release()
    return true
  }

  func onSessionEnded() async -> Bool {
    endedCount += 1
    return true
  }
}

actor GuestSurfaceExitGate {
  private var completed = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if completed { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func complete() {
    completed = true
    continuation?.resume()
    continuation = nil
  }
}
