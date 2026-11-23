// SPDX-License-Identifier: GPL-3.0-or-later
// M2.5 asynchronous fence-pipelined Metal receiver for graphics-lab (GFX1 v3).
// Owner: @DNPMBHC

import AppKit
import CryptoKit
import Darwin
import Foundation
import Metal
import QuartzCore

private let headerSize = 32
private let ackMetricsSize = 24
private let maxFrameBytes = 64 * 1024 * 1024
private let protocolVersionV3: UInt16 = 3
private let ackFlagGpuOk: UInt32 = 1

private enum AsyncLabError: Error, CustomStringConvertible {
    case usage(String)
    case systemCall(String, Int32)
    case protocolViolation(String)
    case metal(String)

    var description: String {
        switch self {
        case .usage(let message): return "usage: \(message)"
        case .systemCall(let call, let code): return "\(call) failed (errno=\(code))"
        case .protocolViolation(let message): return "protocol violation: \(message)"
        case .metal(let message): return "metal: \(message)"
        }
    }
}

private enum PacketKind: UInt16 {
    case hello = 1
    case frame = 2
    case ack = 3
}

private enum PipelineMode: String {
    case sync
    case async
}

private struct HostConfig {
    var bindAddress = "127.0.0.1"
    var port: UInt16 = 39013
    var tcpNoDelay = true
    var splitAck = false
    var pipelineMode: PipelineMode = .async
    var maxInFlight = 2
    var displaySyncEnabled = false
    var logPath: String?
    var captureDir: String?
    var captureFrames: Set<UInt32> = []
}

private extension Data {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            Swift.withUnsafeMutableBytes(of: &value) { dst in
                guard let dstBase = dst.baseAddress else { return }
                dstBase.copyMemory(from: base.advanced(by: offset), byteCount: MemoryLayout<T>.size)
            }
        }
        return T(littleEndian: value)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private struct AsyncHeader {
    let version: UInt16
    let kind: PacketKind
    let sequence: UInt32
    let width: UInt32
    let height: UInt32
    let commandBytes: UInt32
    let resourceBytes: UInt32
    let aux: UInt32

    static func decode(_ data: Data) throws -> AsyncHeader {
        guard data.count == headerSize else {
            throw AsyncLabError.protocolViolation("short header")
        }
        guard Array(data.prefix(4)) == Array("GFX1".utf8) else {
            throw AsyncLabError.protocolViolation("bad magic")
        }
        let version = data.readLE(UInt16.self, at: 4)
        guard version == protocolVersionV3 else {
            throw AsyncLabError.protocolViolation("unsupported version \(version)")
        }
        guard let kind = PacketKind(rawValue: data.readLE(UInt16.self, at: 6)) else {
            throw AsyncLabError.protocolViolation("unknown packet kind")
        }
        return AsyncHeader(
            version: version,
            kind: kind,
            sequence: data.readLE(UInt32.self, at: 8),
            width: data.readLE(UInt32.self, at: 12),
            height: data.readLE(UInt32.self, at: 16),
            commandBytes: data.readLE(UInt32.self, at: 20),
            resourceBytes: data.readLE(UInt32.self, at: 24),
            aux: data.readLE(UInt32.self, at: 28)
        )
    }

    func encode() -> Data {
        var out = Data("GFX1".utf8)
        out.appendLE(version)
        out.appendLE(kind.rawValue)
        out.appendLE(sequence)
        out.appendLE(width)
        out.appendLE(height)
        out.appendLE(commandBytes)
        out.appendLE(resourceBytes)
        out.appendLE(aux)
        return out
    }
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
    let params: ReplayParams

    static func decodeBatch(_ bytes: Data, resourceBytes: Int, imageWidth: Int) throws -> [DrawDescriptor] {
        guard bytes.count == 16 * 32, resourceBytes == 65536 else {
            throw AsyncLabError.protocolViolation("command-only requires 16 draws and 64 KiB resource")
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
                  params.payloadOffset == UInt32(bytes.count),
                  params.payloadBytes == UInt32(resourceBytes),
                  params.imageWidth == UInt32(imageWidth),
                  params.pad == 0 else {
                throw AsyncLabError.protocolViolation("invalid draw descriptor")
            }
            return DrawDescriptor(vertexCount: Int(vertexCount), vertexStart: Int(vertexStart), params: params)
        }
    }
}

