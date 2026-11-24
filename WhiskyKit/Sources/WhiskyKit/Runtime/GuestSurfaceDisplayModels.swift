// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

public enum GuestDisplayResolutionPreset: String, Codable, Equatable, Sendable, CaseIterable {
  case nativeRetinaPointToPoint = "native_retina_point_to_point"
  case highPerformance = "high_performance"
  case followWindow = "follow_window"
}

public struct HostDisplayDescriptor: Codable, Equatable, Sendable {
  public let logicalWidth: Int
  public let logicalHeight: Int
  public let backingScaleFactor: Double
  public let maxRefreshRateHz: Int

  public init(
    logicalWidth: Int,
    logicalHeight: Int,
    backingScaleFactor: Double,
    maxRefreshRateHz: Int
  ) {
    self.logicalWidth = min(16384, max(640, logicalWidth))
    self.logicalHeight = min(16384, max(480, logicalHeight))
    self.backingScaleFactor = backingScaleFactor.isFinite ? min(4, max(1, backingScaleFactor)) : 1
    self.maxRefreshRateHz = max(30, min(240, maxRefreshRateHz))
  }

  public var physicalPixelWidth: Int {
    Int((Double(logicalWidth) * backingScaleFactor).rounded())
  }

  public var physicalPixelHeight: Int {
    Int((Double(logicalHeight) * backingScaleFactor).rounded())
  }

  public var aspectRatio: Double {
    Double(physicalPixelWidth) / Double(max(1, physicalPixelHeight))
  }

  @MainActor
  public static func from(screen: NSScreen) -> HostDisplayDescriptor {
    let frame = screen.frame
    let scale = max(1.0, Double(screen.backingScaleFactor))
    let refresh = max(30, screen.maximumFramesPerSecond)
    return HostDisplayDescriptor(
      logicalWidth: Int(frame.width.rounded()),
      logicalHeight: Int(frame.height.rounded()),
      backingScaleFactor: scale,
      maxRefreshRateHz: refresh
    )
  }

  @MainActor
  public static func primaryOrFallback() -> HostDisplayDescriptor {
    if let screen = NSScreen.main ?? NSScreen.screens.first {
      return from(screen: screen)
    }
    return HostDisplayDescriptor(
      logicalWidth: 1440, logicalHeight: 900, backingScaleFactor: 2.0, maxRefreshRateHz: 60
    )
  }
}

public struct GuestDisplayMode: Codable, Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let refreshRateHz: Int
  public let dpiScalePercent: Int

  public init(width: Int, height: Int, refreshRateHz: Int, dpiScalePercent: Int = 100) {
    self.width = width
    self.height = height
    self.refreshRateHz = refreshRateHz
    self.dpiScalePercent = dpiScalePercent
  }
}

public enum GuestDisplayPolicyError: Error, Equatable, Sendable {
  case dimensionOutOfBounds(width: Int, height: Int)
  case refreshRateOutOfBounds(Int)
  case dpiScaleOutOfBounds(Int)
  case invalidWindowSize
}

public enum GuestDisplayResolutionPolicy {
  public static let allowedWidthRange = 640...7680
  public static let allowedHeightRange = 480...4320
  public static let allowedRefreshRange = 30...240
  public static let allowedDPIScaleRange = 100...300

  public static func validate(_ mode: GuestDisplayMode) throws {
    guard allowedWidthRange.contains(mode.width), allowedHeightRange.contains(mode.height) else {
      throw GuestDisplayPolicyError.dimensionOutOfBounds(width: mode.width, height: mode.height)
    }
    guard allowedRefreshRange.contains(mode.refreshRateHz) else {
      throw GuestDisplayPolicyError.refreshRateOutOfBounds(mode.refreshRateHz)
    }
    guard allowedDPIScaleRange.contains(mode.dpiScalePercent) else {
      throw GuestDisplayPolicyError.dpiScaleOutOfBounds(mode.dpiScalePercent)
    }
  }

  public static func resolve(
    preset: GuestDisplayResolutionPreset,
    hostDisplay: HostDisplayDescriptor,
    windowPixelSize: CGSize? = nil
  ) throws -> GuestDisplayMode {
    let refresh = hostDisplay.maxRefreshRateHz
    let mode: GuestDisplayMode
    switch preset {
    case .nativeRetinaPointToPoint:
      let width = clampEven(hostDisplay.physicalPixelWidth, range: allowedWidthRange)
      let height = clampEven(hostDisplay.physicalPixelHeight, range: allowedHeightRange)
      let dpi = hostDisplay.backingScaleFactor >= 1.75 ? 150 : 100
      mode = GuestDisplayMode(
        width: width, height: height, refreshRateHz: refresh, dpiScalePercent: dpi)
    case .highPerformance:
      let target = highPerformanceDimensions(for: hostDisplay)
      mode = GuestDisplayMode(
        width: target.width, height: target.height, refreshRateHz: refresh, dpiScalePercent: 100
      )
    case .followWindow:
      if let size = windowPixelSize {
        guard size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0, size.width <= 16384, size.height <= 16384
        else {
          throw GuestDisplayPolicyError.invalidWindowSize
        }
      }
      let rawWidth = Int(
        (windowPixelSize.map { Double($0.width) } ?? Double(hostDisplay.physicalPixelWidth))
          .rounded()
      )
      let rawHeight = Int(
        (windowPixelSize.map { Double($0.height) } ?? Double(hostDisplay.physicalPixelHeight))
          .rounded()
      )
      let width = clampEven(rawWidth, range: allowedWidthRange)
      let height = clampEven(rawHeight, range: allowedHeightRange)
      mode = GuestDisplayMode(
        width: width, height: height, refreshRateHz: refresh, dpiScalePercent: 100)
    }
    try validate(mode)
    return mode
  }

  private static func highPerformanceDimensions(
    for hostDisplay: HostDisplayDescriptor
  ) -> (width: Int, height: Int) {
    let isSixteenTen = hostDisplay.aspectRatio <= 1.66
    if hostDisplay.physicalPixelWidth >= 3000 {
      return isSixteenTen ? (2560, 1600) : (2560, 1440)
    }
    return isSixteenTen ? (1920, 1200) : (1920, 1080)
  }

  private static func clampEven(_ value: Int, range: ClosedRange<Int>) -> Int {
    let clamped = min(max(value, range.lowerBound), range.upperBound)
    return clamped - (clamped % 2)
  }
}
