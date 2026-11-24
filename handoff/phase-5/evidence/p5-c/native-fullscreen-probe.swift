// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import AppKit
import Foundation
import IOSurface
import Metal
import ModuleC
import ModuleX
import QuartzCore

private enum NativeProbeError: Error {
  case failed
}

private final class LeaseLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var returned: Set<UInt64> = []
  private var flags: [String: Bool] = [:]

  func check(_ name: String, _ passed: Bool) {
    lock.lock()
    flags[name] = (flags[name] ?? true) && passed
    lock.unlock()
  }

  func didReturn(_ id: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return returned.contains(id)
  }

  var checks: [String: Bool] {
    lock.lock()
    defer { lock.unlock() }
    return flags
  }

  func wrap(_ lease: SurfaceFrameLease) -> GuestSurfaceFrame {
    let metadata = lease.metadata
    check("origin_explicitly_synthetic", metadata.origin == "host_synthetic_not_guest_scanout")
    check("supported_format", metadata.pixelFormat == "BGRA8Unorm")
    check("layout_matches_producer", IOSurfaceGetBytesPerRow(lease.surface) == metadata.bytesPerRow)
    check("producer_write_complete", lease.readyEvent.signaledValue >= metadata.readyValue)
    return GuestSurfaceFrame(
      descriptor: GuestSurfaceFrameDescriptor(
        frameID: metadata.frameID, width: metadata.width, height: metadata.height,
        pixelFormat: .bgra8Unorm, ioSurfaceID: IOSurfaceGetID(lease.surface),
        sharedEventSignaledValue: metadata.readyValue, backend: .syntheticTest),
      surface: lease.surface, sharedEvent: lease.readyEvent,
      onRelease: { [self] in acknowledge(lease) })
  }

  private func acknowledge(_ lease: SurfaceFrameLease) {
    let first = lease.release()
    let repeated = lease.release()
    check("producer_release_idempotent", first && !repeated)
    lock.lock()
    let inserted = returned.insert(lease.metadata.frameID).inserted
    lock.unlock()
    check("consumer_receipt_once_per_frame", inserted)
  }
}

private struct NativeProbeResult: Encodable {
  let owner = "@DNPMBHC"
  let sourceOrigin = "host_synthetic_not_guest_scanout"
  let realGuestVerified = false
  let virtualHIDVerified = false
  let framesConsumed: Int
  let checks: [String: Bool]
  let producerSnapshot: [String: UInt64]
  let hostBackingScale: Double
  let entryState: [String: Bool]
}

