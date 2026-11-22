// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import MetalFX

final class HostMetalFXGPUPath {
    let requestedRoute: HostMetalFXRoute
    private let context: HostMetalFXGPUContext
    private let input: any MTLTexture
    private let output: any MTLTexture
    private let spatial: (any MTLFXSpatialScaler)?
    private let temporal: (any MTLFXTemporalScaler)?
    private(set) var executedRoute: HostMetalFXRoute
    private var supported: Bool?
    private var creationSucceeded: Bool?
    private var fallbackReason: String?
    private var completedFrames = 0

    init(
        route: HostMetalFXRoute, configuration: HostMetalFXBenchmarkConfiguration,
        context: HostMetalFXGPUContext, factories: HostMetalFXFactories
    ) throws {
        requestedRoute = route
        executedRoute = route
        self.context = context
        let inputSize = route == .native ? configuration.outputSize : configuration.inputSize
        supported = true
        let setup = Self.makeScalers(route, size: inputSize, outputSize: configuration.outputSize,
                                     device: context.device, factories: factories)
        spatial = setup.spatial
        temporal = setup.temporal
        if route == .spatial || route == .temporal {
            supported = setup.supported
            creationSucceeded = setup.supported ? (spatial != nil || temporal != nil) : nil
            if creationSucceeded != true {
                executedRoute = .nearest
                fallbackReason = setup.supported ? "scaler_creation_failed" : "device_unsupported"
            }
        }
        let colorUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let inputUsage = colorUsage.union(spatial?.colorTextureUsage ?? []).union(temporal?.colorTextureUsage ?? [])
        let outputUsage = colorUsage.union(spatial?.outputTextureUsage ?? []).union(temporal?.outputTextureUsage ?? [])
        output = try context.texture(size: configuration.outputSize, usage: outputUsage)
        input = route == .native ? output : try context.texture(size: inputSize, usage: inputUsage)
        try context.clear(output)
        try configureScalers()
    }

    private struct Scalers {
        let supported: Bool
        let spatial: (any MTLFXSpatialScaler)?
        let temporal: (any MTLFXTemporalScaler)?
    }

    private static func makeScalers(
        _ route: HostMetalFXRoute, size: Int, outputSize: Int, device: any MTLDevice, factories: HostMetalFXFactories
    ) -> Scalers {
        switch route {
        case .spatial:
            guard factories.supportsSpatial(device) else {
                return Scalers(supported: false, spatial: nil, temporal: nil)
            }
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.colorTextureFormat = .rgba8Unorm
            descriptor.outputTextureFormat = .rgba8Unorm
            descriptor.colorProcessingMode = .linear
            descriptor.inputWidth = size
            descriptor.inputHeight = size
            descriptor.outputWidth = outputSize
            descriptor.outputHeight = outputSize
            return Scalers(supported: true, spatial: factories.makeSpatial(descriptor, device), temporal: nil)
        case .temporal:
            guard factories.supportsTemporal(device) else {
                return Scalers(supported: false, spatial: nil, temporal: nil)
            }
            let descriptor = MTLFXTemporalScalerDescriptor()
            descriptor.colorTextureFormat = .rgba8Unorm
            descriptor.depthTextureFormat = .r32Float
            descriptor.motionTextureFormat = .rg16Float
            descriptor.outputTextureFormat = .rgba8Unorm
            descriptor.inputWidth = size
            descriptor.inputHeight = size
            descriptor.outputWidth = outputSize
            descriptor.outputHeight = outputSize
            descriptor.isAutoExposureEnabled = true
            return Scalers(supported: true, spatial: nil, temporal: factories.makeTemporal(descriptor, device))
        default:
            return Scalers(supported: true, spatial: nil, temporal: nil)
        }
    }

    private func configureScalers() throws {
        if let spatial {
            spatial.colorTexture = input
            spatial.outputTexture = output
            spatial.inputContentWidth = input.width
            spatial.inputContentHeight = input.height
        }
        if let temporal {
            let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
            let depth = try context.texture(size: input.width, format: .r32Float,
                                            usage: usage.union(temporal.depthTextureUsage))
            let motion = try context.texture(size: input.width, format: .rg16Float,
                                             usage: usage.union(temporal.motionTextureUsage))
            let command = try context.commandBuffer()
            try context.compute(context.temporalInputs, command: command, size: input.width, textures: [depth, motion])
            try context.complete(command)
            temporal.colorTexture = input
            temporal.depthTexture = depth
            temporal.motionTexture = motion
            temporal.outputTexture = output
            temporal.inputContentWidth = input.width
            temporal.inputContentHeight = input.height
            temporal.motionVectorScaleX = 1
            temporal.motionVectorScaleY = 1
            temporal.preExposure = 1
            temporal.isDepthReversed = false
        }
    }

