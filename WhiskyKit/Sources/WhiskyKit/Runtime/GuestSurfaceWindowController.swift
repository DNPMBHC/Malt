// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IOSurface
import Metal
import QuartzCore

/// Lightweight view that binds zero-copy `IOSurface` frames directly onto a `CAMetalLayer`.
@MainActor
public final class GuestSurfacePresentationView: NSView {
  public private(set) var presentedFrameCount: UInt64 = 0
  public private(set) var lastDescriptor: GuestSurfaceFrameDescriptor?
  private let hudLabel = NSTextField(labelWithString: "")
  private let hudContainer = NSView()
  private let metalLayer = CAMetalLayer()
  private var presenter: GuestSurfaceMetalPresenter?
  private var inFlightFrames = 0
  public private(set) var lastPresentationError: String?

  public var showsHUD: Bool = true {
    didSet { hudContainer.isHidden = !showsHUD }
  }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureLayers()
    configureHUD()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  private func configureLayers() {
    wantsLayer = true
    metalLayer.device = MTLCreateSystemDefaultDevice()
    if let device = metalLayer.device {
      presenter = try? GuestSurfaceMetalPresenter(device: device)
    }
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.contentsGravity = .resizeAspect
    metalLayer.backgroundColor = NSColor.black.cgColor
    layer = metalLayer
  }

  private func configureHUD() {
    hudContainer.wantsLayer = true
    hudContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
    hudContainer.layer?.cornerRadius = 8
    hudContainer.translatesAutoresizingMaskIntoConstraints = false

    hudLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    hudLabel.textColor = .white
    hudLabel.translatesAutoresizingMaskIntoConstraints = false
    hudContainer.addSubview(hudLabel)
    addSubview(hudContainer)

    NSLayoutConstraint.activate([
      hudContainer.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      hudContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      hudLabel.topAnchor.constraint(equalTo: hudContainer.topAnchor, constant: 6),
      hudLabel.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor, constant: -6),
      hudLabel.leadingAnchor.constraint(equalTo: hudContainer.leadingAnchor, constant: 10),
      hudLabel.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor, constant: -10)
    ])
  }

  public func presentAndWait(_ frame: GuestSurfaceFrame) async -> Bool {
    guard let presenter, inFlightFrames < 2, window != nil else {
      frame.release()
      lastPresentationError = "presenter_or_window_unavailable"
      return false
    }
    guard await frame.waitForProducer(), window != nil, inFlightFrames < 2 else {
      frame.release()
      lastPresentationError = "producer_fence_timeout"
      return false
    }
    metalLayer.drawableSize = CGSize(width: frame.descriptor.width, height: frame.descriptor.height)
    metalLayer.pixelFormat =
      frame.descriptor.pixelFormat == .bgra8Unorm ? .bgra8Unorm : .rgba16Float
    guard let drawable = metalLayer.nextDrawable() else {
      frame.release()
      lastPresentationError = "drawable_unavailable"
      return false
    }
    do {
      let command = try presenter.encode(frame, target: drawable.texture)
      command.present(drawable)
      inFlightFrames += 1
      let completed = await withCheckedContinuation { continuation in
        command.addCompletedHandler { buffer in
          continuation.resume(returning: buffer.status == .completed)
        }
        command.commit()
      }
      inFlightFrames -= 1
      guard completed else {
        lastPresentationError = "gpu_command_failed"
        return false
      }
      presentedFrameCount += 1
      lastDescriptor = frame.descriptor
      lastPresentationError = nil
      return true
    } catch {
      frame.release()
      lastPresentationError = "frame_binding_failed"
      return false
    }
  }

  public func updateHUD(_ metrics: GuestSurfaceOverlayMetrics) {
    hudLabel.stringValue = metrics.summaryLabel
  }
}

/// Native macOS fullscreen game shell container aligned with Plan B zero-copy `IOSurface`
/// presentation and failsafe FPS Raw Input cursor capture.
@MainActor
public final class GuestSurfaceWindowController: NSWindowController, NSWindowDelegate {
  public let presentationView: GuestSurfacePresentationView
  public let inputStateMachine: GuestRawInputCaptureStateMachine
  private let onWindowClosed: (() -> Void)?
  private var overlayMetrics: GuestSurfaceOverlayMetrics
  private var closingForSession = false
  private var fullscreenPending = false
  private var fullscreenScheduled = false
  private var captureOnInitialFocus: Bool
  public var onWindowPixelSizeChanged: ((CGSize) -> Void)?
  private nonisolated(unsafe) var appResignObserver: NSObjectProtocol?
  private nonisolated(unsafe) var appActiveObserver: NSObjectProtocol?