private struct FrameCompletion {
    let sequence: UInt32
    let width: UInt32
    let height: UInt32
    let gpuOk: Bool
    let receiveMs: Double
    let gpuMs: Double
    let textureBytes: UInt64
    let capturedRGBA: Data?
}

private func recvExactly(_ fileDesc: Int32, count: Int) throws -> Data {
    if count == 0 { return Data() }
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let got: Int = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(fileDesc, base.advanced(by: offset), count - offset, 0)
        }
        if got == 0 { throw AsyncLabError.protocolViolation("peer closed connection") }
        if got < 0 {
            if errno == EINTR { continue }
            throw AsyncLabError.systemCall("recv", errno)
        }
        offset += got
    }
    return data
}

private func sendExactly(_ fileDesc: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let sent: Int = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fileDesc, base.advanced(by: offset), data.count - offset, 0)
        }
        if sent == 0 { throw AsyncLabError.protocolViolation("peer closed during send") }
        if sent < 0 {
            if errno == EINTR { continue }
            throw AsyncLabError.systemCall("send", errno)
        }
        offset += sent
    }
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func encodeAckPacket(_ item: FrameCompletion) -> Data {
    let header = AsyncHeader(
        version: protocolVersionV3,
        kind: .ack,
        sequence: item.sequence,
        width: item.width,
        height: item.height,
        commandBytes: item.sequence &+ 1,
        resourceBytes: item.gpuOk ? ackFlagGpuOk : 0,
        aux: UInt32(ackMetricsSize)
    )
    var packet = header.encode()
    packet.appendLE(UInt32(max(0, min(Double(UInt32.max), item.receiveMs * 1000.0))))
    packet.appendLE(UInt32(max(0, min(Double(UInt32.max), item.gpuMs * 1000.0))))
    packet.appendLE(residentBytes())
    packet.appendLE(item.textureBytes)
    return packet
}

private final class ReplaySlot {
    var inputBuffer: MTLBuffer?
    var renderTarget: MTLTexture?
    var width = 0
    var height = 0
}

private final class AsyncMetalPresenter {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let layer: CAMetalLayer
    let presentPipeline: MTLRenderPipelineState
    let replayPipeline: MTLRenderPipelineState
    let mslSourceSHA256: String
    private var slots: [ReplaySlot]

