// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation

public struct GuestRelativePointerDelta: Equatable, Sendable {
  public let deltaX: Double
  public let deltaY: Double
  public let timestamp: TimeInterval

  public init(deltaX: Double, deltaY: Double, timestamp: TimeInterval) {
    self.deltaX = deltaX
    self.deltaY = deltaY
    self.timestamp = timestamp
  }
}

public enum GuestRawInputReleaseReason: String, Equatable, Sendable {
  case emergencyHotkey = "emergency_hotkey"
  case windowResignedKey = "window_resigned_key"
  case applicationDeactivated = "application_deactivated"
  case sessionEnded = "session_ended"
  case explicitToggle = "explicit_toggle"
  case windowClosed = "window_closed"
  case inputTransportFailed = "input_transport_failed"
  case captureFailed = "capture_failed"
}

public enum GuestRawInputCaptureState: Equatable, Sendable {
  case released
  case captured
  case releasePending
}

@MainActor
public protocol GuestCursorControlling: AnyObject {
  @discardableResult
  func setCursorCaptured(_ captured: Bool) -> Bool
}

/// Uses only legitimate per-process cursor association (`CGAssociateMouseAndMouseCursorPosition`)
/// and `NSCursor` visibility while the game shell window is key and active.
@MainActor
public final class SystemGuestCursorController: GuestCursorControlling {
  private var isCurrentlyHidden = false

  public init() {}

  @discardableResult
  public func setCursorCaptured(_ captured: Bool) -> Bool {
    if captured {
      guard CGAssociateMouseAndMouseCursorPosition(boolean_t(0)) == .success else { return false }
      if !isCurrentlyHidden {
        NSCursor.hide()
        isCurrentlyHidden = true
      }
    } else {
      let associated = CGAssociateMouseAndMouseCursorPosition(boolean_t(1)) == .success
      if isCurrentlyHidden {
        NSCursor.unhide()
        isCurrentlyHidden = false
      }
      return associated
    }
    return true
  }

  deinit {
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    if isCurrentlyHidden { DispatchQueue.main.async { NSCursor.unhide() } }
  }
}

/// Deterministic FPS Raw Input capture state machine with four failsafe release guarantees:
/// 1) Emergency hotkey (`Cmd+Option+G`), 2) window resigns key, 3) app deactivated (`Cmd+Tab`),
/// 4) game session exits or window closes. Never deadlocks the macOS desktop cursor.
@MainActor
public final class GuestRawInputCaptureStateMachine {
  public private(set) var state: GuestRawInputCaptureState = .released
  public private(set) var lastReleaseReason: GuestRawInputReleaseReason?
  public private(set) var isWindowKey = false
  public private(set) var isApplicationActive = false
  public private(set) var isSessionRunning = false
  public private(set) var cursorReleaseVerified = true

  private let cursorController: any GuestCursorControlling
  private var capturePermitted: Bool
  private var releaseRetry: Task<Void, Never>?
  private var releaseEpoch: UInt64 = 0
  private let onStateChange: ((GuestRawInputCaptureState, GuestRawInputReleaseReason?) -> Void)?
  private let onPointerDelta: ((GuestRelativePointerDelta) -> Void)?

  public init(
    cursorController: any GuestCursorControlling = SystemGuestCursorController(),
    capturePermitted: Bool = true,
    onStateChange: ((GuestRawInputCaptureState, GuestRawInputReleaseReason?) -> Void)? = nil,
    onPointerDelta: ((GuestRelativePointerDelta) -> Void)? = nil
  ) {
    self.cursorController = cursorController
    self.capturePermitted = capturePermitted
    self.onStateChange = onStateChange
    self.onPointerDelta = onPointerDelta
  }

  func revokeCapturePermission() {
    capturePermitted = false
    release(reason: .inputTransportFailed)
  }

  public func updateFocus(windowKey: Bool, applicationActive: Bool) {
    isWindowKey = windowKey
    isApplicationActive = applicationActive
    if !applicationActive {
      release(reason: .applicationDeactivated)
    } else if !windowKey {
      release(reason: .windowResignedKey)
    }
  }

  public func setSessionRunning(_ running: Bool) {
    isSessionRunning = running
    if !running {
      release(reason: .sessionEnded)
    }
  }

  @discardableResult
  public func requestCapture() -> Bool {
    guard capturePermitted, isWindowKey, isApplicationActive, isSessionRunning else {
      return false
    }
    guard state != .releasePending else { return false }
    guard state != .captured else { return true }
    releaseRetry?.cancel()
    releaseRetry = nil
    guard cursorController.setCursorCaptured(true) else {
      release(reason: .captureFailed)
      return false
    }
    state = .captured
    cursorReleaseVerified = false
    lastReleaseReason = nil
    onStateChange?(.captured, nil)
    return true
  }

  public func release(reason: GuestRawInputReleaseReason) {
    releaseRetry?.cancel()
    releaseRetry = nil
    releaseEpoch &+= 1
    let wasCaptured = (state != .released)
    state = .released
    lastReleaseReason = reason
    cursorReleaseVerified = false
    for _ in 0..<3 where !cursorReleaseVerified {
      cursorReleaseVerified = cursorController.setCursorCaptured(false)
    }
    if !cursorReleaseVerified {
      state = .releasePending
      retryCursorRelease(epoch: releaseEpoch)
    }
    if wasCaptured {
      onStateChange?(state, reason)
    }
  }

  private func retryCursorRelease(epoch: UInt64) {
    let controller = cursorController
    releaseRetry = Task { [weak self] in
      for _ in 0..<20 {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        if let self, self.releaseEpoch != epoch { return }
        guard !Task.isCancelled else { return }
        if controller.setCursorCaptured(false) {
          self?.confirmCursorRelease(epoch: epoch)
          return
        }
      }
    }
  }

  private func confirmCursorRelease(epoch: UInt64) {
    guard releaseEpoch == epoch, state == .releasePending else { return }
    state = .released
    cursorReleaseVerified = true
    releaseRetry = nil
    onStateChange?(.released, lastReleaseReason)
  }

  /// Handles `Cmd+Option+G` emergency toggle/release. Returns `true` if the key event was consumed.
  @discardableResult
  public func handleKeyDown(
    charactersIgnoringModifiers: String,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    let relevantFlags = modifierFlags.intersection([.command, .option, .control, .shift])
    guard relevantFlags == [.command, .option],
      charactersIgnoringModifiers.lowercased() == "g"
    else {
      return false
    }
    if state != .released {
      release(reason: .emergencyHotkey)
    } else {
      _ = requestCapture()
    }
    return true
  }

  /// Extracts relative pointer movement only while captured and focused.
  @discardableResult
  public func handleMouseDelta(deltaX: Double, deltaY: Double, timestamp: TimeInterval) -> Bool {
    guard state == .captured, isWindowKey, isApplicationActive, isSessionRunning else {
      return false
    }
    guard deltaX.isFinite, deltaY.isFinite, timestamp.isFinite,
      deltaX != 0 || deltaY != 0
    else { return false }
    onPointerDelta?(GuestRelativePointerDelta(deltaX: deltaX, deltaY: deltaY, timestamp: timestamp))
    return true
  }

}

/// Forward only physical relative deltas to the focused Guest's virtual HID device.
/// Implementations must not manufacture host events or use a Windows process injector.
@MainActor
public protocol GuestRelativePointerSink: AnyObject {
  func submit(_ delta: GuestRelativePointerDelta) -> Bool
}