  public init(
    initialMetrics: GuestSurfaceOverlayMetrics,
    cursorController: any GuestCursorControlling = SystemGuestCursorController(),
    onPointerDelta: ((GuestRelativePointerDelta) -> Void)? = nil,
    pointerSink: (any GuestRelativePointerSink)? = nil,
    captureOnInitialFocus: Bool = false,
    onWindowClosed: (() -> Void)? = nil
  ) {
    self.overlayMetrics = initialMetrics
    self.captureOnInitialFocus = captureOnInitialFocus
    self.onWindowClosed = onWindowClosed
    self.presentationView = GuestSurfacePresentationView(
      frame: NSRect(x: 0, y: 0, width: initialMetrics.width, height: initialMetrics.height)
    )
    var stateMachinePlaceholder: ((GuestRelativePointerDelta) -> Void)?
    var refreshCaptureHUD: (() -> Void)?
    let stateMachine = GuestRawInputCaptureStateMachine(
      cursorController: cursorController,
      capturePermitted: pointerSink != nil || onPointerDelta != nil,
      onStateChange: { _, _ in refreshCaptureHUD?() },
      onPointerDelta: { [weak pointerSink] delta in
        onPointerDelta?(delta)
        if let pointerSink {
          if !pointerSink.submit(delta) { stateMachinePlaceholder?(delta) }
        } else if onPointerDelta == nil {
          stateMachinePlaceholder?(delta)
        }
      }
    )
    stateMachinePlaceholder = { [weak stateMachine] _ in
      stateMachine?.revokeCapturePermission()
    }
    self.inputStateMachine = stateMachine

    let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    let window = GuestSurfaceHostingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: style,
      backing: .buffered,
      defer: false
    )
    window.title = "Game Shell"
    window.backgroundColor = .black
    window.collectionBehavior = [.fullScreenPrimary, .managed]
    window.contentView = presentationView
    window.inputStateMachine = stateMachine
    window.acceptsMouseMovedEvents = true