    init(layer: CAMetalLayer, slotCount: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw AsyncLabError.metal("Metal device or command queue unavailable")
        }
        self.device = device
        self.queue = queue
        self.layer = layer
        self.slots = (0..<max(1, slotCount)).map { _ in ReplaySlot() }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.maximumDrawableCount = min(3, max(2, slotCount))

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
        self.mslSourceSHA256 = sha256Hex(Data(source.utf8))
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        }
        let library = try device.makeLibrary(source: source, options: options)
        self.presentPipeline = try Self.makePipeline(
            device: device, library: library, vertex: "vertex_main",
            fragment: "fragment_main", format: .bgra8Unorm
        )
        self.replayPipeline = try Self.makePipeline(
            device: device, library: library, vertex: "replay_vertex",
            fragment: "replay_fragment", format: .rgba8Unorm
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private func prepareSlot(
        _ slot: ReplaySlot,
        width: Int,
        height: Int,
        commands: Data,
        resource: Data
    ) throws -> (MTLBuffer, MTLTexture) {
        if slot.renderTarget == nil || slot.width != width || slot.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            desc.storageMode = .private
            desc.usage = [.renderTarget, .shaderRead]
            guard let tex = device.makeTexture(descriptor: desc) else {
                throw AsyncLabError.metal("render target allocation failed")
            }
            slot.renderTarget = tex
            slot.width = width
            slot.height = height
        }
        let totalBytes = commands.count + resource.count
        if slot.inputBuffer == nil || (slot.inputBuffer?.length ?? 0) != totalBytes {
            guard let buf = device.makeBuffer(length: totalBytes, options: .storageModeShared) else {
                throw AsyncLabError.metal("input buffer allocation failed")
            }
            slot.inputBuffer = buf
        }
        guard let inputBuffer = slot.inputBuffer, let renderTarget = slot.renderTarget else {
            throw AsyncLabError.metal("slot resources unavailable")
        }
        commands.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                inputBuffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
        resource.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                inputBuffer.contents().advanced(by: commands.count).copyMemory(from: base, byteCount: raw.count)
            }
        }
        return (inputBuffer, renderTarget)
    }

    func encodeAndSubmit(
        slotIndex: Int,
        sequence: UInt32,
        width: Int,
        height: Int,
        commands: Data,
        resource: Data,
        draws: [DrawDescriptor],
        receiveMs: Double,
        capture: Bool,
        synchronous: Bool,
        onCompleted: @escaping (FrameCompletion) -> Void
    ) throws {
        try autoreleasepool {
            let slot = slots[slotIndex % slots.count]
            let (inputBuffer, renderTarget) = try prepareSlot(
                slot, width: width, height: height, commands: commands, resource: resource
            )
            guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else {
                throw AsyncLabError.metal("drawable or command buffer unavailable")
            }
            try encodeScene(
                command: command, renderTarget: renderTarget, inputBuffer: inputBuffer,
                width: width, height: height, draws: draws
            )
            let rowBytes = (width * 4 + 255) & ~255
            let captureBuffer = try encodeCaptureIfNeeded(
                command: command, renderTarget: renderTarget, width: width,
                height: height, rowBytes: rowBytes, capture: capture
            )
            try encodePresent(command: command, source: renderTarget, drawable: drawable)
            command.present(drawable)

            let texBytes = UInt64(width * height * 4 * slots.count)
            let finishBlock: (MTLCommandBuffer) -> Void = { completed in
                let ok = completed.status == .completed
                let duration = completed.gpuEndTime - completed.gpuStartTime
                let gpuMs = duration > 0 ? duration * 1000.0 : 0.0
                var rgba: Data?
                if ok, let buf = captureBuffer {
                    rgba = Self.copyCapturedRGBA(buffer: buf, width: width, height: height, rowBytes: rowBytes)
                }
                onCompleted(FrameCompletion(
                    sequence: sequence,
                    width: UInt32(width),
                    height: UInt32(height),
                    gpuOk: ok,
                    receiveMs: receiveMs,
                    gpuMs: gpuMs,
                    textureBytes: texBytes,
                    capturedRGBA: rgba
                ))
            }

            if synchronous {
                command.commit()
                command.waitUntilCompleted()
                finishBlock(command)
            } else {
                command.addCompletedHandler(finishBlock)
                command.commit()
            }
        }
    }

    private func encodeScene(
        command: MTLCommandBuffer,
        renderTarget: MTLTexture,
        inputBuffer: MTLBuffer,
        width: Int,
        height: Int,
        draws: [DrawDescriptor]
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = renderTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw AsyncLabError.metal("scene encoder unavailable")
        }
        encoder.setRenderPipelineState(replayPipeline)
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1
        ))
        encoder.setFragmentBuffer(inputBuffer, offset: 0, index: 0)
        for descriptor in draws {
            var params = descriptor.params
            encoder.setFragmentBytes(&params, length: MemoryLayout<ReplayParams>.size, index: 1)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: descriptor.vertexStart, vertexCount: descriptor.vertexCount
            )
        }
        encoder.endEncoding()
    }

    private func encodeCaptureIfNeeded(
        command: MTLCommandBuffer,
        renderTarget: MTLTexture,
        width: Int,
        height: Int,
        rowBytes: Int,
        capture: Bool
    ) throws -> MTLBuffer? {
        guard capture else { return nil }
        guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else {
            throw AsyncLabError.metal("capture buffer or blit encoder unavailable")
        }
        blit.copy(
            from: renderTarget, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height
        )
        blit.endEncoding()
        return buffer
    }

    private func encodePresent(
        command: MTLCommandBuffer,
        source: MTLTexture,
        drawable: CAMetalDrawable
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw AsyncLabError.metal("present encoder unavailable")
        }
        encoder.setRenderPipelineState(presentPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static func copyCapturedRGBA(buffer: MTLBuffer, width: Int, height: Int, rowBytes: Int) -> Data {
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress else { return }
            for row in 0..<height {
                dst.advanced(by: row * width * 4).copyMemory(
                    from: buffer.contents().advanced(by: row * rowBytes), byteCount: width * 4
                )
            }
        }
        return rgba
    }
}

