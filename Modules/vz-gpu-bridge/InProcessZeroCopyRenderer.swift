// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import CryptoKit
import Darwin
import Foundation
import IOSurface
import Metal
import QuartzCore

public struct DrawBatchCommand {
    public var drawIndex: UInt32
    public var colorSeed: UInt32
    public var offsetX: Float
    public var offsetY: Float
}

public struct BenchmarkSample: Encodable {
    public let mode: String
    public let width: Int
    public let height: Int
    public let drawCalls: Int
    public let frames: Int
    public let warmupFrames: Int
    public let meanMs: Double
    public let p50Ms: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let fps: Double
    public let wallMs: Double
    public let cpuUserMs: Double
    public let cpuSysMs: Double
    public let hostCpuPercent: Double
    public let zeroCopySurfaceActive: Bool
    public let firstPixelBGRA: [UInt8]
    public var imageSHA256 = ""
    public var metalAPI = "Metal4"
    public var gpuCompletionBoundary = "MTLSharedEvent"
    public var frameLatenciesMs: [Double] = []
    public var ringAliasesMetalMemory = false
    public var presentationEncoded = false
    public var submittedCommands: UInt64 = 0
    public var gpuCompletedFrames: UInt64 = 0
}

@available(macOS 26.0, *)
public final class InProcessZeroCopyRenderer {
    public let device: MTLDevice
    public let presentBridge: IOSurfacePresentBridge
    public let ring: SharedCommandRing
    public var presentationLayer: CAMetalLayer?
    private let engine: Metal4Engine
    private let presentationQueue: MTLCommandQueue
    private let presentationPipeline: MTLRenderPipelineState
    private let maxDraws: Int
    private var presentedFrames: UInt64 = 0

    public init(width: Int, height: Int, maxDraws: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Metal4Renderer", code: 1)
        }
        self.device = device
        self.maxDraws = maxDraws
        presentBridge = try IOSurfacePresentBridge(device: device, width: width, height: height)
        ring = try SharedCommandRing(device: device, maxDraws: maxDraws)
        engine = try Metal4Engine(device: device, ring: ring.buffer, texture: presentBridge.texture)
        presentationQueue = queue
        presentationPipeline = try Self.makePresentationPipeline(device: device)
    }

    private static func makePresentationPipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: gpuShaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "present_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "present_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    public static func fillCommands(_ pointer: UnsafeMutableRawPointer, draws: Int, frame: UInt32) {
        let commands = pointer.bindMemory(to: DrawBatchCommand.self, capacity: draws)
        for index in 0..<draws {
            commands[index] = DrawBatchCommand(drawIndex: UInt32(index), colorSeed: frame,
                offsetX: Float(index % 64) / 32.0 - 0.98,
                offsetY: Float((index / 64) % 32) / 16.0 - 0.97)
        }
    }

    public func renderFrame(drawCalls: Int, frameIndex: UInt32,
                            readbackToBuffer: UnsafeMutableRawPointer?,
                            incomingCommands: UnsafeRawPointer? = nil) throws {
        guard drawCalls > 0, drawCalls <= maxDraws else {
            throw NSError(domain: "Metal4Renderer", code: 2)
        }
        let slot = try ring.acquire()
        defer { ring.release() }
        if let incomingCommands {
            slot.pointer.copyMemory(from: incomingCommands,
                                    byteCount: drawCalls * MemoryLayout<DrawBatchCommand>.stride)
        } else {
            Self.fillCommands(slot.pointer, draws: drawCalls, frame: frameIndex)
        }
        ring.publish()
        let value = presentBridge.nextSignalValue()
        try engine.submit(ring: ring.buffer, offset: slot.offset, draws: drawCalls,
                          texture: presentBridge.texture, fence: (presentBridge.sharedEvent, value))
        guard presentBridge.sharedEvent.wait(untilSignaledValue: value, timeoutMS: 10000) else {
            throw NSError(domain: "Metal4Renderer", code: 3)
        }
        try presentIfRequested(value: value)
        if let readbackToBuffer {
            presentBridge.readPixelRegion(into: readbackToBuffer)
        }
    }

    private func presentIfRequested(value: UInt64) throws {
        guard let layer = presentationLayer else { return }
        guard let command = presentationQueue.makeCommandBuffer() else {
            throw NSError(domain: "Metal4Renderer", code: 4)
        }
        command.encodeWaitForEvent(presentBridge.sharedEvent, value: value)
        guard presentBridge.encodePresent(commandBuffer: command, pipeline: presentationPipeline, layer: layer) else {
            throw NSError(domain: "Metal4Renderer", code: 5)
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw NSError(domain: "Metal4Renderer", code: 6)
        }
        presentedFrames &+= 1
    }

    public func imageSHA256() -> String {
        var bytes = [UInt8](repeating: 0, count: presentBridge.descriptor.width * presentBridge.descriptor.height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            if let base = pointer.baseAddress { presentBridge.readPixelRegion(into: base) }
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    public func runZeroCopyBenchmark(drawCalls: Int, frames: Int, warmupFrames: Int) throws -> BenchmarkSample {
        guard frames > 0, warmupFrames >= 0 else { throw NSError(domain: "Benchmark", code: 1) }
        for index in 0..<warmupFrames {
            try renderFrame(drawCalls: drawCalls, frameIndex: UInt32(index), readbackToBuffer: nil)
        }
        let cpuStart = Self.processCpuTimesMs()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var latencies: [Double] = []
        for index in 0..<frames {
            let start = DispatchTime.now().uptimeNanoseconds
            try renderFrame(drawCalls: drawCalls, frameIndex: UInt32(index + warmupFrames), readbackToBuffer: nil)
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
        let cpuEnd = Self.processCpuTimesMs()
        var sample = Self.makeSample(BenchmarkSampleInput(mode: "in_process_zero_copy",
            width: presentBridge.descriptor.width, height: presentBridge.descriptor.height,
            drawCalls: drawCalls, warmupFrames: warmupFrames, latenciesMs: latencies, wallMs: wallMs,
            cpuUserMs: cpuEnd.userMs - cpuStart.userMs, cpuSysMs: cpuEnd.sysMs - cpuStart.sysMs,
            zeroCopySurfaceActive: true, firstPixel: presentBridge.sampleFirstPixelBGRA()))
        sample.imageSHA256 = imageSHA256()
        sample.ringAliasesMetalMemory = ring.aliasesMetalMemory
        sample.presentationEncoded = presentedFrames > 0
        sample.submittedCommands = UInt64(drawCalls * (frames + warmupFrames))
        sample.gpuCompletedFrames = ring.consumed
        return sample
    }
}
