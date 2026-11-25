import AppKit
import Foundation
import Metal
import MetalFX
import CryptoKit
import QuartzCore
import Darwin

private let headerSize = 32
private enum OffloadMode: String {
    case pixelReadback = "pixel-readback"
    case commandOnly = "command-only"

    var protocolVersion: UInt16 { self == .commandOnly ? 2 : 1 }
}
private let maxFrameBytes = 64 * 1024 * 1024

private enum ProtocolKind: UInt16 {
    case hello = 1
    case frame = 2
    case ack = 3
}

private enum ResourcePolicyMode: String {
    case off
    case auto
    case maximumPerformance = "maximum-performance"
    case balanced
    case conserveEnergy = "conserve-energy"
}

private enum EffectivePolicy: String {
    case off
    case maximumPerformance = "maximum-performance"
    case balanced
    case conserveEnergy = "conserve-energy"

    var targetFPSCap: Int? {
        switch self {
        case .off, .maximumPerformance: return nil
        case .balanced: return 60
        case .conserveEnergy: return 30
        }
    }

    var minFrameIntervalNs: UInt64 {
        guard let cap = targetFPSCap, cap > 0 else { return 0 }
        return UInt64(1_000_000_000.0 / Double(cap))
    }

    var allowsMetalFXSpatial: Bool {
        switch self {
        case .off, .maximumPerformance: return true
        case .balanced, .conserveEnergy: return false
        }
    }

    var qosLabel: String {
        switch self {
        case .off, .maximumPerformance: return "userInitiated"
        case .balanced: return "utility"
        case .conserveEnergy: return "background"
        }
    }
}

private enum MetalFXMode: String {
    case off
    case spatial
}

private final class DynamicResourcePolicyState {
    private let lock = NSLock()
    private let configuredMode: ResourcePolicyMode
    private var currentEffective: EffectivePolicy
    private var thermalStateLabel: String
    private var lowPowerEnabled: Bool
    private var observers: [NSObjectProtocol] = []

    init(mode: ResourcePolicyMode) {
        self.configuredMode = mode
        let processInfo = ProcessInfo.processInfo
        self.thermalStateLabel = Self.label(for: processInfo.thermalState)
        self.lowPowerEnabled = processInfo.isLowPowerModeEnabled
        self.currentEffective = Self.resolve(
            mode: mode,
            thermal: processInfo.thermalState,
            lowPower: processInfo.isLowPowerModeEnabled
        )
        if mode == .auto {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: ProcessInfo.thermalStateDidChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in self?.refreshFromSystem() },
                center.addObserver(
                    forName: .NSProcessInfoPowerStateDidChange,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in self?.refreshFromSystem() }
            ]
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func refreshFromSystem() {
        let info = ProcessInfo.processInfo
        lock.lock()
        thermalStateLabel = Self.label(for: info.thermalState)
        lowPowerEnabled = info.isLowPowerModeEnabled
        currentEffective = Self.resolve(
            mode: configuredMode,
            thermal: info.thermalState,
            lowPower: info.isLowPowerModeEnabled
        )
        lock.unlock()
    }

    func snapshot() -> (effective: EffectivePolicy, source: String, thermal: String, lowPower: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let source: String
        switch configuredMode {
        case .off: source = "off"
        case .auto: source = "live"
        case .maximumPerformance, .balanced, .conserveEnergy: source = "override"
        }
        return (currentEffective, source, thermalStateLabel, lowPowerEnabled)
    }

    private static func resolve(
        mode: ResourcePolicyMode,
        thermal: ProcessInfo.ThermalState,
        lowPower: Bool
    ) -> EffectivePolicy {
        switch mode {
        case .off: return .off
        case .maximumPerformance: return .maximumPerformance
        case .balanced: return .balanced
        case .conserveEnergy: return .conserveEnergy
        case .auto:
            if lowPower || thermal == .critical { return .conserveEnergy }
            if thermal == .serious { return .balanced }
            return .maximumPerformance
        }
    }

    private static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "serious"
        }
    }
}

private struct PacketHeader {
    var version: UInt16 = 1
    var kind: ProtocolKind
    var sequence: UInt32
    var width: UInt32
    var height: UInt32
    var commandBytes: UInt32
    var resourceBytes: UInt32
    var pixelBytes: UInt32

    func encoded() -> Data {
        var data = Data([0x47, 0x46, 0x58, 0x31])
        data.appendLE(version)
        data.appendLE(kind.rawValue)
        data.appendLE(sequence)
        data.appendLE(width)
        data.appendLE(height)
        data.appendLE(commandBytes)
        data.appendLE(resourceBytes)
        data.appendLE(pixelBytes)
        return data
    }