private final class OrderedAckDispatcher {
    private let fileDesc: Int32
    private let queue = DispatchQueue(label: "guest-gpu-lab.ack-sender", qos: .userInitiated)
    private let logQueue = DispatchQueue(label: "guest-gpu-lab.log", qos: .utility)
    private let logHandle: FileHandle
    private let captureDir: URL?
    private let splitAck: Bool
    private let semaphore: DispatchSemaphore
    private let drainGroup: DispatchGroup
    private var nextSeq: UInt32 = 0
    private var pending: [UInt32: FrameCompletion] = [:]
    private var failed = false

    init(
        fileDesc: Int32,
        logHandle: FileHandle,
        captureDir: URL?,
        splitAck: Bool,
        semaphore: DispatchSemaphore,
        drainGroup: DispatchGroup
    ) {
        self.fileDesc = fileDesc
        self.logHandle = logHandle
        self.captureDir = captureDir
        self.splitAck = splitAck
        self.semaphore = semaphore
        self.drainGroup = drainGroup
    }

    func enqueue(_ completion: FrameCompletion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending[completion.sequence] = completion
            self.flushOrdered()
        }
    }

    func hasFailed() -> Bool {
        queue.sync { failed }
    }

    private func flushOrdered() {
        while let item = pending.removeValue(forKey: nextSeq) {
            defer {
                semaphore.signal()
                drainGroup.leave()
            }
            nextSeq &+= 1
            if failed { continue }
            if !item.gpuOk {
                failed = true
                Darwin.shutdown(fileDesc, SHUT_RDWR)
                continue
            }
            if let rgba = item.capturedRGBA, let dir = captureDir {
                let fileURL = dir.appendingPathComponent("frame-\(item.sequence).rgba")
                try? rgba.write(to: fileURL, options: .atomic)
            }
            let packet = encodeAckPacket(item)
            do {
                if splitAck {
                    try sendExactly(fileDesc, data: packet.subdata(in: 0..<headerSize))
                    try sendExactly(fileDesc, data: packet.subdata(in: headerSize..<packet.count))
                } else {
                    try sendExactly(fileDesc, data: packet)
                }
            } catch {
                failed = true
                Darwin.shutdown(fileDesc, SHUT_RDWR)
                continue
            }
            let line = """
            {"sequence":\(item.sequence),"fence_id":\(item.sequence &+ 1),\
            "receive_ms":\(String(format: "%.6f", item.receiveMs)),\
            "gpu_ms":\(String(format: "%.6f", item.gpuMs)),\
            "gpu_ok":true}\n
            """
            logQueue.async { [logHandle] in
                if let data = line.data(using: .utf8) {
                    try? logHandle.write(contentsOf: data)
                }
            }
        }
    }
}

private final class AsyncHostDelegate: NSObject, NSApplicationDelegate {
    private let config: HostConfig
    private var window: NSWindow?
    private var presenter: AsyncMetalPresenter?
    private var listener: Int32 = -1
    private var logHandle: FileHandle = .standardOutput
    private let acceptQueue = DispatchQueue(label: "guest-gpu-lab.accept", qos: .userInitiated)

