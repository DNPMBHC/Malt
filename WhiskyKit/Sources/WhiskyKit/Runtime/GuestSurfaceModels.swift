// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IOSurface
import Metal

public enum GuestSurfaceBackendKind: String, Codable, Equatable, Sendable {
  case vzZeroCopyIOSurface = "vz_zero_copy_iosurface"
  case utmViogpu3D = "utm_viogpu3d"
  case syntheticTest = "synthetic_test"
  case unavailable

  public var displayTitle: String {
    switch self {
    case .vzZeroCopyIOSurface: "VZ Zero-Copy IOSurface"
    case .utmViogpu3D: "UTM WHQL viogpu3d"
    case .syntheticTest: "Synthetic IOSurface"
    case .unavailable: "Frame source unavailable"
    }
  }
}

public enum GuestSurfacePixelFormat: String, Codable, Equatable, Sendable {
  case bgra8Unorm = "BGRA8Unorm"
  case rgba16Float = "RGBA16Float"

  public var osType: OSType {
    switch self {
    case .bgra8Unorm: kCVPixelFormatType_32BGRA
    case .rgba16Float: kCVPixelFormatType_64RGBAHalf
    }
  }

  public var bytesPerElement: Int {
    switch self {
    case .bgra8Unorm: 4
    case .rgba16Float: 8
    }
  }
}

public struct GuestSurfaceFrameDescriptor: Codable, Equatable, Sendable {
  public let frameID: UInt64
  public let width: Int
  public let height: Int
  public let pixelFormat: GuestSurfacePixelFormat
  public let ioSurfaceID: UInt32?
  public let sharedEventSignaledValue: UInt64?
  public let presentedAtNanos: UInt64
  public let backend: GuestSurfaceBackendKind

  public init(
    frameID: UInt64,
    width: Int,
    height: Int,
    pixelFormat: GuestSurfacePixelFormat = .bgra8Unorm,
    ioSurfaceID: UInt32? = nil,
    sharedEventSignaledValue: UInt64? = nil,
    presentedAtNanos: UInt64 = DispatchTime.now().uptimeNanoseconds,
    backend: GuestSurfaceBackendKind
  ) {
    self.frameID = frameID
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
    self.ioSurfaceID = ioSurfaceID
    self.sharedEventSignaledValue = sharedEventSignaledValue
    self.presentedAtNanos = presentedAtNanos
    self.backend = backend
  }
}

/// Zero-copy frame container bridging Plan B (`VZCustomVirtioDevice` -> `IOSurface`) to `CALayer`.
public final class GuestSurfaceFrame: @unchecked Sendable {
  public let descriptor: GuestSurfaceFrameDescriptor
  public let surface: IOSurfaceRef?
  public let sharedEvent: MTLSharedEvent?
  private let releaseLock = NSLock()
  private var releaseHandler: (@Sendable () -> Void)?

  public init(
    descriptor: GuestSurfaceFrameDescriptor,
    surface: IOSurfaceRef? = nil,
    sharedEvent: MTLSharedEvent? = nil,
    onRelease: (@Sendable () -> Void)? = nil
  ) {
    self.descriptor = descriptor
    self.surface = surface
    self.sharedEvent = sharedEvent
    self.releaseHandler = onRelease
  }

  public func release() {
    releaseLock.lock()
    let handler = releaseHandler
    releaseHandler = nil
    releaseLock.unlock()
    handler?()
  }

  deinit { release() }
}

public protocol GuestSurfaceFrameSource: Sendable {
  var backendKind: GuestSurfaceBackendKind { get }
  func start(onFrame: @escaping @Sendable (GuestSurfaceFrame) -> Void) async throws
  func stop() async
}

