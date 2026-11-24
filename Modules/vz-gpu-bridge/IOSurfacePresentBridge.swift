// SPDX-License-Identifier: GPL-3.0-or-later
// Zero-copy IOSurface <-> MTLTexture <-> CAMetalLayer presentation bridge with MTLSharedEvent.
// Owner: @DNPMBHC

import AppKit
import CoreVideo
import Foundation
import IOSurface
import Metal
import QuartzCore

public struct ZeroCopySurfaceDescriptor {
    public let surfaceID: IOSurfaceID
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: MTLPixelFormat
}

public final class IOSurfacePresentBridge {
    public let device: MTLDevice
    public let surface: IOSurfaceRef
    public let texture: MTLTexture
    public let sharedEvent: MTLSharedEvent
    public let descriptor: ZeroCopySurfaceDescriptor
    public private(set) var signalValue: UInt64 = 0
    private let presentationLock = NSLock()
    private var presentedCount: UInt64 = 0
    private var lastPresentedTime: Double = 0

    public var presentationStats: (count: UInt64, time: Double) {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        return (presentedCount, lastPresentedTime)
    }

    public init(device: MTLDevice, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw NSError(domain: "vz-gpu-bridge", code: 101)
        }
        let bytesPerElement = 4
        let bytesPerRow = ((width * bytesPerElement) + 255) & ~255
        let props: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA
        ]
        guard let createdSurface = IOSurfaceCreate(props as CFDictionary) else {
            throw NSError(domain: "vz-gpu-bridge", code: 102)
        }
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let boundTex = device.makeTexture(descriptor: texDesc, iosurface: createdSurface, plane: 0),
              let event = device.makeSharedEvent() else {
            throw NSError(domain: "vz-gpu-bridge", code: 103)
        }
        self.device = device
        self.surface = createdSurface
        self.texture = boundTex
        self.sharedEvent = event
        self.descriptor = ZeroCopySurfaceDescriptor(
            surfaceID: IOSurfaceGetID(createdSurface),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8Unorm
        )
    }

    public func nextSignalValue() -> UInt64 {
        signalValue &+= 1
        return signalValue
    }

    public func signalNextFence(on commandBuffer: MTLCommandBuffer) -> UInt64 {
        let nextVal = nextSignalValue()
        commandBuffer.encodeSignalEvent(sharedEvent, value: nextVal)
        return nextVal
    }

    public func readPixelRegion(into destination: UnsafeMutableRawPointer) {
        let region = MTLRegionMake2D(0, 0, descriptor.width, descriptor.height)
        texture.getBytes(
            destination,
            bytesPerRow: descriptor.width * 4,
            from: region,
            mipmapLevel: 0
        )
    }

    public func sampleFirstPixelBGRA() -> [UInt8] {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let region = MTLRegionMake2D(0, 0, 1, 1)
        texture.getBytes(&pixel, bytesPerRow: 4, from: region, mipmapLevel: 0)
        return pixel
    }

    public func encodePresent(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        layer: CAMetalLayer
    ) -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        drawable.addPresentedHandler { [weak self] frame in
            guard let self else { return }
            self.presentationLock.lock()
            self.presentedCount &+= 1
            self.lastPresentedTime = frame.presentedTime
            self.presentationLock.unlock()
        }
        commandBuffer.present(drawable)
        return true
    }

    public static func lookupSharedSurface(surfaceID: IOSurfaceID) -> IOSurfaceRef? {
        IOSurfaceLookup(surfaceID)
    }
}
