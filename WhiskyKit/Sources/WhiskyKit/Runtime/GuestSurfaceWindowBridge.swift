// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Main App integration stays in the runtime module; the App supplies settings and a real HID sink.
@MainActor
public final class GuestSurfaceWindowBridge: GuestSurfacePresentationHooks {
  public private(set) var controller: GuestSurfaceWindowController?
  private let configuration: GuestSurfaceSessionConfiguration
  private let pointerSink: (any GuestRelativePointerSink)?
  private let onClose: @Sendable () -> Void
  private let onResize: @Sendable (CGSize) -> Void

  public init(
    configuration: GuestSurfaceSessionConfiguration,
    pointerSink: (any GuestRelativePointerSink)? = nil,
    onClose: @escaping @Sendable () -> Void,
    onResize: @escaping @Sendable (CGSize) -> Void = { _ in }
  ) {
    self.configuration = configuration
    self.pointerSink = pointerSink
    self.onClose = onClose
    self.onResize = onResize
  }

  public func onSessionStarted(mode: GuestDisplayMode, backend: GuestSurfaceBackendKind) async {
    guard backend != .unavailable else { return }
    let controller = GuestSurfaceWindowController(
      initialMetrics: GuestSurfaceOverlayMetrics(
        width: mode.width, height: mode.height, refreshRateHz: mode.refreshRateHz,
        backend: backend, rawInputCaptured: false),
      pointerSink: pointerSink, captureOnInitialFocus: configuration.enableRawInputOnFocus, onWindowClosed: onClose)
    controller.presentationView.showsHUD = configuration.showOverlayHUD
    controller.onWindowPixelSizeChanged = onResize
    controller.setSessionRunning(true)
    self.controller = controller
    controller.enterNativeFullscreenIfNeeded()
  }

  public func onFrameReceived(_ frame: GuestSurfaceFrame) async -> Bool {
    guard let controller else {
      frame.release()
      return false
    }
    return await controller.presentFrame(frame)
  }

  public func onSessionEnded() async -> Bool {
    let closing = controller
    controller = nil
    closing?.setSessionRunning(false)
    closing?.closeAndReleaseResources()
    for _ in 0..<22 {
      if closing?.inputStateMachine.cursorReleaseVerified != false { return true }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
    }
    return closing?.inputStateMachine.cursorReleaseVerified ?? true
  }
}