/// Local real `IOSurface`-backed frame source for deterministic zero-copy contract verification.
public actor SyntheticIOSurfaceFrameSource: GuestSurfaceFrameSource {
  public nonisolated let backendKind: GuestSurfaceBackendKind = .syntheticTest
  private let width: Int
  private let height: Int
  private let pixelFormat: GuestSurfacePixelFormat
  private var surface: IOSurfaceRef?
  private var frameCounter: UInt64 = 0
  private var onFrame: (@Sendable (GuestSurfaceFrame) -> Void)?

  public init(
    width: Int = 1280, height: Int = 720, pixelFormat: GuestSurfacePixelFormat = .bgra8Unorm
  ) {
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
  }

  public func start(onFrame: @escaping @Sendable (GuestSurfaceFrame) -> Void) async throws {
    self.onFrame = onFrame
    if surface == nil {
      let bytesPerElement = pixelFormat.bytesPerElement
      let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytesPerElement)
      let allocSize = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bytesPerRow * height)
      let properties: [CFString: Any] = [
        kIOSurfaceWidth: width,
        kIOSurfaceHeight: height,
        kIOSurfaceBytesPerElement: bytesPerElement,
        kIOSurfaceBytesPerRow: bytesPerRow,
        kIOSurfaceAllocSize: allocSize,
        kIOSurfacePixelFormat: pixelFormat.osType
      ]
      surface = IOSurfaceCreate(properties as CFDictionary)
    }
    emitNextFrame()
  }

  public func emitNextFrame() {
    guard let onFrame, let surface else { return }
    frameCounter += 1
    let surfaceID = IOSurfaceGetID(surface)
    let descriptor = GuestSurfaceFrameDescriptor(
      frameID: frameCounter,
      width: width,
      height: height,
      pixelFormat: pixelFormat,
      ioSurfaceID: surfaceID == 0 ? nil : surfaceID,
      backend: backendKind
    )
    onFrame(GuestSurfaceFrame(descriptor: descriptor, surface: surface))
  }

  public func stop() async {
    onFrame = nil
    surface = nil
  }
}

public enum GuestHeadlessIdlePolicy: String, Codable, Equatable, Sendable {
  case suspendOnExit = "suspend_on_exit"
  case keepWarm = "keep_warm"
}

public enum GuestDisplayDPIStatus: String, Codable, Equatable, Sendable {
  case unchanged
  case applied
  case unsupported
}

public struct GuestDisplaySyncSnapshot: Codable, Equatable, Sendable {
  public let previousMode: GuestDisplayMode
  public let appliedMode: GuestDisplayMode
  public let displayDeviceName: String
  public let changeDisplayStatusCode: Int
  public let dpiSynchronizationStatus: GuestDisplayDPIStatus

  public init(
    previousMode: GuestDisplayMode,
    appliedMode: GuestDisplayMode,
    displayDeviceName: String = #"\\.\DISPLAY1"#,
    changeDisplayStatusCode: Int = 0,
    dpiSynchronizationStatus: GuestDisplayDPIStatus = .unchanged
  ) {
    self.previousMode = previousMode
    self.appliedMode = appliedMode
    self.displayDeviceName = displayDeviceName
    self.changeDisplayStatusCode = changeDisplayStatusCode
    self.dpiSynchronizationStatus = dpiSynchronizationStatus
  }
}

public struct GuestSurfaceSessionConfiguration: Equatable, Sendable {
  public let resolutionPreset: GuestDisplayResolutionPreset
  public let hostDisplay: HostDisplayDescriptor
  public let idlePolicy: GuestHeadlessIdlePolicy
  public let enableRawInputOnFocus: Bool
  public let showOverlayHUD: Bool

  public init(
    resolutionPreset: GuestDisplayResolutionPreset = .highPerformance,
    hostDisplay: HostDisplayDescriptor,
    idlePolicy: GuestHeadlessIdlePolicy = .keepWarm,
    enableRawInputOnFocus: Bool = true,
    showOverlayHUD: Bool = true
  ) {
    self.resolutionPreset = resolutionPreset
    self.hostDisplay = hostDisplay
    self.idlePolicy = idlePolicy
    self.enableRawInputOnFocus = enableRawInputOnFocus
    self.showOverlayHUD = showOverlayHUD
  }
}

public struct GuestSurfaceOverlayMetrics: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let refreshRateHz: Int
  public let backend: GuestSurfaceBackendKind
  public let rawInputCaptured: Bool
  public let releaseShortcutHint: String
  public let cursorReleaseVerified: Bool

  public init(
    width: Int,
    height: Int,
    refreshRateHz: Int,
    backend: GuestSurfaceBackendKind,
    rawInputCaptured: Bool,
    releaseShortcutHint: String = "⌘⌥G",
    cursorReleaseVerified: Bool = true
  ) {
    self.width = width
    self.height = height
    self.refreshRateHz = refreshRateHz
    self.backend = backend
    self.rawInputCaptured = rawInputCaptured
    self.releaseShortcutHint = releaseShortcutHint
    self.cursorReleaseVerified = cursorReleaseVerified
  }

  public var summaryLabel: String {
    let captureText = rawInputCaptured ? "Raw Input 锁定" : (cursorReleaseVerified ? "光标自由" : "光标释放待确认")
    return
      "\(width)×\(height) @ \(refreshRateHz)Hz · \(backend.displayTitle) · \(captureText) (\(releaseShortcutHint))"
  }
}
