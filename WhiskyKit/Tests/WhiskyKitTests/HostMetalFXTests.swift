// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Metal
import MetalFX
import XCTest
@testable import WhiskyKit

final class HostMetalFXTests: XCTestCase {
    func testMetalAPIValidationIsEnabledForHostChecks() throws {
        guard ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] == "1" else {
            throw XCTSkip("Rerun host checks with MTL_DEBUG_LAYER=1 to verify the Metal API contract.")
        }
    }

    func testMetalFXSpatialCapabilityAndCommandBufferExecution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available on this host.")
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            throw XCTSkip("This device does not support MetalFX spatial scaling.")
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = .rgba8Unorm
        descriptor.outputTextureFormat = .rgba8Unorm
        descriptor.inputWidth = 16
        descriptor.inputHeight = 16
        descriptor.outputWidth = 32
        descriptor.outputHeight = 32
        let scaler = try XCTUnwrap(descriptor.makeSpatialScaler(device: device))
        let input = try makeTexture(device, 16, 16, .rgba8Unorm, scaler.colorTextureUsage)
        let output = try makeTexture(device, 32, 32, .rgba8Unorm, scaler.outputTextureUsage, storageMode: .private)
        try writePixels(Data(repeating: 128, count: 16 * 16 * 4), to: input, width: 16, bytesPerPixel: 4)
        scaler.colorTexture = input
        scaler.inputContentWidth = 16
        scaler.inputContentHeight = 16
        scaler.outputTexture = output

        let pixels = try executeAndReadBack(device: device, output: output) { commandBuffer in
            scaler.encode(commandBuffer: commandBuffer)
        }
        XCTAssertTrue(pixels.contains(where: { $0 != 0 }))
    }

    func testMetalFXTemporalCapabilityAndCommandBufferExecution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available on this host.")
        }
        guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else {
            throw XCTSkip("This device does not support MetalFX temporal scaling.")
        }
        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.colorTextureFormat = .rgba8Unorm
        descriptor.depthTextureFormat = .r32Float
        descriptor.motionTextureFormat = .rg16Float
        descriptor.outputTextureFormat = .rgba8Unorm
        descriptor.inputWidth = 16
        descriptor.inputHeight = 16
        descriptor.outputWidth = 32
        descriptor.outputHeight = 32
        descriptor.isAutoExposureEnabled = true
        let scaler = try XCTUnwrap(descriptor.makeTemporalScaler(device: device))
        let color = try makeTexture(device, 16, 16, .rgba8Unorm, scaler.colorTextureUsage)
        let depth = try makeTexture(device, 16, 16, .r32Float, scaler.depthTextureUsage)
        let motion = try makeTexture(device, 16, 16, .rg16Float, scaler.motionTextureUsage)
        let output = try makeTexture(device, 32, 32, .rgba8Unorm, scaler.outputTextureUsage, storageMode: .private)
        try writePixels(Data(repeating: 128, count: 16 * 16 * 4), to: color, width: 16, bytesPerPixel: 4)
        try writePixels(Data(repeating: 0, count: 16 * 16 * 4), to: depth, width: 16, bytesPerPixel: 4)
        try writePixels(Data(repeating: 0, count: 16 * 16 * 4), to: motion, width: 16, bytesPerPixel: 4)
        scaler.colorTexture = color
        scaler.depthTexture = depth
        scaler.motionTexture = motion
        scaler.outputTexture = output
        scaler.inputContentWidth = 16
        scaler.inputContentHeight = 16
        scaler.reset = true

        let pixels = try executeAndReadBack(device: device, output: output) { commandBuffer in
            scaler.encode(commandBuffer: commandBuffer)
        }
        XCTAssertTrue(pixels.contains(where: { $0 != 0 }))
    }

    func testExtendedGraphicsQueriesSeparateSupportFromActualUse() throws {
        let absent = HostCapabilityProvider.extendedGraphicsCapabilities(for: nil)
        XCTAssertFalse(absent.devicePresent)
        XCTAssertFalse(absent.frameInterpolationSupported)
        XCTAssertEqual(absent.actualFeatureUse, "not-tested")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let first = HostCapabilityProvider.extendedGraphicsCapabilities(for: device)
        XCTAssertTrue(first.devicePresent)
        XCTAssertEqual(first, HostCapabilityProvider.extendedGraphicsCapabilities(for: device))
        XCTAssertEqual(first.actualFeatureUse, "not-tested")
        if ProcessInfo.processInfo.environment["HOST_WRITE_GRAPHICS_SUPPORT"] == "1" {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let output = package.appendingPathComponent("Documentation/HostExtendedGraphicsSupport.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(first).write(to: output, options: .atomic)
        }
    }

    private func makeTexture(
        _ device: any MTLDevice,
        _ width: Int,
        _ height: Int,
        _ format: MTLPixelFormat,
        _ usage: MTLTextureUsage,
        storageMode: MTLStorageMode = .shared
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func writePixels(_ data: Data, to texture: any MTLTexture, width: Int, bytesPerPixel: Int) throws {
        try data.withUnsafeBytes { bytes in
            let address = try XCTUnwrap(bytes.baseAddress)
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, width), mipmapLevel: 0,
                withBytes: address, bytesPerRow: width * bytesPerPixel
            )
        }
    }

    private func executeAndReadBack(
        device: any MTLDevice,
        output: any MTLTexture,
        encode: (any MTLCommandBuffer) -> Void
    ) throws -> [UInt8] {
        let readback = try makeTexture(device, output.width, output.height, output.pixelFormat, [])
        let zeros = [UInt8](repeating: 0, count: output.width * output.height * 4)
        try zeros.withUnsafeBytes { bytes in
            let address = try XCTUnwrap(bytes.baseAddress)
            readback.replace(
                region: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0,
                withBytes: address, bytesPerRow: output.width * 4
            )
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        // Start from known pixels so unwritten private GPU memory cannot satisfy the output assertion.
        try copyTexture(readback, to: output, commandBuffer: commandBuffer)
        encode(commandBuffer)
        try copyTexture(output, to: readback, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        var bytes = [UInt8](repeating: 0, count: output.width * output.height * 4)
        readback.getBytes(
            &bytes, bytesPerRow: output.width * 4,
            from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0
        )
        return bytes
    }

    private func copyTexture(
        _ source: any MTLTexture,
        to destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }
}