    static func decode(_ data: Data) throws -> PacketHeader {
        guard data.count == headerSize,
              data[0] == 0x47, data[1] == 0x46, data[2] == 0x58, data[3] == 0x31,
              (data.readLE(UInt16.self, at: 4) == 1 || data.readLE(UInt16.self, at: 4) == 2),
              let kind = ProtocolKind(rawValue: data.readLE(UInt16.self, at: 6)) else {
            throw LabError.protocolViolation("invalid packet header")
        }
        return PacketHeader(version: data.readLE(UInt16.self, at: 4), kind: kind,
                            sequence: data.readLE(UInt32.self, at: 8),
                            width: data.readLE(UInt32.self, at: 12),
                            height: data.readLE(UInt32.self, at: 16),
                            commandBytes: data.readLE(UInt32.self, at: 20),
                            resourceBytes: data.readLE(UInt32.self, at: 24),
                            pixelBytes: data.readLE(UInt32.self, at: 28))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size)) }
        return T(littleEndian: value)
    }
}

private enum LabError: Error, CustomStringConvertible {
    case protocolViolation(String)
    case systemCall(String, Int32)
    case metal(String)

    var description: String {
        switch self {
        case .protocolViolation(let s): return s
        case .systemCall(let s, let e): return "\(s): errno \(e)"
        case .metal(let s): return s
        }
    }
}

private func sanitizedError(_ error: Error) -> String {
    if let labError = error as? LabError { return labError.description }
    let systemError = error as NSError
    return "operation failed: domain=\(systemError.domain) code=\(systemError.code)"
}

private func recvExactly(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let got = data.withUnsafeMutableBytes { raw in
            Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
        }
        if got == 0 { throw LabError.protocolViolation("peer closed connection") }
        if got < 0 {
            if errno == EINTR { continue }
            throw LabError.systemCall("recv", errno)
        }
        offset += got
    }
    return data
}

private func sendExactly(_ fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let sent = data.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
        }
        if sent == 0 { throw LabError.protocolViolation("peer stopped accepting data") }
        if sent < 0 {
            if errno == EINTR { continue }
            throw LabError.systemCall("send", errno)
        }
        offset += sent
    }
}

private func sendAckMetrics(_ fd: Int32, receiveMs: Double, gpuMs: Double,
                            resident: UInt64, textureBytes: UInt64) throws {
    var data = Data()
    data.appendLE(UInt32(max(0, min(Double(UInt32.max), receiveMs * 1000))))
    data.appendLE(UInt32(max(0, min(Double(UInt32.max), gpuMs * 1000))))
    data.appendLE(resident)
    data.appendLE(textureBytes)
    try sendExactly(fd, data: data)
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func fnv1a64(_ data: Data) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return hash
}

private struct ReplayParams {
    var payloadOffset: UInt32
    var payloadBytes: UInt32
    var imageWidth: UInt32
    var pad: UInt32
}

private struct DrawDescriptor {
    let vertexCount: Int
    let vertexStart: Int
    var params: ReplayParams

    static func decodeBatch(_ bytes: Data, resourceBytes: Int, imageWidth: Int) throws -> [DrawDescriptor] {
        guard bytes.count == 16 * 32, resourceBytes == 65536 else {
            throw LabError.protocolViolation("command-only requires 16 draw records and 64 KiB resources")
        }
        return try stride(from: 0, to: bytes.count, by: 32).map { offset in
            let opcode = bytes.readLE(UInt32.self, at: offset)
            let vertexCount = bytes.readLE(UInt32.self, at: offset + 4)
            let vertexStart = bytes.readLE(UInt32.self, at: offset + 8)
            let reserved = bytes.readLE(UInt32.self, at: offset + 12)
            let params = ReplayParams(
                payloadOffset: bytes.readLE(UInt32.self, at: offset + 16),
                payloadBytes: bytes.readLE(UInt32.self, at: offset + 20),
                imageWidth: bytes.readLE(UInt32.self, at: offset + 24),
                pad: bytes.readLE(UInt32.self, at: offset + 28)
            )
            guard opcode == 1, vertexCount == 3, vertexStart == 0, reserved == 0,
                  params.payloadOffset == UInt32(bytes.count), params.payloadBytes == UInt32(resourceBytes),
                  params.imageWidth == UInt32(imageWidth), params.pad == 0 else {
                throw LabError.protocolViolation("invalid draw opcode, geometry, constants or buffer range")
            }
            return DrawDescriptor(vertexCount: Int(vertexCount), vertexStart: Int(vertexStart), params: params)
        }
    }
}

