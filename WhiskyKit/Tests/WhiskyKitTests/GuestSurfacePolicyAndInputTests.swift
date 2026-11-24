// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IOSurface
import Metal
import XCTest

@testable import WhiskyKit

enum GuestSurfaceTestTypes {
  typealias PushSource = GuestSurfacePushFrameSource
  typealias DisplaySynchronizing = GuestDisplaySynchronizing
  typealias GuestConfiguration = RuntimeGuestConfiguration
  typealias DisplayMode = GuestDisplayMode
  typealias DisplaySnapshot = GuestDisplaySyncSnapshot
  typealias DisplayError = GuestDisplaySyncError
  typealias Provider = WindowsGuestProvider
  typealias Suspending = GuestLifecycleSuspending
  typealias Availability = WindowsGuestAvailability
  typealias LaunchRequest = RuntimeLaunchRequest
  typealias Session = RuntimeSession
  typealias ProviderError = UTMGuestError
  typealias ExitResult = RuntimeExitResult
  typealias PresentationHooks = GuestSurfacePresentationHooks
  typealias Backend = GuestSurfaceBackendKind
  typealias Frame = GuestSurfaceFrame
  typealias Transport = UTMGuestTransport
  typealias VMSnapshot = UTMVMSnapshot
  typealias ProcessResult = UTMProcessResult
  typealias SyntheticSource = SyntheticIOSurfaceFrameSource
  typealias FrameDescriptor = GuestSurfaceFrameDescriptor
  typealias TextureBinding = GuestSurfaceTextureBinding
  typealias BindingError = GuestSurfaceBindingError
  typealias MetalPresenter = GuestSurfaceMetalPresenter
}

@MainActor
private final class MockGuestCursorController: GuestCursorControlling {
  private(set) var isCaptured = false
  private(set) var captureCalls = 0
  private(set) var releaseCalls = 0
  var captureSucceeds = true
  var failedReleaseAttempts = 0

  func setCursorCaptured(_ captured: Bool) -> Bool {
    if captured, !captureSucceeds { return false }
    if !captured, failedReleaseAttempts > 0 {
      failedReleaseAttempts -= 1
      return false
    }
    isCaptured = captured
    if captured {
      captureCalls += 1
    } else {
      releaseCalls += 1
    }
    return true
  }
}

@MainActor
private final class MockGuestPointerSink: GuestRelativePointerSink {
  var acceptsInput = true
  func submit(_ delta: GuestRelativePointerDelta) -> Bool { acceptsInput }
}

final class GuestSurfacePolicyTests: XCTestCase {
  func testRetinaPointToPointAndHighPerformancePresetsMatchAspectRatio() throws {
    let mbp14 = HostDisplayDescriptor(
      logicalWidth: 1512, logicalHeight: 982, backingScaleFactor: 2.0, maxRefreshRateHz: 120
    )
    let pointToPoint = try GuestDisplayResolutionPolicy.resolve(
      preset: .nativeRetinaPointToPoint, hostDisplay: mbp14
    )
    XCTAssertEqual(pointToPoint.width, 3024)
    XCTAssertEqual(pointToPoint.height, 1964)
    XCTAssertEqual(pointToPoint.refreshRateHz, 120)
    XCTAssertEqual(pointToPoint.dpiScalePercent, 150)

    let highPerfMBP = try GuestDisplayResolutionPolicy.resolve(
      preset: .highPerformance, hostDisplay: mbp14
    )
    XCTAssertEqual(highPerfMBP.width, 2560)
    XCTAssertEqual(highPerfMBP.height, 1600)
    XCTAssertEqual(highPerfMBP.refreshRateHz, 120)

    let monitor16by9 = HostDisplayDescriptor(
      logicalWidth: 1920, logicalHeight: 1080, backingScaleFactor: 1.0, maxRefreshRateHz: 60
    )
    let highPerf16by9 = try GuestDisplayResolutionPolicy.resolve(
      preset: .highPerformance, hostDisplay: monitor16by9
    )
    XCTAssertEqual(highPerf16by9.width, 1920)
    XCTAssertEqual(highPerf16by9.height, 1080)
    XCTAssertEqual(highPerf16by9.refreshRateHz, 60)

    let follow = try GuestDisplayResolutionPolicy.resolve(
      preset: .followWindow, hostDisplay: mbp14, windowPixelSize: CGSize(width: 1281, height: 721)
    )
    XCTAssertEqual(follow.width, 1280)
    XCTAssertEqual(follow.height, 720)
  }

