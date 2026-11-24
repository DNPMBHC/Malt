// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

/// The producer passes retained IOSurface/event objects into this adapter; no module dependency or pixel copy.
public final class GuestSurfacePushFrameSource: GuestSurfaceFrameSource, @unchecked Sendable {
  public let backendKind: GuestSurfaceBackendKind
  private let lock = NSLock()
  private let startProducer: @Sendable () async throws -> Void
  private let stopProducer: @Sendable () async -> Void
  private var callback: (@Sendable (GuestSurfaceFrame) -> Void)?
  private var lastFrameID: UInt64 = 0

  public init(
    backend: GuestSurfaceBackendKind = .vzZeroCopyIOSurface,
    startProducer: @escaping @Sendable () async throws -> Void = {},
    stopProducer: @escaping @Sendable () async -> Void = {}
  ) {
    backendKind = backend
    self.startProducer = startProducer
    self.stopProducer = stopProducer
  }

  public func start(onFrame: @escaping @Sendable (GuestSurfaceFrame) -> Void) async throws {
    try install(onFrame)
    do { try await startProducer() } catch {
      await stop()
      throw error
    }
  }

  private func install(_ onFrame: @escaping @Sendable (GuestSurfaceFrame) -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    guard callback == nil else { throw GuestSurfaceSessionError.sessionAlreadyRunning }
    lastFrameID = 0
    callback = onFrame
  }

  @discardableResult
  public func publish(_ frame: GuestSurfaceFrame) -> Bool {
    lock.lock()
    let receiver: (@Sendable (GuestSurfaceFrame) -> Void)?
    if frame.descriptor.backend == backendKind, frame.descriptor.frameID > lastFrameID {
      receiver = callback
      if receiver != nil { lastFrameID = frame.descriptor.frameID }
    } else {
      receiver = nil
    }
    lock.unlock()
    guard let receiver else {
      frame.release()
      return false
    }
    receiver(frame)
    return true
  }

  public func stop() async {
    removeReceiver()
    await stopProducer()
  }

  private func removeReceiver() {
    lock.lock()
    callback = nil
    lock.unlock()
  }
}