    init(config: HostConfig) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try setupLoggingAndCapture()
            try setupWindowAndPresenter()
            try startListener()
        } catch {
            fputs("metal_host_async: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func setupLoggingAndCapture() throws {
        if let logPath = config.logPath {
            let url = URL(fileURLWithPath: logPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: logPath, contents: nil)
            logHandle = try FileHandle(forWritingTo: url)
        }
        if let capPath = config.captureDir {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: capPath), withIntermediateDirectories: true
            )
        }
    }

    private func setupWindowAndPresenter() throws {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Guest GPU Lab Async Host"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        let layer = CAMetalLayer()
        layer.displaySyncEnabled = config.displaySyncEnabled
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        self.window = win
        self.presenter = try AsyncMetalPresenter(layer: layer, slotCount: config.maxInFlight)
    }

    private func startListener() throws {
        listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AsyncLabError.systemCall("socket", errno) }
        setSockInt(listener, level: SOL_SOCKET, option: SO_NOSIGPIPE, value: 1)
        setSockInt(listener, level: SOL_SOCKET, option: SO_REUSEADDR, value: 1)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = config.port.bigEndian
        guard inet_pton(AF_INET, config.bindAddress, &addr.sin_addr) == 1 else {
            throw AsyncLabError.usage("invalid --bind IPv4 address")
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listener, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw AsyncLabError.systemCall("bind", errno) }
        guard Darwin.listen(listener, 4) == 0 else { throw AsyncLabError.systemCall("listen", errno) }

        let deviceName = presenter?.device.name ?? "unknown"
        let mslSha = presenter?.mslSourceSHA256 ?? "unknown"
        let capEnabled = config.captureDir != nil && !config.captureFrames.isEmpty
        fputs(
            "ready bind=\(config.bindAddress) port=\(config.port) device=\(deviceName) "
            + "pipeline_mode=\(config.pipelineMode.rawValue) max_in_flight=\(config.maxInFlight) "
            + "tcp_nodelay=\(config.tcpNoDelay ? 1 : 0) display_sync=\(config.displaySyncEnabled ? 1 : 0) "
            + "capture_enabled=\(capEnabled) msl_sha256=\(mslSha)\n",
            stderr
        )
        fflush(stderr)
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func setSockInt(_ fileDesc: Int32, level: Int32, option: Int32, value: Int32) {
        var val = value
        _ = withUnsafePointer(to: &val) { ptr in
            setsockopt(fileDesc, level, option, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private func acceptLoop() {
        while listener >= 0 {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            setSockInt(client, level: SOL_SOCKET, option: SO_NOSIGPIPE, value: 1)
            setSockInt(client, level: IPPROTO_TCP, option: TCP_NODELAY, value: config.tcpNoDelay ? 1 : 0)
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            withUnsafePointer(to: &timeout) { ptr in
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }
            handleClient(client)
            Darwin.close(client)
        }
    }

    private func handleClient(_ fileDesc: Int32) {
        guard let presenter else { return }
        do {
            let hello = try AsyncHeader.decode(recvExactly(fileDesc, count: headerSize))
            guard hello.kind == .hello, hello.width > 0, hello.height > 0,
                  hello.width <= 4096, hello.height <= 4096,
                  hello.commandBytes == 512, hello.resourceBytes == 65536 else {
                throw AsyncLabError.protocolViolation("invalid v3 hello")
            }
            let clientWindow = Int(hello.aux)
            let effectiveWindow = max(1, min(config.maxInFlight, clientWindow == 0 ? 1 : clientWindow))
            let effectiveSync = (config.pipelineMode == .sync) || (effectiveWindow == 1)

            let semaphore = DispatchSemaphore(value: effectiveWindow)
            let drainGroup = DispatchGroup()
            let captureURL = config.captureDir.map { URL(fileURLWithPath: $0) }
            let dispatcher = OrderedAckDispatcher(
                fileDesc: fileDesc,
                logHandle: logHandle,
                captureDir: captureURL,
                splitAck: config.splitAck,
                semaphore: semaphore,
                drainGroup: drainGroup
            )

            try processFrameLoop(
                fileDesc: fileDesc,
                hello: hello,
                presenter: presenter,
                effectiveWindow: effectiveWindow,
                effectiveSync: effectiveSync,
                semaphore: semaphore,
                drainGroup: drainGroup,
                dispatcher: dispatcher
            )
            drainGroup.wait()
        } catch {
            fputs("metal_host_async session ended: \(error)\n", stderr)
            fflush(stderr)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func processFrameLoop(
        fileDesc: Int32,
        hello: AsyncHeader,
        presenter: AsyncMetalPresenter,
        effectiveWindow: Int,
        effectiveSync: Bool,
        semaphore: DispatchSemaphore,
        drainGroup: DispatchGroup,
        dispatcher: OrderedAckDispatcher
    ) throws {
        var expectedSeq: UInt32 = 0
        var retainedCommands = Data()
        var retainedResource = Data()
        var retainedDraws: [DrawDescriptor] = []

        while !dispatcher.hasFailed() {
            let startNs = DispatchTime.now().uptimeNanoseconds
            let headerRaw: Data
            do {
                headerRaw = try recvExactly(fileDesc, count: headerSize)
            } catch AsyncLabError.protocolViolation(let msg) where msg == "peer closed connection" {
                break
            }
            let header = try AsyncHeader.decode(headerRaw)
            guard header.kind == .frame, header.sequence == expectedSeq,
                  header.width == hello.width, header.height == hello.height,
                  header.aux == 0,
                  header.commandBytes == 0 || header.commandBytes == hello.commandBytes,
                  header.resourceBytes == 0 || header.resourceBytes == hello.resourceBytes else {
                throw AsyncLabError.protocolViolation("invalid frame header seq=\(header.sequence)")
            }
            let bodyCount = Int(header.commandBytes) + Int(header.resourceBytes)
            let body = try recvExactly(fileDesc, count: bodyCount)
            if header.commandBytes > 0 {
                retainedCommands = body.subdata(in: 0..<Int(header.commandBytes))
                retainedDraws = try DrawDescriptor.decodeBatch(
                    retainedCommands, resourceBytes: Int(hello.resourceBytes), imageWidth: Int(hello.width)
                )
            } else if retainedCommands.count != Int(hello.commandBytes) {
                throw AsyncLabError.protocolViolation("commands uninitialized")
            }
            if header.resourceBytes > 0 {
                let start = Int(header.commandBytes)
                retainedResource = body.subdata(in: start..<(start + Int(header.resourceBytes)))
            } else if retainedResource.count != Int(hello.resourceBytes) {
                throw AsyncLabError.protocolViolation("resource uninitialized")
            }

            let receiveMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            semaphore.wait()
            if dispatcher.hasFailed() {
                semaphore.signal()
                break
            }
            drainGroup.enter()
            let capture = config.captureDir != nil && config.captureFrames.contains(header.sequence)
            do {
                try presenter.encodeAndSubmit(
                    slotIndex: Int(header.sequence % UInt32(effectiveWindow)),
                    sequence: header.sequence,
                    width: Int(hello.width),
                    height: Int(hello.height),
                    commands: retainedCommands,
                    resource: retainedResource,
                    draws: retainedDraws,
                    receiveMs: receiveMs,
                    capture: capture,
                    synchronous: effectiveSync
                ) { completion in
                    dispatcher.enqueue(completion)
                }
            } catch {
                semaphore.signal()
                drainGroup.leave()
                throw error
            }
            expectedSeq &+= 1
        }
    }
}

private func parseConfig(_ args: [String]) throws -> HostConfig {
    var config = HostConfig()
    var index = 1
    while index < args.count {
        let arg = args[index]
        func nextValue() throws -> String {
            index += 1
            guard index < args.count else { throw AsyncLabError.usage("missing value for \(arg)") }
            return args[index]
        }
        switch arg {
        case "--bind": config.bindAddress = try nextValue()
        case "--port":
            guard let port = UInt16(try nextValue()) else { throw AsyncLabError.usage("invalid port") }
            config.port = port
        case "--tcp-nodelay":
            config.tcpNoDelay = (try nextValue()) != "0"
        case "--split-ack":
            config.splitAck = (try nextValue()) != "0"
        case "--pipeline-mode":
            let raw = try nextValue()
            guard let mode = PipelineMode(rawValue: raw) else {
                throw AsyncLabError.usage("invalid --pipeline-mode \(raw)")
            }
            config.pipelineMode = mode
        case "--max-in-flight":
            guard let depth = Int(try nextValue()), 1...3 ~= depth else {
                throw AsyncLabError.usage("--max-in-flight must be 1..3")
            }
            config.maxInFlight = depth
        case "--display-sync":
            config.displaySyncEnabled = (try nextValue()) != "0"
        case "--log": config.logPath = try nextValue()
        case "--capture-dir": config.captureDir = try nextValue()
        case "--capture-frames":
            let csv = try nextValue()
            let parsed = try csv.split(separator: ",").map { token -> UInt32 in
                guard let value = UInt32(token.trimmingCharacters(in: .whitespaces)) else {
                    throw AsyncLabError.usage("invalid capture frame \(token)")
                }
                return value
            }
            config.captureFrames = Set(parsed)
        default:
            throw AsyncLabError.usage("unknown option \(arg)")
        }
        index += 1
    }
    return config
}

do {
    let config = try parseConfig(CommandLine.arguments)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AsyncHostDelegate(config: config)
    app.delegate = delegate
    app.run()
} catch {
    fputs("metal_host_async: \(error)\n", stderr)
    exit(2)
}