    func frame() throws -> (cpu: Double, gpu: Double?) {
        do {
            return try encodeFrame()
        } catch {
            guard executedRoute == .spatial || executedRoute == .temporal else { throw error }
            executedRoute = .nearest
            fallbackReason = "scaler_command_failed"
            // A failed optional reconstruction still produces a real image through the baseline consumer.
            return try encodeFrame()
        }
    }

    private func encodeFrame() throws -> (cpu: Double, gpu: Double?) {
        let start = DispatchTime.now().uptimeNanoseconds
        let command = try context.commandBuffer()
        let jitter = executedRoute == .temporal ? Self.jitter(frame: completedFrames) : SIMD2<Float>.zero
        try context.compute(context.scene, command: command, size: input.width, textures: [input], jitter: jitter)
        switch executedRoute {
        case .spatial:
            spatial?.encode(commandBuffer: command)
        case .temporal:
            temporal?.reset = completedFrames == 0
            temporal?.jitterOffsetX = jitter.x
            temporal?.jitterOffsetY = jitter.y
            temporal?.encode(commandBuffer: command)
        case .nearest:
            try context.compute(context.nearest, command: command, size: output.width, textures: [input, output])
        default:
            break
        }
        command.commit()
        let cpu = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        command.waitUntilCompleted()
        guard command.status == .completed, command.error == nil else { throw HostMetalFXBenchmarkError.commandFailed }
        completedFrames += 1
        let startTime = command.gpuStartTime
        let endTime = command.gpuEndTime
        let gpu = startTime > 0 && endTime >= startTime ? (endTime - startTime) * 1_000 : nil
        return (cpu, gpu)
    }

    func readPixels() throws -> [UInt8] {
        let readback = try context.texture(size: output.width, usage: [], storage: .shared)
        let command = try context.commandBuffer()
        try context.copy(output, to: readback, command: command)
        try context.complete(command)
        var pixels = [UInt8](repeating: 0, count: output.width * output.height * 4)
        readback.getBytes(
            &pixels, bytesPerRow: output.width * 4,
            from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0
        )
        return pixels
    }

    func report(
        pixels: [UInt8], reference: [UInt8], cpuReference: [UInt8]
    ) -> HostMetalFXPathReport {
        let colorOffsets = pixels.indices.filter { $0 % 4 != 3 }
        let error = colorOffsets.reduce(0.0) {
            $0 + abs(Double(pixels[$1]) - Double(reference[$1]))
        } / Double(colorOffsets.count * 255)
        let cpuError = colorOffsets.reduce(0.0) {
            $0 + abs(Double(pixels[$1]) - Double(cpuReference[$1]))
        } / Double(colorOffsets.count * 255)
        let opaque = stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }
        return HostMetalFXPathReport(
            requestedRoute: requestedRoute, executedRoute: executedRoute, capabilitySupported: supported,
            scalerCreationSucceeded: creationSucceeded, gpuEncodingCompleted: completedFrames > 0,
            requestedGPUEncodingCompleted: completedFrames > 0 && requestedRoute == executedRoute,
            fallbackReason: fallbackReason, shadedPixelsPerFrame: input.width * input.height,
            outputChecksum: HostMetalFXBenchmark.checksum(pixels), opaqueOutput: opaque,
            nonzeroColorOutput: colorOffsets.contains { pixels[$0] != 0 },
            meanAbsoluteErrorAgainstNative: error, meanAbsoluteErrorAgainstCPUReference: cpuError
        )
    }

    private static func jitter(frame: Int) -> SIMD2<Float> {
        func halton(_ value: Int, base: Int) -> Float {
            var value = value
            var fraction: Float = 1
            var result: Float = 0
            while value > 0 {
                fraction /= Float(base)
                result += fraction * Float(value % base)
                value /= base
            }
            return result
        }
        let index = frame % 32 + 1
        return SIMD2(halton(index, base: 2) - 0.5, halton(index, base: 3) - 0.5)
    }
}
