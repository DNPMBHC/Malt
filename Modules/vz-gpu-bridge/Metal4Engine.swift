// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import Metal

@available(macOS 26.0, *)
public final class Metal4Engine {
    public let queue: MTL4CommandQueue
    private let command: MTL4CommandBuffer
    private let allocator: MTL4CommandAllocator
    private let arguments: MTL4ArgumentTable
    private let pipeline: MTLRenderPipelineState
    private let residency: MTLResidencySet

    public init(device: MTLDevice, ring: MTLBuffer, texture: MTLTexture) throws {
        guard let queue = device.makeMTL4CommandQueue(),
              let command = device.makeCommandBuffer(),
              let allocator = device.makeCommandAllocator() else {
            throw NSError(domain: "Metal4Engine", code: 1)
        }
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        arguments = try device.makeArgumentTable(descriptor: tableDescriptor)
        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.initialCapacity = 2
        residency = try device.makeResidencySet(descriptor: residencyDescriptor)
        residency.addAllocation(ring)
        residency.addAllocation(texture)
        residency.commit()
        queue.addResidencySet(residency)
        self.queue = queue
        self.command = command
        self.allocator = allocator
        pipeline = try Self.makePipeline(device: device)
    }

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: gpuShaderSource, options: nil)
        let vertex = MTL4LibraryFunctionDescriptor()
        vertex.library = library
        vertex.name = "vs_main"
        let fragment = MTL4LibraryFunctionDescriptor()
        fragment.library = library
        fragment.name = "fs_main"
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.vertexFunctionDescriptor = vertex
        descriptor.fragmentFunctionDescriptor = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        return try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
    }

    public func submit(ring: MTLBuffer, offset: Int, draws: Int,
                       texture: MTLTexture, fence: (event: MTLSharedEvent, value: UInt64)) throws {
        allocator.reset()
        command.beginCommandBuffer(allocator: allocator)
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw NSError(domain: "Metal4Engine", code: 2)
        }
        arguments.setAddress(ring.gpuAddress + UInt64(offset), index: 0)
        encoder.setArgumentTable(arguments, stages: .vertex)
        encoder.setRenderPipelineState(pipeline)
        for index in 0..<draws {
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3,
                                   instanceCount: 1, baseInstance: index)
        }
        encoder.endEncoding()
        command.endCommandBuffer()
        queue.commit([command])
        queue.signalEvent(fence.event, value: fence.value)
    }
}