  func testInvalidDisplayModesAreRejectedBeforeScriptGeneration() {
    let tooSmall = GuestDisplayMode(width: 320, height: 240, refreshRateHz: 60)
    XCTAssertThrowsError(try GuestDisplaySyncScriptBuilder.applyScript(for: tooSmall)) { error in
      XCTAssertEqual(
        error as? GuestDisplayPolicyError, .dimensionOutOfBounds(width: 320, height: 240)
      )
    }

    let badRefresh = GuestDisplayMode(width: 1920, height: 1080, refreshRateHz: 500)
    XCTAssertThrowsError(try GuestDisplaySyncScriptBuilder.applyScript(for: badRefresh)) { error in
      XCTAssertEqual(error as? GuestDisplayPolicyError, .refreshRateOutOfBounds(500))
    }
  }

  func testWindowFollowUsesBackingPixelsAndRejectsUnsafeNumericInputs() throws {
    let host = HostDisplayDescriptor(
      logicalWidth: 1280, logicalHeight: 800,
      backingScaleFactor: 2, maxRefreshRateHz: 144)
    let mode = try GuestDisplayResolutionPolicy.resolve(preset: .followWindow, hostDisplay: host)
    XCTAssertEqual(mode.width, 2560)
    XCTAssertEqual(mode.height, 1600)
    XCTAssertEqual(mode.refreshRateHz, 144)
    XCTAssertThrowsError(
      try GuestDisplayResolutionPolicy.resolve(
        preset: .followWindow, hostDisplay: host, windowPixelSize: CGSize(width: Double.nan, height: 800)))
    XCTAssertThrowsError(
      try GuestDisplaySyncScriptBuilder.applyScript(
        for: mode, deviceName: "DISPLAY1'; exit 0; '"))
  }

  @MainActor
  func testSyntheticIOSurfaceFrameSourceBindsZeroCopySurfaceToPresentationView() async throws {
    let source = SyntheticIOSurfaceFrameSource(width: 1280, height: 720)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var imported: MTLTexture?
    var surfaceID: IOSurfaceID?
    let (stream, continuation) = AsyncStream<GuestSurfaceFrame>.makeStream()

    try await source.start { frame in
      continuation.yield(frame)
      continuation.finish()
    }
    for await frame in stream {
      surfaceID = frame.descriptor.ioSurfaceID
      imported = try GuestSurfaceTextureBinding.makeTexture(for: frame, device: device)
      frame.release()
    }
    await source.stop()

    XCTAssertEqual(imported?.width, 1280)
    XCTAssertEqual(imported?.height, 720)
    XCTAssertEqual(imported?.storageMode, .shared)
    XCTAssertEqual(IOSurfaceGetID(try XCTUnwrap(imported?.iosurface)), surfaceID)
  }
}

@MainActor
final class GuestSurfaceInputCaptureTests: XCTestCase {
  func testCaptureRequiresKeyActiveAndRunningSession() {
    let cursor = MockGuestCursorController()
    let machine = GuestRawInputCaptureStateMachine(cursorController: cursor)

    XCTAssertFalse(machine.requestCapture())
    machine.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertFalse(machine.requestCapture())

    machine.setSessionRunning(true)
    XCTAssertTrue(machine.requestCapture())
    XCTAssertEqual(machine.state, .captured)
    XCTAssertTrue(cursor.isCaptured)
  }