    super.init(window: window)
    window.delegate = self
    refreshCaptureHUD = { [weak self] in self?.refreshHUDCaptureState() }
    window.onInputStateChanged = { [weak self] in self?.refreshHUDCaptureState() }
    presentationView.updateHUD(initialMetrics)
    registerApplicationObservers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  private func registerApplicationObservers() {
    let center = NotificationCenter.default
    appResignObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.inputStateMachine.updateFocus(windowKey: false, applicationActive: false)
        self?.refreshHUDCaptureState()
      }
    }
    appActiveObserver = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        let isKey = self?.window?.isKeyWindow ?? false
        self?.inputStateMachine.updateFocus(windowKey: isKey, applicationActive: true)
        self?.scheduleFullscreenEntry()
        self?.refreshHUDCaptureState()
      }
    }
  }

  public func presentFrame(_ frame: GuestSurfaceFrame) async -> Bool {
    guard await presentationView.presentAndWait(frame) else { return false }
    let updated = GuestSurfaceOverlayMetrics(
      width: frame.descriptor.width,
      height: frame.descriptor.height,
      refreshRateHz: overlayMetrics.refreshRateHz,
      backend: frame.descriptor.backend,
      rawInputCaptured: inputStateMachine.state == .captured,
      releaseShortcutHint: overlayMetrics.releaseShortcutHint,
      cursorReleaseVerified: inputStateMachine.cursorReleaseVerified
    )
    overlayMetrics = updated
    presentationView.updateHUD(updated)
    return true
  }

  public func setSessionRunning(_ running: Bool) {
    inputStateMachine.setSessionRunning(running)
    refreshHUDCaptureState()
  }

  public func enterNativeFullscreenIfNeeded() {
    guard let window else { return }
    fullscreenPending = true
    window.makeKeyAndOrderFront(nil)
    scheduleFullscreenEntry()
  }

  private func scheduleFullscreenEntry() {
    guard fullscreenPending, !fullscreenScheduled, !closingForSession,
      let window, window.isVisible, window.isKeyWindow, NSApp?.isActive == true
    else { return }
    fullscreenScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.fullscreenScheduled = false
      guard self.fullscreenPending, !self.closingForSession, let window = self.window,
        window.isVisible, window.isKeyWindow, NSApp?.isActive == true
      else { return }
      self.fullscreenPending = false
      if !window.styleMask.contains(.fullScreen) {
        window.displayIfNeeded()
        window.toggleFullScreen(nil)
      }
    }
  }

  public func closeAndReleaseResources() {
    closingForSession = true
    fullscreenPending = false
    inputStateMachine.release(reason: .windowClosed)
    refreshHUDCaptureState()
    window?.orderOut(nil)
    close()
  }

  public func windowDidBecomeKey(_ notification: Notification) {
    scheduleFullscreenEntry()
    inputStateMachine.updateFocus(windowKey: true, applicationActive: NSApp?.isActive ?? true)
    if captureOnInitialFocus, inputStateMachine.requestCapture() { captureOnInitialFocus = false }
    refreshHUDCaptureState()
  }

  public func windowDidResignKey(_ notification: Notification) {
    inputStateMachine.updateFocus(windowKey: false, applicationActive: NSApp?.isActive ?? false)
    refreshHUDCaptureState()
  }

  public func windowWillClose(_ notification: Notification) {
    inputStateMachine.release(reason: .windowClosed)
    refreshHUDCaptureState()
    if !closingForSession { onWindowClosed?() }
  }

  public func windowDidResize(_ notification: Notification) {
    onWindowPixelSizeChanged?(presentationView.convertToBacking(presentationView.bounds).size)
  }

  public func windowDidChangeBackingProperties(_ notification: Notification) {
    windowDidResize(notification)
  }

  private func refreshHUDCaptureState() {
    let updated = GuestSurfaceOverlayMetrics(
      width: overlayMetrics.width,
      height: overlayMetrics.height,
      refreshRateHz: overlayMetrics.refreshRateHz,
      backend: overlayMetrics.backend,
      rawInputCaptured: inputStateMachine.state == .captured,
      releaseShortcutHint: overlayMetrics.releaseShortcutHint,
      cursorReleaseVerified: inputStateMachine.cursorReleaseVerified
    )
    overlayMetrics = updated
    presentationView.updateHUD(updated)
  }

  deinit {
    let center = NotificationCenter.default
    if let appResignObserver { center.removeObserver(appResignObserver) }
    if let appActiveObserver { center.removeObserver(appActiveObserver) }
  }
}

@MainActor
private final class GuestSurfaceHostingWindow: NSWindow {
  weak var inputStateMachine: GuestRawInputCaptureStateMachine?
  var onInputStateChanged: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let characters = event.charactersIgnoringModifiers {
      let consumed =
        inputStateMachine?.handleKeyDown(
          charactersIgnoringModifiers: characters, modifierFlags: event.modifierFlags) == true
      if consumed {
        onInputStateChanged?()
        return
      }
    }
    super.sendEvent(event)
  }

  override func keyDown(with event: NSEvent) {
    let consumed =
      event.charactersIgnoringModifiers.map { chars in
        inputStateMachine?.handleKeyDown(
          charactersIgnoringModifiers: chars, modifierFlags: event.modifierFlags
        ) ?? false
      } ?? false
    if consumed { return }
    super.keyDown(with: event)
  }

  override func mouseMoved(with event: NSEvent) { forwardPhysicalMouse(event) }

  override func mouseDragged(with event: NSEvent) { forwardPhysicalMouse(event) }

  override func rightMouseDragged(with event: NSEvent) { forwardPhysicalMouse(event) }

  override func otherMouseDragged(with event: NSEvent) { forwardPhysicalMouse(event) }

  private func forwardPhysicalMouse(_ event: NSEvent) {
    guard let raw = event.cgEvent else { return }
    let previousState = inputStateMachine?.state
    _ = inputStateMachine?.handleMouseDelta(
      deltaX: raw.getDoubleValueField(.eventUnacceleratedPointerMovementX),
      deltaY: raw.getDoubleValueField(.eventUnacceleratedPointerMovementY), timestamp: event.timestamp)
    if inputStateMachine?.state != previousState { onInputStateChanged?() }
  }
}
