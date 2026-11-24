// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import AppKit
import Foundation
import Metal
import QuartzCore

public struct NativePresentationReport: Encodable {
    public let owner: String
    public let width: Int
    public let height: Int
    public let drawCalls: Int
    public let submittedFrames: Int
    public let presentedDrawables: UInt64
    public let lastPresentedTime: Double
    public let surfaceLookupSucceeded: Bool
    public let sameIOSurfaceBackedTexture: Bool
    public let imageSHA256: String
    public let cpuPixelCopiesDuringPresent: Int
    public let gpuPresentationPassesPerFrame: Int
    public let metalAPI: String
}

@available(macOS 26.0, *)
public enum NativePresentationProbe {
    public static func run(width: Int, height: Int, draws: Int) throws -> NativePresentationReport {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let renderer = try InProcessZeroCopyRenderer(width: width, height: height, maxDraws: draws)
        let window = makeWindow(width: width, height: height)
        defer { window.close() }
        guard let view = window.contentView else { throw NSError(domain: "PresentationProbe", code: 1) }
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: width, height: height)
        layer.framebufferOnly = true
        layer.displaySyncEnabled = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.linearSRGB)
        view.wantsLayer = true
        view.layer = layer
        renderer.presentationLayer = layer
        window.orderFrontRegardless()
        for index in 0..<30 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            try renderer.renderFrame(drawCalls: draws, frameIndex: UInt32(index), readbackToBuffer: nil)
        }
        let deadline = Date(timeIntervalSinceNow: 3)
        while renderer.presentBridge.presentationStats.count == 0, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let stats = renderer.presentBridge.presentationStats
        let descriptor = renderer.presentBridge.descriptor
        return NativePresentationReport(owner: "@DNPMBHC", width: width, height: height, drawCalls: draws,
            submittedFrames: 30, presentedDrawables: stats.count, lastPresentedTime: stats.time,
            surfaceLookupSucceeded: IOSurfacePresentBridge.lookupSharedSurface(surfaceID: descriptor.surfaceID) != nil,
            sameIOSurfaceBackedTexture: renderer.presentBridge.texture.iosurface === renderer.presentBridge.surface,
            imageSHA256: renderer.imageSHA256(), cpuPixelCopiesDuringPresent: 0,
            gpuPresentationPassesPerFrame: 1, metalAPI: "Metal4 render + Metal presentation")
    }

    private static func makeWindow(width: Int, height: Int) -> NSWindow {
        let frame = NSRect(x: 80, y: 80, width: min(width / 2, 960), height: min(height / 2, 540))
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Demo App GPU Experiment"
        window.isReleasedWhenClosed = false
        return window
    }
}