  func testAllFourFailsafeReleaseTriggersUnlockCursorAndStopDeltaFlow() {
    let cursor = MockGuestCursorController()
    var deltas: [GuestRelativePointerDelta] = []
    let machine = GuestRawInputCaptureStateMachine(
      cursorController: cursor,
      onPointerDelta: { deltas.append($0) }
    )
    machine.setSessionRunning(true)
    machine.updateFocus(windowKey: true, applicationActive: true)

    // 1. Emergency hotkey Cmd+Option+G
    XCTAssertTrue(machine.requestCapture())
    XCTAssertTrue(machine.handleMouseDelta(deltaX: 12.5, deltaY: -4.0, timestamp: 1.0))
    XCTAssertEqual(deltas.count, 1)
    XCTAssertTrue(
      machine.handleKeyDown(charactersIgnoringModifiers: "g", modifierFlags: [.command, .option])
    )
    XCTAssertEqual(machine.state, .released)
    XCTAssertEqual(machine.lastReleaseReason, .emergencyHotkey)
    XCTAssertFalse(cursor.isCaptured)
    XCTAssertFalse(machine.handleMouseDelta(deltaX: 5.0, deltaY: 5.0, timestamp: 2.0))

    // 2. Window resigns key
    XCTAssertTrue(machine.requestCapture())
    machine.updateFocus(windowKey: false, applicationActive: true)
    XCTAssertEqual(machine.state, .released)
    XCTAssertEqual(machine.lastReleaseReason, .windowResignedKey)

    // 3. Application deactivated (Cmd+Tab)
    machine.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertTrue(machine.requestCapture())
    machine.updateFocus(windowKey: true, applicationActive: false)
    XCTAssertEqual(machine.state, .released)
    XCTAssertEqual(machine.lastReleaseReason, .applicationDeactivated)

    // 4. Session ends
    machine.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertTrue(machine.requestCapture())
    machine.setSessionRunning(false)
    XCTAssertEqual(machine.state, .released)
    XCTAssertEqual(machine.lastReleaseReason, .sessionEnded)
    XCTAssertFalse(cursor.isCaptured)
  }
  func testCaptureFailureAndTransientReleaseFailureRemainRecoverable() {
    let cursor = MockGuestCursorController()
    let machine = GuestRawInputCaptureStateMachine(cursorController: cursor)
    machine.updateFocus(windowKey: true, applicationActive: true)
    machine.setSessionRunning(true)
    cursor.captureSucceeds = false
    XCTAssertFalse(machine.requestCapture())
    XCTAssertEqual(machine.state, .released)
    XCTAssertTrue(machine.cursorReleaseVerified)
    cursor.captureSucceeds = true
    XCTAssertTrue(machine.requestCapture())
    cursor.failedReleaseAttempts = 2
    machine.release(reason: .windowClosed)
    XCTAssertEqual(machine.state, .released)
    XCTAssertTrue(machine.cursorReleaseVerified)
    XCTAssertFalse(cursor.isCaptured)
  }

  func testRepeatedCaptureReleaseAndNonFiniteDeltasDoNotUnbalanceCursor() {
    let cursor = MockGuestCursorController()
    let machine = GuestRawInputCaptureStateMachine(cursorController: cursor)
    machine.updateFocus(windowKey: true, applicationActive: true)
    machine.setSessionRunning(true)
    for _ in 0..<100 {
      XCTAssertTrue(machine.requestCapture())
      XCTAssertTrue(machine.requestCapture())
      XCTAssertFalse(machine.handleMouseDelta(deltaX: .nan, deltaY: 1, timestamp: 1))
      machine.release(reason: .windowClosed)
      machine.release(reason: .sessionEnded)
      XCTAssertTrue(machine.cursorReleaseVerified)
    }
    XCTAssertEqual(cursor.captureCalls, 100)
    XCTAssertEqual(machine.state, .released)
  }

  func testNoInputConnectionCannotCaptureAndWrongHotkeysStayUnconsumed() {
    let cursor = MockGuestCursorController()
    let machine = GuestRawInputCaptureStateMachine(cursorController: cursor, capturePermitted: false)
    machine.updateFocus(windowKey: true, applicationActive: true)
    machine.setSessionRunning(true)
    XCTAssertFalse(machine.requestCapture())
    XCTAssertFalse(machine.handleKeyDown(charactersIgnoringModifiers: "g", modifierFlags: [.command]))
    XCTAssertFalse(machine.handleKeyDown(charactersIgnoringModifiers: "g", modifierFlags: [.command, .option, .shift]))
    XCTAssertEqual(cursor.captureCalls, 0)
  }

  func testPersistentReleaseFailureIsReportedAndEmergencyKeyRetriesIt() {
    let cursor = MockGuestCursorController()
    let machine = GuestRawInputCaptureStateMachine(cursorController: cursor)
    machine.updateFocus(windowKey: true, applicationActive: true)
    machine.setSessionRunning(true)
    XCTAssertTrue(machine.requestCapture())
    cursor.failedReleaseAttempts = 100
    machine.release(reason: .windowClosed)
    XCTAssertEqual(machine.state, .releasePending)
    XCTAssertFalse(machine.cursorReleaseVerified)
    XCTAssertFalse(machine.requestCapture())
    cursor.failedReleaseAttempts = 0
    XCTAssertTrue(machine.handleKeyDown(charactersIgnoringModifiers: "g", modifierFlags: [.command, .option]))
    XCTAssertEqual(machine.state, .released)
    XCTAssertTrue(machine.cursorReleaseVerified)
  }

