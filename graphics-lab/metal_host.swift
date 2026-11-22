import AppKit
import Foundation
import Metal
import MetalFX
import QuartzCore
import Darwin

private let headerSize = 32
private let protocolVersion: UInt16 = 1
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
    var kind: ProtocolKind
    var sequence: UInt32
    var width: UInt32
    var height: UInt32
    var commandBytes: UInt32
    var resourceBytes: UInt32
    var pixelBytes: UInt32

    func encoded() -> Data {
        var data = Data([0x47, 0x46, 0x58, 0x31])
        data.appendLE(protocolVersion)
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
              data.readLE(UInt16.self, at: 4) == protocolVersion,
              let kind = ProtocolKind(rawValue: data.readLE(UInt16.self, at: 6)) else {
            throw LabError.protocolViolation("invalid packet header")
        }
        return PacketHeader(kind: kind,
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

private final class MetalPresenter {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let layer: CAMetalLayer
    let pipeline: MTLRenderPipelineState
    let supportsMetalFXSpatial: Bool
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
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw LabError.metal("pipeline creation failed: \(error)")
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

    func present(width: Int, height: Int, pixels: Data, useMetalFXSpatial: Bool) throws -> (gpuMs: Double, renderPath: String) {
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
            throw LabError.metal("command buffer failed: \(String(describing: command.error))")
        }
        let duration = command.gpuEndTime - command.gpuStartTime
        return (duration > 0 ? duration * 1000 : 0, renderPath)
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
                    throw LabError.protocolViolation("invalid --resource-policy value: \(arguments[i])")
                }
                policyMode = parsed
            case "--metalfx":
                i += 1
                guard let parsed = MetalFXMode(rawValue: arguments[i]) else {
                    throw LabError.protocolViolation("invalid --metalfx value: \(arguments[i])")
                }
                metalFXMode = parsed
            case "--fullscreen":
                startFullScreen = true
            case "--help":
                print("metal_host [--bind 127.0.0.1] [--port 39003] [--jsonl OUTPUT] [--resource-policy off|auto|maximum-performance|balanced|conserve-energy] [--metalfx off|spatial] [--fullscreen]")
                exit(0)
            default: throw LabError.protocolViolation("unknown argument: \(arguments[i])")
            }
            i += 1
        }
        guard port != 0 else { throw LabError.protocolViolation("port must be 1...65535") }
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
            fputs("metal_host: \(error)\n", stderr)
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
        fputs("ready bind=\(bindAddress) port=\(port) device=\(presenter.device.name) policy=\(snap.effective.rawValue) source=\(snap.source) metalfx_requested=\(metalFXMode.rawValue) metalfx_supported=\(presenter.supportsMetalFXSpatial)\n", stderr)
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
            guard hello.kind == .hello, hello.width > 0, hello.height > 0,
                  hello.width <= 4096, hello.height <= 4096,
                  hello.pixelBytes == hello.width * hello.height * 4,
                  hello.commandBytes <= 4 * 1024 * 1024, hello.resourceBytes <= 32 * 1024 * 1024,
                  UInt64(hello.commandBytes) + UInt64(hello.resourceBytes) + UInt64(hello.pixelBytes) <= UInt64(maxFrameBytes) else {
                throw LabError.protocolViolation("invalid hello dimensions or limits")
            }
            let warmupFrames = hello.sequence
            var expectedSequence: UInt32 = 0
            var retainedCommands = Data()
            var retainedResource = Data()
            var lastPresentEndNs: UInt64 = 0
            while true {
                let frameStart = DispatchTime.now().uptimeNanoseconds
                let header = try PacketHeader.decode(recvExactly(fd, count: headerSize))
                guard header.kind == .frame, header.sequence == expectedSequence,
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
                    guard header.commandBytes % 16 == 0 else {
                        throw LabError.protocolViolation("command batch must contain 16-byte records")
                    }
                    retainedCommands = body.subdata(in: 0..<Int(header.commandBytes))
                    for offset in stride(from: 0, to: retainedCommands.count, by: 16) {
                        guard retainedCommands.readLE(UInt32.self, at: offset) == 1 else {
                            throw LabError.protocolViolation("unsupported command opcode")
                        }
                    }
                } else if retainedCommands.count != Int(hello.commandBytes) {
                    throw LabError.protocolViolation("command batch must be initialized before it can be retained")
                }
                let resourceStart = Int(header.commandBytes)
                let resourceEnd = resourceStart + Int(header.resourceBytes)
                if header.resourceBytes > 0 {
                    retainedResource = body.subdata(in: resourceStart..<resourceEnd)
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
                let presentResult = try presenter.present(
                    width: Int(header.width),
                    height: Int(header.height),
                    pixels: pixels,
                    useMetalFXSpatial: useSpatial
                )
                lastPresentEndNs = presentStartNs
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000
                let hostResident = residentBytes()
                let ack = PacketHeader(kind: .ack, sequence: header.sequence, width: 0, height: 0,
                                       commandBytes: 0, resourceBytes: 0, pixelBytes: 0)
                try sendExactly(fd, data: ack.encoded())
                let textureBytes = UInt64(drawableBytes(width: Int(header.width), height: Int(header.height)) * 4)
                try sendAckMetrics(fd, receiveMs: elapsedMs, gpuMs: presentResult.gpuMs,
                                   resident: hostResident, textureBytes: textureBytes)
                let record: [String: Any] = [
                    "frame_index": expectedSequence,
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
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(0x0a)
                let logHandle = log
                telemetryQueue.async {
                    try? logHandle.write(contentsOf: line)
                }
                expectedSequence &+= 1
            }
        } catch {
            telemetryQueue.sync {}
            fputs("receiver_session_end reason=\(error)\n", stderr)
        }
    }

    private func drawableBytes(width: Int, height: Int) -> Int {
        width * height * 4
    }
}

do {
    let delegate = AppDelegate()
    try delegate.configure(arguments: CommandLine.arguments)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
} catch {
    fputs("metal_host: \(error)\n", stderr)
    exit(2)
}
