// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal

final class HostMetalFXGPUContext {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let scene: any MTLComputePipelineState
    let nearest: any MTLComputePipelineState
    let temporalInputs: any MTLComputePipelineState

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw HostMetalFXBenchmarkError.allocationFailed }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw HostMetalFXBenchmarkError.shaderUnavailable
            }
            return try device.makeComputePipelineState(function: function)
        }
        scene = try pipeline("syntheticScene")
        nearest = try pipeline("nearestScale")
        temporalInputs = try pipeline("initializeTemporalInputs")
    }

    func texture(
        size: Int, format: MTLPixelFormat = .rgba8Unorm,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite], storage: MTLStorageMode = .private
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw HostMetalFXBenchmarkError.allocationFailed
        }
        return texture
    }

    func commandBuffer() throws -> any MTLCommandBuffer {
        guard let buffer = queue.makeCommandBuffer() else { throw HostMetalFXBenchmarkError.allocationFailed }
        return buffer
    }

    func compute(
        _ pipeline: any MTLComputePipelineState, command: any MTLCommandBuffer,
        size: Int, textures: [any MTLTexture], jitter: SIMD2<Float>? = nil
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw HostMetalFXBenchmarkError.encoderUnavailable
        }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if var jitter { encoder.setBytes(&jitter, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
        encoder.dispatchThreads(
            MTLSize(width: size, height: size, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
    }

    func copy(
        _ source: any MTLTexture, to destination: any MTLTexture, command: any MTLCommandBuffer
    ) throws {
        guard let encoder = command.makeBlitCommandEncoder() else {
            throw HostMetalFXBenchmarkError.encoderUnavailable
        }
        encoder.copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: source.width, height: source.height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    func complete(_ command: any MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, command.error == nil else {
            throw HostMetalFXBenchmarkError.commandFailed
        }
    }

    func clear(_ texture: any MTLTexture) throws {
        let staging = try self.texture(size: texture.width, usage: [], storage: .shared)
        let zeros = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        try zeros.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { throw HostMetalFXBenchmarkError.allocationFailed }
            staging.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                withBytes: address, bytesPerRow: texture.width * 4
            )
        }
        let command = try commandBuffer()
        try copy(staging, to: texture, command: command)
        try complete(command)
    }

    // The same deterministic shader runs at full or half resolution; only reconstruction differs.
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    kernel void syntheticScene(texture2d<float, access::write> color [[texture(0)]],
                               constant float2 &jitter [[buffer(0)]], uint2 pixel [[thread_position_in_grid]]) {
        float2 uv = (float2(pixel) + 0.5f + jitter) / float2(color.get_width(), color.get_height());
        float3 rgb = float3(uv.x, uv.y, 0.25f + 0.5f * uv.x * uv.y);
        float phase = uv.x * 3.0f + uv.y * 7.0f;
        for (uint index = 0; index < 24; ++index) { phase = sin(phase + float(index) * 0.03125f); }
        rgb += 0.025f * phase;
        float grid = float((uint(floor(uv.x * 8.0f)) + uint(floor(uv.y * 8.0f))) & 1);
        color.write(float4(clamp(rgb * 0.8f + 0.1f * grid, 0.0f, 1.0f), 1.0f), pixel);
    }

    kernel void nearestScale(texture2d<float, access::read> input [[texture(0)]],
                             texture2d<float, access::write> output [[texture(1)]],
                             uint2 pixel [[thread_position_in_grid]]) {
        uint2 source = pixel * uint2(input.get_width(), input.get_height()) /
                              uint2(output.get_width(), output.get_height());
        output.write(input.read(source), pixel);
    }

    kernel void initializeTemporalInputs(texture2d<float, access::write> depth [[texture(0)]],
                                         texture2d<float, access::write> motion [[texture(1)]],
                                         uint2 pixel [[thread_position_in_grid]]) {
        depth.write(float4(0.5f), pixel);
        motion.write(float4(0.0f), pixel);
    }
    """#
}