@MainActor
private final class NativeProbeDelegate: NSObject, NSApplicationDelegate {
  private let ledger = LeaseLedger()
  private var controller: GuestSurfaceWindowController?
  private var enteredFullscreen = false
  private var phase = "opening"
  private var entryState: [String: Bool] = [:]
  private var cancelledWindowEntered = false
  private var enterObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
      self?.controller?.closeAndReleaseResources()
      self?.emitFailure("native_window_timeout")
      NSApp.terminate(nil)
    }
    Task { @MainActor in
      do {
        let result = try await runProbe()
        let data = try JSONEncoder().encode(result)
        guard let encoded = String(data: data, encoding: .utf8) else { throw NativeProbeError.failed }
        emit(encoded)
        NSApp.terminate(nil)
      } catch {
        controller?.closeAndReleaseResources()
        emitFailure("native_window_failed")
        NSApp.terminate(nil)
      }
    }
  }

  private func emit(_ encoded: String) {
    if CommandLine.arguments.count == 2 {
      try? Data(encoded.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
    print(encoded)
  }

  private func emitFailure(_ code: String) {
    let value: [String: Any] = [
      "owner": "@DNPMBHC", "passed": false, "error": code,
      "phase": phase, "checks": ledger.checks, "entryState": entryState
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: value),
      let encoded = String(data: data, encoding: .utf8)
    else { return }
    emit(encoded)
  }

  private func runProbe() async throws -> NativeProbeResult {
    let window = try await openFullscreen()
    phase = "presenting"
    let count = try await presentFrames(window)
    let scale = Double(window.window?.backingScaleFactor ?? 0)
    ledger.check("native_cametal_layer_attached", window.presentationView.layer is CAMetalLayer)
    ledger.check("actual_gpu_present_count", window.presentationView.presentedFrameCount == UInt64(count))
    ledger.check("presentation_error_absent", window.presentationView.lastPresentationError == nil)
    ledger.check("no_cursor_capture", window.inputStateMachine.state != .captured)
    ledger.check("missing_hid_refuses_capture", !window.inputStateMachine.requestCapture())
    ledger.check("backing_scale_matches_screen", scale == Double(window.window?.screen?.backingScaleFactor ?? -1))
    phase = "closing"
    window.closeAndReleaseResources()
    for _ in 0..<30 where NSApp.currentSystemPresentationOptions.contains(.fullScreen) {
      try await Task.sleep(for: .milliseconds(100))
    }
    ledger.check("window_closed_automatically", window.window?.isVisible != true)
    ledger.check("native_fullscreen_presentation_ended", !NSApp.currentSystemPresentationOptions.contains(.fullScreen))
    ledger.check("cursor_release_verified", window.inputStateMachine.cursorReleaseVerified)
    ledger.check("input_state_released", window.inputStateMachine.state == .released)
    try await verifyPendingClose()
    if let enterObserver { NotificationCenter.default.removeObserver(enterObserver) }
    return NativeProbeResult(
      framesConsumed: count, checks: ledger.checks, producerSnapshot: lastProducerSnapshot, hostBackingScale: scale,
      entryState: entryState)
  }

  private func verifyPendingClose() async throws {
    let metrics = GuestSurfaceOverlayMetrics(
      width: 512, height: 320, refreshRateHz: 60, backend: .syntheticTest, rawInputCaptured: false)
    let cancelled = GuestSurfaceWindowController(initialMetrics: metrics, captureOnInitialFocus: false)
    cancelled.window?.title = "Cancelled Diagnostics"
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didEnterFullScreenNotification, object: cancelled.window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelledWindowEntered = true }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    cancelled.enterNativeFullscreenIfNeeded()
    cancelled.closeAndReleaseResources()
    try await Task.sleep(for: .milliseconds(200))
    ledger.check("pending_fullscreen_cancelled_on_close", !cancelledWindowEntered)
    ledger.check("cancelled_window_stayed_closed", cancelled.window?.isVisible != true)
    ledger.check("cancelled_window_not_fullscreen", cancelled.window?.styleMask.contains(.fullScreen) != true)
    ledger.check("cancelled_cursor_release_verified", cancelled.inputStateMachine.cursorReleaseVerified)
  }

  private func openFullscreen() async throws -> GuestSurfaceWindowController {
    let metrics = GuestSurfaceOverlayMetrics(
      width: 512, height: 320, refreshRateHz: 60, backend: .syntheticTest, rawInputCaptured: false)
    let window = GuestSurfaceWindowController(initialMetrics: metrics, captureOnInitialFocus: false)
    controller = window
    window.window?.title = "Synthetic Surface Diagnostics"
    window.window?.center()
    window.setSessionRunning(true)
    enterObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEnterFullScreenNotification, object: window.window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.enteredFullscreen = true }
    }
    NSApp.activate()
    entryState["application_active_before_request"] = NSApp.isActive
    entryState["window_key_before_request"] = window.window?.isKeyWindow == true
    window.enterNativeFullscreenIfNeeded()
    entryState["application_active_after_request"] = NSApp.isActive
    entryState["window_key_after_request"] = window.window?.isKeyWindow == true
    for _ in 0..<50 where !enteredFullscreen {
      try await Task.sleep(for: .milliseconds(100))
    }
    entryState["application_active_after_wait"] = NSApp.isActive
    entryState["window_key_after_wait"] = window.window?.isKeyWindow == true
    entryState["window_visible_after_wait"] = window.window?.isVisible == true
    ledger.check("native_fullscreen_transition_notified", enteredFullscreen)
    ledger.check("window_fullscreen_style_observed", window.window?.styleMask.contains(.fullScreen) == true)
    ledger.check(
      "native_fullscreen_primary_behavior", window.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
    ledger.check("window_on_active_space", window.window?.isOnActiveSpace == true)
    guard enteredFullscreen else { throw NativeProbeError.failed }
    return window
  }

  private var lastProducerSnapshot: [String: UInt64] = [:]

  private func presentFrames(_ window: GuestSurfaceWindowController) async throws -> Int {
    let producer = try SurfaceFrameProducer(width: 512, height: 320, draws: 64)
    let push = GuestSurfacePushFrameSource(backend: .syntheticTest)
    let pair = AsyncStream<GuestSurfaceFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    try await push.start { frame in
      switch pair.continuation.yield(frame) {
      case .dropped(let old): old.release()
      case .terminated: frame.release()
      case .enqueued: break
      @unknown default: frame.release()
      }
    }
    producer.start { [ledger] in push.publish(ledger.wrap($0)) }
    var count = 0
    do {
      count = try await consume(pair.stream, window: window, producer: producer)
      ledger.check("consumption_succeeded", true)
    } catch { ledger.check("consumption_succeeded", false) }
    await push.stop()
    await withCheckedContinuation { continuation in producer.stop { continuation.resume() } }
    pair.continuation.finish()
    for await frame in pair.stream { frame.release() }
    lastProducerSnapshot = producer.snapshot()
    ledger.check("all_producer_leases_returned", lastProducerSnapshot["leased"] == 0)
    ledger.check("no_producer_render_failure", lastProducerSnapshot["failures"] == 0)
    ledger.check("twelve_frames_presented", count == 12)
    return count
  }

  private func consume(
    _ stream: AsyncStream<GuestSurfaceFrame>, window: GuestSurfaceWindowController, producer: SurfaceFrameProducer
  ) async throws -> Int {
    var count = 0
    var previousID: UInt64 = 0
    var resized = false
    for await frame in stream {
      ledger.check("frame_id_increases", frame.descriptor.frameID > previousID)
      previousID = frame.descriptor.frameID
      guard await window.presentFrame(frame) else { throw NativeProbeError.failed }
      frame.release()
      for _ in 0..<100 where !ledger.didReturn(frame.descriptor.frameID) {
        try await Task.sleep(for: .milliseconds(1))
      }
      ledger.check("released_after_native_gpu_present", ledger.didReturn(frame.descriptor.frameID))
      count += 1
      if frame.descriptor.width == 768 && frame.descriptor.height == 432 { resized = true }
      if count == 4 {
        let changed = await withCheckedContinuation { continuation in
          producer.resize(width: 768, height: 432) { continuation.resume(returning: $0) }
        }
        ledger.check("producer_resize_succeeded", changed)
      }
      if count == 12 { break }
    }
    ledger.check("resized_frames_presented", resized)
    return count
  }
}

@main
private struct NativeFullscreenProbe {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = NativeProbeDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
