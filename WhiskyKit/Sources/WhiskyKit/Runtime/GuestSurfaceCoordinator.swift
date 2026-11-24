// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Own this coordinator in App state. It wires session, native window and debounced display updates.
@MainActor
public final class GuestSurfaceCoordinator {
  public private(set) var lastResult: GuestSurfaceSessionResult?
  public private(set) var lastFailureCode: String?
  public private(set) var bridge: GuestSurfaceWindowBridge?
  private var session: GuestSurfaceSession?
  private var resizeTask: Task<Void, Never>?

  public init() {}

  public func run(
    _ request: RuntimeLaunchRequest, provider: any WindowsGuestProvider,
    displaySync: any GuestDisplaySynchronizing, configuration: GuestSurfaceSessionConfiguration,
    frameSource: any GuestSurfaceFrameSource, pointerSink: (any GuestRelativePointerSink)? = nil
  ) async throws -> GuestSurfaceSessionResult {
    guard session == nil else { throw GuestSurfaceSessionError.sessionAlreadyRunning }
    guard frameSource.backendKind != .unavailable else { throw GuestSurfaceSessionError.frameSourceUnavailable }
    lastFailureCode = nil
    lastResult = nil
    let bridge = GuestSurfaceWindowBridge(
      configuration: configuration, pointerSink: pointerSink,
      onClose: { [weak self] in Task { await self?.cancel() } },
      onResize: { [weak self] size in Task { await self?.scheduleResize(size) } })
    let session = GuestSurfaceSession(
      provider: provider, displaySync: displaySync, configuration: configuration,
      frameSource: frameSource, presentationHooks: bridge)
    self.session = session
    self.bridge = bridge
    defer {
      resizeTask?.cancel()
      resizeTask = nil
      self.session = nil
      self.bridge = nil
    }
    do {
      let result = try await withTaskCancellationHandler {
        try await session.run(request)
      } onCancel: {
        Task { await session.cancel() }
      }
      lastResult = result
      if let cleanupFailure = await session.lastCleanupFailure {
        lastFailureCode = cleanupFailure
      }
      return result
    } catch {
      lastFailureCode = "guest_surface_session_failed"
      throw error
    }
  }

  public func cancel() async {
    resizeTask?.cancel()
    await session?.cancel()
  }

  private func scheduleResize(_ size: CGSize) {
    resizeTask?.cancel()
    guard let session else { return }
    resizeTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(200))
        _ = try await session.synchronizeWindowPixelSize(size)
      } catch is CancellationError {
        // A later resize or teardown owns the final mode.
      } catch { self?.lastFailureCode = "window_display_sync_failed" }
    }
  }
}