private struct PresentationResult {
    let gpuMs: Double
    let renderPath: String
    let sceneDrawCount: Int
    let presentationDrawCount: Int
    let capturedRGBA: Data?
}

private func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private final class MetalPresenter {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let layer: CAMetalLayer
    let pipeline: MTLRenderPipelineState
    let replayPipeline: MTLRenderPipelineState
    let mslSourceSHA256: String
    let supportsMetalFXSpatial: Bool
    private var replayTexture: MTLTexture?
    private var replayWidth = 0
    private var replayHeight = 0
    private var replayInput: MTLBuffer?
    private var inputTexture: MTLTexture?
    private var inputWidth = 0
    private var inputHeight = 0
    private var spatialScaler: MTLFXSpatialScaler?
    private var scaledTexture: MTLTexture?
    private var scalerInputWidth = 0
    private var scalerInputHeight = 0
    private var scalerOutputWidth = 0
    private var scalerOutputHeight = 0

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LabError.metal("Metal device or command queue unavailable")
        }
        self.device = device
        self.queue = queue
        self.layer = layer
        self.supportsMetalFXSpatial = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vertex_main(uint id [[vertex_id]]) {
          constexpr float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
          constexpr float2 t[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
          V o; o.position = float4(p[id], 0.0, 1.0); o.uv = t[id]; return o;
        }
        fragment float4 fragment_main(V in [[stage_in]], texture2d<float> src [[texture(0)]]) {
          constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
          return src.sample(s, in.uv);
        }
        struct ReplayV { float4 position [[position]]; };
        struct ReplayParams { uint PayloadOffset; uint PayloadBytes; uint ImageWidth; uint Pad; };
        vertex ReplayV replay_vertex(uint id [[vertex_id]]) {
          float2 p = id == 0 ? float2(-1.0, -1.0) :
                     (id == 1 ? float2(-1.0, 3.0) : float2(3.0, -1.0));
          ReplayV o; o.position = float4(p, 0.0, 1.0); return o;
        }
        fragment float4 replay_fragment(ReplayV input [[stage_in]],
                                        device const uint* InputData [[buffer(0)]],
                                        constant ReplayParams& params [[buffer(1)]]) {
          uint2 pixel = uint2(input.position.xy);
          uint address = ((pixel.y * params.ImageWidth + pixel.x) * 4u) % params.PayloadBytes;
          uint value = 0;
          #pragma unroll
          for (uint i = 0; i < 8; ++i) {
            value ^= InputData[(params.PayloadOffset + ((address + i * 4u) % params.PayloadBytes)) / 4u];
          }
          float shade = float(value & 255u) / 255.0f;
          return float4(shade, 0.25f + shade * 0.5f, 1.0f - shade * 0.35f, 1.0f);
        }
        """
        do {
            let options = MTLCompileOptions()
            if #available(macOS 15.0, *) {
                options.mathMode = .safe
                options.mathFloatingPointFunctions = .precise
            } else {
                options.fastMathEnabled = false
            }
            let library = try device.makeLibrary(source: source, options: options)
            self.mslSourceSHA256 = sha256(Data(source.utf8))
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let replayDescriptor = MTLRenderPipelineDescriptor()
            replayDescriptor.vertexFunction = library.makeFunction(name: "replay_vertex")
            replayDescriptor.fragmentFunction = library.makeFunction(name: "replay_fragment")
            replayDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            replayDescriptor.colorAttachments[0].isBlendingEnabled = false
            replayDescriptor.rasterSampleCount = 1
            self.replayPipeline = try device.makeRenderPipelineState(descriptor: replayDescriptor)
        } catch {
            throw LabError.metal("pipeline creation failed: \(sanitizedError(error))")
        }
    }

    private func ensureSpatialScaler(inputW: Int, inputH: Int, outputW: Int, outputH: Int) -> (MTLFXSpatialScaler, MTLTexture)? {
        guard supportsMetalFXSpatial, outputW > inputW, outputH > inputH else { return nil }
        if let existingScaler = spatialScaler, let existingTex = scaledTexture,
           scalerInputWidth == inputW, scalerInputHeight == inputH,
           scalerOutputWidth == outputW, scalerOutputHeight == outputH {
            return (existingScaler, existingTex)
        }
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputW
        desc.inputHeight = inputH
        desc.outputWidth = outputW
        desc.outputHeight = outputH
        desc.colorTextureFormat = .rgba8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.colorProcessingMode = .perceptual
        guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputW, height: outputH, mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        guard let outTex = device.makeTexture(descriptor: outDesc) else { return nil }
        spatialScaler = scaler
        scaledTexture = outTex
        scalerInputWidth = inputW
        scalerInputHeight = inputH
        scalerOutputWidth = outputW
        scalerOutputHeight = outputH
        return (scaler, outTex)
    }

    func present(width: Int, height: Int, pixels: Data, useMetalFXSpatial: Bool) throws -> PresentationResult {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else {
            throw LabError.metal("invalid image or drawable unavailable")
        }
        if inputTexture == nil || inputWidth != width || inputHeight != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                       width: width,
                                                                       height: height,
                                                                       mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let allocated = device.makeTexture(descriptor: descriptor) else {
                throw LabError.metal("frame texture allocation failed")
            }
            inputTexture = allocated
            inputWidth = width
            inputHeight = height
        }
        pixels.withUnsafeBytes { raw in
            inputTexture!.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                  withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }

        var sourceForBlit: MTLTexture = inputTexture!
        var renderPath = "direct_blit"
        if useMetalFXSpatial,
           let (scaler, upscaled) = ensureSpatialScaler(
               inputW: width,
               inputH: height,
               outputW: drawable.texture.width,
               outputH: drawable.texture.height
           ) {
            scaler.colorTexture = inputTexture
            scaler.outputTexture = upscaled
            scaler.encode(commandBuffer: command)
            sourceForBlit = upscaled
            renderPath = "metalfx_spatial"
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw LabError.metal("render encoder creation failed")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sourceForBlit, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw LabError.metal("command buffer failed")
        }
        let duration = command.gpuEndTime - command.gpuStartTime
        return PresentationResult(gpuMs: duration > 0 ? duration * 1000 : 0, renderPath: renderPath,
                                  sceneDrawCount: 0, presentationDrawCount: 1, capturedRGBA: nil)
    }

    func replay(width: Int, height: Int, commands: Data, resource: Data, draws: [DrawDescriptor],
                commandsUpdated: Bool, resourceUpdated: Bool, capture: Bool) throws -> PresentationResult {
        guard width > 0, height > 0, draws.count == 16, commands.count == 512, resource.count == 65536,
              let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else {
            throw LabError.metal("invalid command-only frame or drawable unavailable")
        }
        if replayTexture == nil || replayWidth != width || replayHeight != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw LabError.metal("replay render target allocation failed")
            }
            replayTexture = texture
            replayWidth = width
            replayHeight = height
        }
        let inputBytes = commands.count + resource.count
        let allocateInput = replayInput == nil || replayInput!.length != inputBytes
        if allocateInput {
            guard let buffer = device.makeBuffer(length: inputBytes, options: .storageModeShared) else {
                throw LabError.metal("replay InputData allocation failed")
            }
            replayInput = buffer
        }
        if allocateInput || commandsUpdated {
            commands.withUnsafeBytes { bytes in
                replayInput!.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        if allocateInput || resourceUpdated {
            resource.withUnsafeBytes { bytes in
                replayInput!.contents().advanced(by: commands.count).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = replayTexture!
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        guard let sceneEncoder = command.makeRenderCommandEncoder(descriptor: scenePass) else {
            throw LabError.metal("replay render encoder unavailable")
        }
        sceneEncoder.label = "command-only scene: 16 received draws"
        sceneEncoder.setRenderPipelineState(replayPipeline)
        sceneEncoder.setCullMode(.none)
        sceneEncoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
        sceneEncoder.setFragmentBuffer(replayInput!, offset: 0, index: 0)
        for descriptor in draws {
            var params = descriptor.params
            sceneEncoder.setFragmentBytes(&params, length: MemoryLayout<ReplayParams>.size, index: 1)
            sceneEncoder.drawPrimitives(type: .triangle, vertexStart: descriptor.vertexStart, vertexCount: descriptor.vertexCount)
        }
        sceneEncoder.endEncoding()

        var captureBuffer: MTLBuffer?
        let rowBytes = (width * 4 + 255) & ~255
        if capture {
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else {
                throw LabError.metal("capture buffer or blit encoder unavailable")
            }
            blit.copy(from: replayTexture!, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding()
            captureBuffer = buffer
        }
        let presentationPass = MTLRenderPassDescriptor()
        presentationPass.colorAttachments[0].texture = drawable.texture
        presentationPass.colorAttachments[0].loadAction = .clear
        presentationPass.colorAttachments[0].storeAction = .store
        guard let presentationEncoder = command.makeRenderCommandEncoder(descriptor: presentationPass) else {
            throw LabError.metal("replay presentation encoder unavailable")
        }
        presentationEncoder.setRenderPipelineState(pipeline)
        presentationEncoder.setFragmentTexture(replayTexture!, index: 0)
        presentationEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        presentationEncoder.endEncoding()
        command.present(drawable)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw LabError.metal("replay command buffer failed") }
        var capturedRGBA: Data?
        if let buffer = captureBuffer {
            var rgba = Data(count: width * height * 4)
            rgba.withUnsafeMutableBytes { bytes in
                for row in 0..<height {
                    bytes.baseAddress!.advanced(by: row * width * 4).copyMemory(
                        from: buffer.contents().advanced(by: row * rowBytes), byteCount: width * 4
                    )
                }
            }
            capturedRGBA = rgba
        }
        let duration = command.gpuEndTime - command.gpuStartTime
        return PresentationResult(gpuMs: duration > 0 ? duration * 1000 : 0, renderPath: "command_only_metal_replay",
                                  sceneDrawCount: draws.count, presentationDrawCount: 1, capturedRGBA: capturedRGBA)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var presenter: MetalPresenter!
    private var policyState: DynamicResourcePolicyState!
    private var listener: Int32 = -1
    private var log: FileHandle = .standardOutput
    private let workQueue = DispatchQueue(label: "graphics-lab.receiver", qos: .userInitiated)
    private var telemetryQueue = DispatchQueue(label: "graphics-lab.telemetry", qos: .userInitiated)
    private var port: UInt16 = 39003
    private var bindAddress = "127.0.0.1"
    private var policyMode: ResourcePolicyMode = .off
    private var metalFXMode: MetalFXMode = .off
    private var startFullScreen = false
    private var offloadMode: OffloadMode = .pixelReadback
    private var displaySyncEnabled = true
    private var captureDirectory: URL?
    private var captureFrames: Set<UInt32> = []
    private var binarySHA256 = "unavailable"

    func configure(arguments: [String]) throws {
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--bind": i += 1; bindAddress = arguments[i]
            case "--port": i += 1; port = UInt16(arguments[i]) ?? 0
            case "--jsonl":
                i += 1
                let path = arguments[i]
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw LabError.protocolViolation("cannot create JSONL output")
                }
                log = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            case "--resource-policy":
                i += 1
                guard let parsed = ResourcePolicyMode(rawValue: arguments[i]) else {
                    throw LabError.protocolViolation("invalid --resource-policy value")
                }
                policyMode = parsed
            case "--metalfx":
                i += 1
                guard let parsed = MetalFXMode(rawValue: arguments[i]) else {
                    throw LabError.protocolViolation("invalid --metalfx value")
                }
                metalFXMode = parsed
            case "--offload-mode":
                guard i + 1 < arguments.count, let parsed = OffloadMode(rawValue: arguments[i + 1]) else {
                    throw LabError.protocolViolation("invalid --offload-mode")
                }
                i += 1
                offloadMode = parsed
            case "--display-sync":
                guard i + 1 < arguments.count, arguments[i + 1] == "on" || arguments[i + 1] == "off" else {
                    throw LabError.protocolViolation("--display-sync requires on or off")
                }
                i += 1
                displaySyncEnabled = arguments[i] == "on"
            case "--capture-dir":
                guard i + 1 < arguments.count else { throw LabError.protocolViolation("missing --capture-dir value") }
                i += 1
                let path = arguments[i]
                guard !path.hasPrefix("/"),
                      path.hasPrefix("graphics-lab/") || path.hasPrefix("handoff/phase-2/evidence/window-c/") else {
                    throw LabError.protocolViolation("capture directory must be relative and inside the authorized evidence paths")
                }
                let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
                let destination = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                let allowedRoots = [root.appendingPathComponent("graphics-lab").resolvingSymlinksInPath(),
                                    root.appendingPathComponent("handoff/phase-2/evidence/window-c").resolvingSymlinksInPath()]
                guard allowedRoots.contains(where: { destination.path.hasPrefix($0.path + "/") }) else {
                    throw LabError.protocolViolation("capture directory escapes authorized paths")
                }
                captureDirectory = destination
            case "--capture-frame":
                guard i + 1 < arguments.count else { throw LabError.protocolViolation("missing --capture-frame value") }
                i += 1
                let values = arguments[i].split(separator: ",", omittingEmptySubsequences: false)
                guard !values.isEmpty else { throw LabError.protocolViolation("invalid capture frame") }
                for value in values {
                    guard let frame = UInt32(value) else { throw LabError.protocolViolation("invalid capture frame") }
                    captureFrames.insert(frame)
                }
            case "--fullscreen":
                startFullScreen = true
            case "--help":
                print("metal_host [--bind 127.0.0.1] [--port 39003] [--jsonl OUTPUT] [--resource-policy off|auto|maximum-performance|balanced|conserve-energy] [--metalfx off|spatial] [--fullscreen] [--offload-mode pixel-readback|command-only] [--display-sync on|off] [--capture-dir RELATIVE_PATH --capture-frame N[,N]]")
                exit(0)
            default: throw LabError.protocolViolation("unknown argument")
            }
            i += 1
        }
        guard port != 0 else { throw LabError.protocolViolation("port must be 1...65535") }
        if captureDirectory != nil {
            guard offloadMode == .commandOnly, metalFXMode == .off else {
                throw LabError.protocolViolation("captures require command-only with MetalFX off")
            }
            if captureFrames.isEmpty { captureFrames.insert(0) }
        } else if !captureFrames.isEmpty {
            throw LabError.protocolViolation("--capture-frame requires --capture-dir")
        }
        if let executable = arguments.first, let bytes = try? Data(contentsOf: URL(fileURLWithPath: executable)) {
            binarySHA256 = sha256(bytes)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            policyState = DynamicResourcePolicyState(mode: policyMode)
            let initialSnap = policyState.snapshot()
            let telemetryQoS: DispatchQoS
            switch initialSnap.effective {
            case .off, .maximumPerformance: telemetryQoS = .userInitiated
            case .balanced: telemetryQoS = .utility
            case .conserveEnergy: telemetryQoS = .background
            }
            // Keep the presentation receiver loop at .userInitiated to avoid XNU timer coalescing
            // on frame pacing; apply lower QoS to asynchronous telemetry logging instead.
            telemetryQueue = DispatchQueue(label: "graphics-lab.telemetry", qos: telemetryQoS)

            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            window.collectionBehavior = [.fullScreenPrimary]
            window.title = "Graphics Lab Host"
            let view = NSView(frame: window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            let layer = CAMetalLayer()
            layer.displaySyncEnabled = displaySyncEnabled
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer = layer
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            if startFullScreen {
                NSApp.activate(ignoringOtherApps: true)
                window.toggleFullScreen(nil)
            }
            presenter = try MetalPresenter(layer: layer)
            try startListener()
        } catch {
            fputs("metal_host: \(sanitizedError(error))\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func startListener() throws {
        listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LabError.systemCall("socket", errno) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
            throw LabError.protocolViolation("--bind must be an IPv4 address")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw LabError.systemCall("bind", errno) }
        guard Darwin.listen(listener, 1) == 0 else { throw LabError.systemCall("listen", errno) }
        let snap = policyState.snapshot()
        fputs("ready bind=\(bindAddress) port=\(port) device=\(presenter.device.name) policy=\(snap.effective.rawValue) source=\(snap.source) metalfx_requested=\(metalFXMode.rawValue) metalfx_supported=\(presenter.supportsMetalFXSpatial) offload_mode=\(offloadMode.rawValue) display_sync_enabled=\(displaySyncEnabled)\n", stderr)
        workQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while listener >= 0 {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; break }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) {
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            _ = withUnsafePointer(to: &timeout) {
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ fd: Int32) {
        do {
            let hello = try PacketHeader.decode(recvExactly(fd, count: headerSize))
            guard hello.kind == .hello, hello.version == offloadMode.protocolVersion, hello.width > 0, hello.height > 0,
                  hello.width <= 4096, hello.height <= 4096,
                  hello.pixelBytes == (offloadMode == .commandOnly ? 0 : hello.width * hello.height * 4),
                  hello.commandBytes <= 4 * 1024 * 1024, hello.resourceBytes <= 32 * 1024 * 1024,
                  UInt64(hello.commandBytes) + UInt64(hello.resourceBytes) + UInt64(hello.pixelBytes) <= UInt64(maxFrameBytes) else {
                throw LabError.protocolViolation("invalid hello dimensions or limits")
            }
            if offloadMode == .commandOnly {
                guard hello.commandBytes == 512, hello.resourceBytes == 65536 else {
                    throw LabError.protocolViolation("command-only hello must advertise 16 draws and 64 KiB resource data")
                }
            }
            let warmupFrames = hello.sequence
            var expectedSequence: UInt32 = 0
            var retainedCommands = Data()
            var retainedResource = Data()
            var retainedDraws: [DrawDescriptor] = []
            var lastPresentEndNs: UInt64 = 0
            while true {
                let frameStart = DispatchTime.now().uptimeNanoseconds
                let header = try PacketHeader.decode(recvExactly(fd, count: headerSize))
                guard header.kind == .frame, header.version == hello.version, header.sequence == expectedSequence,
                      header.width == hello.width, header.height == hello.height,
                      header.commandBytes <= hello.commandBytes,
                      (header.commandBytes == 0 || header.commandBytes == hello.commandBytes),
                      header.resourceBytes <= hello.resourceBytes,
                      header.pixelBytes == hello.pixelBytes else {
                    throw LabError.protocolViolation("frame sequence or dimensions changed")
                }
                let bodyCount = Int(header.commandBytes) + Int(header.resourceBytes) + Int(header.pixelBytes)
                let body = try recvExactly(fd, count: bodyCount)
                if header.commandBytes > 0 {
                    retainedCommands = body.subdata(in: 0..<Int(header.commandBytes))
                    if offloadMode == .commandOnly {
                        retainedDraws = try DrawDescriptor.decodeBatch(retainedCommands, resourceBytes: Int(hello.resourceBytes),
                                                                     imageWidth: Int(hello.width))
                    } else {
                        guard header.commandBytes % 16 == 0 else {
                            throw LabError.protocolViolation("command batch must contain 16-byte records")
                        }
                        for offset in stride(from: 0, to: retainedCommands.count, by: 16) {
                            guard retainedCommands.readLE(UInt32.self, at: offset) == 1 else {
                                throw LabError.protocolViolation("unsupported command opcode")
                            }
                        }
                    }
                } else if retainedCommands.count != Int(hello.commandBytes) {
                    throw LabError.protocolViolation("command batch must be initialized before it can be retained")
                }
                let resourceStart = Int(header.commandBytes)
                let resourceEnd = resourceStart + Int(header.resourceBytes)
                if header.resourceBytes > 0 {
                    retainedResource = body.subdata(in: resourceStart..<resourceEnd)
                } else if retainedResource.count != Int(hello.resourceBytes) {
                    throw LabError.protocolViolation("resource data must be initialized before it can be retained")
                }
                let pixels = body.subdata(in: Int(header.commandBytes + header.resourceBytes)..<body.count)

                let snap = policyState.snapshot()
                var pacingSleepMs = 0.0
                let minIntervalNs = snap.effective.minFrameIntervalNs
                if minIntervalNs > 0, lastPresentEndNs > 0 {
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    let targetNs = lastPresentEndNs &+ minIntervalNs
                    if nowNs < targetNs {
                        let remainingNs = targetNs - nowNs
                        let sleepStart = nowNs
                        var ts = timespec(
                            tv_sec: Int(remainingNs / 1_000_000_000),
                            tv_nsec: Int(remainingNs % 1_000_000_000)
                        )
                        Darwin.nanosleep(&ts, nil)
                        pacingSleepMs = Double(DispatchTime.now().uptimeNanoseconds - sleepStart) / 1_000_000.0
                    }
                }

                let presentStartNs = DispatchTime.now().uptimeNanoseconds
                let useSpatial = (metalFXMode == .spatial) && snap.effective.allowsMetalFXSpatial
                let presentResult: PresentationResult
                let shouldCapture = captureDirectory != nil && captureFrames.contains(header.sequence)
                if offloadMode == .commandOnly {
                    presentResult = try presenter.replay(
                        width: Int(header.width), height: Int(header.height), commands: retainedCommands,
                        resource: retainedResource, draws: retainedDraws,
                        commandsUpdated: header.commandBytes > 0, resourceUpdated: header.resourceBytes > 0, capture: shouldCapture
                    )
                } else {
                    presentResult = try presenter.present(
                        width: Int(header.width), height: Int(header.height), pixels: pixels, useMetalFXSpatial: useSpatial
                    )
                }
                if let rgba = presentResult.capturedRGBA {
                    try writeCapture(rgba, header: header, commands: retainedCommands, resource: retainedResource,
                                     result: presentResult)
                }
                lastPresentEndNs = presentStartNs
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000
                let hostResident = residentBytes()
                let ack = PacketHeader(version: hello.version, kind: .ack, sequence: header.sequence, width: 0, height: 0,
                                       commandBytes: 0, resourceBytes: 0, pixelBytes: 0)
                try sendExactly(fd, data: ack.encoded())
                let textureBytes = UInt64(drawableBytes(width: Int(header.width), height: Int(header.height)) * 4)
                try sendAckMetrics(fd, receiveMs: elapsedMs, gpuMs: presentResult.gpuMs,
                                   resident: hostResident, textureBytes: textureBytes)
                let record: [String: Any] = [
                    "frame_index": expectedSequence,
                    "offload_mode": offloadMode.rawValue,
                    "display_sync_enabled": displaySyncEnabled,
                    "protocol_version": hello.version,
                    "scene_draw_count": presentResult.sceneDrawCount,
                    "presentation_draw_count": presentResult.presentationDrawCount,
                    "capture_enabled": shouldCapture,
                    "capture_configured": captureDirectory != nil,
                    "completion_scope": "gpu-command-complete",
                    "host_binary_sha256": binarySHA256,
                    "msl_source_sha256": presenter.mslSourceSHA256,
                    "warmup": expectedSequence < warmupFrames,
                    "host_receive_to_present_complete_ms": elapsedMs,
                    "metal_command_complete_ms": presentResult.gpuMs > 0 ? presentResult.gpuMs as Any : NSNull(),
                    "transferred_bytes_in": headerSize + bodyCount,
                    "ack_bytes_out": headerSize + 24,
                    "ack_header_bytes_out": headerSize,
                    "ack_metrics_bytes_out": 24,
                    "command_bytes": header.commandBytes,
                    "command_updated_bytes": header.commandBytes,
                    "command_fnv1a64": String(fnv1a64(retainedCommands), radix: 16),
                    "resource_bytes": header.resourceBytes,
                    "resource_fnv1a64": String(fnv1a64(retainedResource), radix: 16),
                    "resource_updated_bytes": header.resourceBytes,
                    "resource_resident_bytes": retainedResource.count,
                    "pixel_bytes": header.pixelBytes,
                    "modeled_host_texture_bytes": textureBytes,
                    "resident_bytes": hostResident == 0 ? NSNull() : hostResident as Any,
                    "device": presenter.device.name,
                    "policy_mode": snap.effective.rawValue,
                    "policy_source": snap.source,
                    "policy_qos": snap.effective.qosLabel,
                    "target_fps_cap": snap.effective.targetFPSCap as Any? ?? NSNull(),
                    "pacing_sleep_ms": pacingSleepMs,
                    "render_path": presentResult.renderPath,
                    "thermal_state": snap.thermal,
                    "low_power_mode": snap.lowPower
                ]
                var serialized = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                serialized.append(0x0a)
                let line = serialized
                let logHandle = log
                telemetryQueue.async {
                    try? logHandle.write(contentsOf: line)
                }
                expectedSequence &+= 1
            }
        } catch {
            telemetryQueue.sync {}
            fputs("receiver_session_end reason=\(sanitizedError(error))\n", stderr)
        }
    }

    private func writeCapture(_ rgba: Data, header: PacketHeader, commands: Data, resource: Data,
                              result: PresentationResult) throws {
        guard let directory = captureDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = String(format: "frame-%06u", header.sequence)
        let metadata: [String: Any] = [
            "frame_sequence": header.sequence,
            "width": header.width,
            "height": header.height,
            "pixel_format": "rgba8Unorm",
            "row_order": "top-to-bottom",
            "row_bytes": header.width * 4,
            "byte_count": rgba.count,
            "rgba_sha256": sha256(rgba),
            "command_sha256": sha256(commands),
            "resource_sha256": sha256(resource),
            "msl_source_sha256": presenter.mslSourceSHA256,
            "host_binary_sha256": binarySHA256,
            "device": presenter.device.name,
            "offload_mode": offloadMode.rawValue,
            "display_sync_enabled": displaySyncEnabled,
            "protocol_version": header.version,
            "scene_draw_count": result.sceneDrawCount,
            "presentation_draw_count": result.presentationDrawCount,
            "host_gpu_ms": result.gpuMs,
            "capture_in_performance_sample": false,
            "completion_scope": "gpu-command-complete",
            "metalfx": "off"
        ]
        try rgba.write(to: directory.appendingPathComponent(basename + ".rgba"), options: .atomic)
        var json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
        json.append(0x0a)
        try json.write(to: directory.appendingPathComponent(basename + ".json"), options: .atomic)
    }

    private func drawableBytes(width: Int, height: Int) -> Int {
        width * height * 4
    }
}

do {
    if CommandLine.arguments.contains("--validate-msl") {
        let presenter = try MetalPresenter(layer: CAMetalLayer())
        let result: [String: Any] = ["pipeline_validated": true, "device": presenter.device.name,
                                     "msl_source_sha256": presenter.mslSourceSHA256,
                                     "validation_scope": "Metal pipeline compilation"]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        exit(0)
    }
    let delegate = AppDelegate()
    try delegate.configure(arguments: CommandLine.arguments)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
} catch {
    fputs("metal_host: \(sanitizedError(error))\n", stderr)
    exit(2)
}