  func testNativeWindowDelegateAndApplicationObserverReleaseWithoutGlobalEvents() {
    _ = NSApplication.shared
    let cursor = MockGuestCursorController()
    let controller = GuestSurfaceWindowController(
      initialMetrics: GuestSurfaceOverlayMetrics(
        width: 1280, height: 720, refreshRateHz: 60, backend: .syntheticTest, rawInputCaptured: false),
      cursorController: cursor, onPointerDelta: { _ in })
    XCTAssertTrue(controller.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
    controller.setSessionRunning(true)
    controller.inputStateMachine.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertTrue(controller.inputStateMachine.requestCapture())
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    XCTAssertFalse(cursor.isCaptured)
    controller.inputStateMachine.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertTrue(controller.inputStateMachine.requestCapture())
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    XCTAssertFalse(cursor.isCaptured)
    controller.closeAndReleaseResources()
    XCTAssertTrue(controller.inputStateMachine.cursorReleaseVerified)
  }

  func testInputTransportFailureAndDisappearanceReleaseTheNativeWindowCapture() {
    _ = NSApplication.shared
    for rejectsInput in [true, false] {
      let cursor = MockGuestCursorController()
      var sink: MockGuestPointerSink? = MockGuestPointerSink()
      let controller = GuestSurfaceWindowController(
        initialMetrics: GuestSurfaceOverlayMetrics(
          width: 1280, height: 720, refreshRateHz: 60, backend: .syntheticTest, rawInputCaptured: false),
        cursorController: cursor, pointerSink: sink)
      controller.setSessionRunning(true)
      let machine = controller.inputStateMachine
      machine.updateFocus(windowKey: true, applicationActive: true)
      XCTAssertTrue(machine.requestCapture())
      if rejectsInput { sink?.acceptsInput = false } else { sink = nil }
      XCTAssertTrue(machine.handleMouseDelta(deltaX: 3, deltaY: 2, timestamp: 1))
      XCTAssertEqual(machine.state, .released)
      XCTAssertEqual(machine.lastReleaseReason, .inputTransportFailed)
      XCTAssertTrue(machine.cursorReleaseVerified)
      XCTAssertFalse(cursor.isCaptured)
      XCTAssertFalse(machine.requestCapture())
      XCTAssertTrue(machine.handleKeyDown(charactersIgnoringModifiers: "g", modifierFlags: [.command, .option]))
      XCTAssertFalse(cursor.isCaptured)
      controller.closeAndReleaseResources()
    }
  }

}

@MainActor
extension GuestSurfacePolicyTests {
  func testTransientCursorReleaseFailureAutomaticallyRecoversWithoutAnotherEvent() async throws {
    let cursor = MockGuestCursorController()
    let machine = GuestRawInputCaptureStateMachine(cursorController: cursor)
    machine.setSessionRunning(true)
    machine.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertTrue(machine.requestCapture())
    cursor.failedReleaseAttempts = 4
    machine.release(reason: .windowClosed)
    XCTAssertEqual(machine.state, .releasePending)
    XCTAssertFalse(machine.cursorReleaseVerified)
    for _ in 0..<100 where !machine.cursorReleaseVerified {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(machine.cursorReleaseVerified)
    XCTAssertEqual(machine.state, .released)
    XCTAssertFalse(cursor.isCaptured)
    XCTAssertEqual(machine.lastReleaseReason, .windowClosed)
  }

  func testCursorRetryRetainsControllerAfterWindowStateMachineIsDestroyed() async throws {
    let cursor = MockGuestCursorController()
    var machine: GuestRawInputCaptureStateMachine? = GuestRawInputCaptureStateMachine(cursorController: cursor)
    machine?.setSessionRunning(true)
    machine?.updateFocus(windowKey: true, applicationActive: true)
    XCTAssertTrue(machine?.requestCapture() == true)
    cursor.failedReleaseAttempts = 4
    machine?.release(reason: .windowClosed)
    XCTAssertTrue(cursor.isCaptured)
    machine = nil
    for _ in 0..<100 where cursor.isCaptured {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(cursor.isCaptured)
    XCTAssertEqual(cursor.releaseCalls, 1)
  }
}
