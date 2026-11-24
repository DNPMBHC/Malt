// SPDX-License-Identifier: GPL-3.0-or-later
//
// MultiProcessIPCBaseline.swift
// Phase 5 Window 5B: Multi-process Unix Domain Socket IPC + frame copy baseline
// simulating QEMU <-> QEMURenderServer out-of-process rendering overhead.
//

import CryptoKit
import Darwin
import Foundation

public struct IPCBenchConfig {
    public let socketPath: String
    public let width: Int
    public let height: Int
    public let drawCalls: Int
    public let frames: Int
    public let warmupFrames: Int
    public var copyFrames = true
}

public struct IPCWorkerReport: Encodable {
    public let framesRendered: Int
    public let cpuUserMs: Double
    public let cpuSysMs: Double
    public let imageSHA256: String
    public let measurementFrames: Int
}

public enum MultiProcessIPCBaseline {
    private static func writeAll(sockFd: Int32, buffer: UnsafeRawPointer, length: Int) -> Bool {
        var sent = 0
        while sent < length {
            let chunk = Darwin.write(sockFd, buffer.advanced(by: sent), length - sent)
            if chunk <= 0 {
                if errno == EINTR { continue }
                return false
            }
            sent += chunk
        }
        return true
    }

    private static func readAll(sockFd: Int32, buffer: UnsafeMutableRawPointer, length: Int) -> Bool {
        var received = 0
        while received < length {
            let chunk = Darwin.read(sockFd, buffer.advanced(by: received), length - received)
            if chunk <= 0 {
                if chunk < 0 && errno == EINTR { continue }
                return false
            }
            received += chunk
        }
        return true
    }

    private static func makeUnixAddress(path: String) -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 104) { dst in
                let count = min(utf8.count, 103)
                for idx in 0..<count {
                    dst[idx] = utf8[idx]
                }
                dst[count] = 0
            }
        }
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    private static func openServerSocket(socketPath: String) throws -> Int32 {
        unlink(socketPath)
        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw NSError(domain: "VZGPUBridge", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create AF_UNIX socket"
            ])
        }
        var (addr, addrLen) = makeUnixAddress(path: socketPath)
        let bindStatus = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.bind(serverFd, sptr, addrLen)
            }
        }
        guard bindStatus == 0, Darwin.listen(serverFd, 1) == 0 else {
            close(serverFd)
            throw NSError(domain: "VZGPUBridge", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Failed to bind/listen on Unix socket"
            ])
        }
        return serverFd
    }

    private static func connectClientSocket(socketPath: String) throws -> Int32 {
        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientFd >= 0 else {
            throw NSError(domain: "VZGPUBridge", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create client AF_UNIX socket"
            ])
        }
        var (addr, addrLen) = makeUnixAddress(path: socketPath)
        for _ in 0..<50 {
            let connStatus = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                    Darwin.connect(clientFd, sptr, addrLen)
                }
            }
            if connStatus == 0 {
                return clientFd
            }
            usleep(20_000)
        }
        close(clientFd)
        throw NSError(domain: "VZGPUBridge", code: 24, userInfo: [
            NSLocalizedDescriptionKey: "Timed out connecting to IPC worker"
        ])
    }

    public static func runWorker(config: IPCBenchConfig) throws -> IPCWorkerReport {
        let serverFd = try openServerSocket(socketPath: config.socketPath)
        defer {
            close(serverFd)
            unlink(config.socketPath)
        }
        let clientFd = Darwin.accept(serverFd, nil, nil)
        guard clientFd >= 0 else {
            throw NSError(domain: "VZGPUBridge", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Failed to accept IPC client"
            ])
        }
        defer { close(clientFd) }

        let renderer = try InProcessZeroCopyRenderer(
            width: config.width,
            height: config.height,
            maxDraws: config.drawCalls
        )
        let cmdBytes = config.drawCalls * MemoryLayout<DrawBatchCommand>.stride
        let frameBytes = config.copyFrames ? config.width * config.height * 4 : 8
        let cmdBuf = UnsafeMutableRawPointer.allocate(byteCount: cmdBytes, alignment: 16)
        let frameBuf = UnsafeMutableRawPointer.allocate(byteCount: frameBytes, alignment: 16)
        defer {
            cmdBuf.deallocate()
            frameBuf.deallocate()
        }

        var cpuStart = InProcessZeroCopyRenderer.processCpuTimesMs()
        let totalFrames = config.frames + config.warmupFrames
        var rendered = 0
        for idx in 0..<totalFrames {
            if idx == config.warmupFrames { cpuStart = InProcessZeroCopyRenderer.processCpuTimesMs() }
            guard readAll(sockFd: clientFd, buffer: cmdBuf, length: cmdBytes) else { break }
            try renderer.renderFrame(
                drawCalls: config.drawCalls,
                frameIndex: UInt32(idx),
                readbackToBuffer: config.copyFrames ? frameBuf : nil,
                incomingCommands: cmdBuf
            )
            if !config.copyFrames { frameBuf.storeBytes(of: UInt64(idx).littleEndian, as: UInt64.self) }
            guard writeAll(sockFd: clientFd, buffer: frameBuf, length: frameBytes) else { break }
            rendered += 1
        }
        let cpuEnd = InProcessZeroCopyRenderer.processCpuTimesMs()
        return IPCWorkerReport(
            framesRendered: rendered,
            cpuUserMs: cpuEnd.userMs - cpuStart.userMs,
            cpuSysMs: cpuEnd.sysMs - cpuStart.sysMs,
            imageSHA256: renderer.imageSHA256(),
            measurementFrames: max(0, rendered - config.warmupFrames)
        )
    }

    private static func exchangeFrame(
        sockFd: Int32,
        cmdBuf: UnsafeRawPointer,
        cmdBytes: Int,
        frameBuf: UnsafeMutableRawPointer,
        frameBytes: Int
    ) throws {
        guard writeAll(sockFd: sockFd, buffer: cmdBuf, length: cmdBytes),
              readAll(sockFd: sockFd, buffer: frameBuf, length: frameBytes) else {
            throw NSError(domain: "VZGPUBridge", code: 26, userInfo: [
                NSLocalizedDescriptionKey: "IPC frame transfer failed"
            ])
        }
    }

    private static func verifyACK(config: IPCBenchConfig, frame: UnsafeMutableRawPointer,
                                  expected: Int) throws {
        guard config.copyFrames || UInt64(littleEndian: frame.load(as: UInt64.self)) == UInt64(expected) else {
            throw NSError(domain: "IPCFrameSequence", code: 1)
        }
    }

    public static func runClient(config: IPCBenchConfig) throws -> BenchmarkSample {
        let clientFd = try connectClientSocket(socketPath: config.socketPath)
        defer { close(clientFd) }
        let cmdBytes = config.drawCalls * MemoryLayout<DrawBatchCommand>.stride
        let frameBytes = config.copyFrames ? config.width * config.height * 4 : 8
        let cmdBuf = UnsafeMutableRawPointer.allocate(byteCount: cmdBytes, alignment: 16)
        let frameBuf = UnsafeMutableRawPointer.allocate(byteCount: frameBytes, alignment: 16)
        defer { cmdBuf.deallocate(); frameBuf.deallocate() }

        for index in 0..<config.warmupFrames {
            InProcessZeroCopyRenderer.fillCommands(cmdBuf, draws: config.drawCalls, frame: UInt32(index))
            try exchangeFrame(
                sockFd: clientFd, cmdBuf: cmdBuf, cmdBytes: cmdBytes, frameBuf: frameBuf, frameBytes: frameBytes
            )
            try verifyACK(config: config, frame: frameBuf, expected: index)
        }
        let cpuStart = InProcessZeroCopyRenderer.processCpuTimesMs()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var latencies: [Double] = []
        latencies.reserveCapacity(config.frames)
        for index in 0..<config.frames {
            let fStart = DispatchTime.now().uptimeNanoseconds
            InProcessZeroCopyRenderer.fillCommands(cmdBuf, draws: config.drawCalls,
                                                   frame: UInt32(index + config.warmupFrames))
            try exchangeFrame(
                sockFd: clientFd, cmdBuf: cmdBuf, cmdBytes: cmdBytes, frameBuf: frameBuf, frameBytes: frameBytes
            )
            try verifyACK(config: config, frame: frameBuf, expected: index + config.warmupFrames)
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - fStart) / 1_000_000.0)
        }
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000.0
        let cpuEnd = InProcessZeroCopyRenderer.processCpuTimesMs()
        return makeClientSample(config: config, frame: (frameBuf, frameBytes),
                                latencies: latencies, wallMs: wallMs,
                                cpu: (cpuEnd.userMs - cpuStart.userMs, cpuEnd.sysMs - cpuStart.sysMs))
    }

    private static func makeClientSample(config: IPCBenchConfig,
                                         frame: (buffer: UnsafeMutableRawPointer, bytes: Int),
                                         latencies: [Double], wallMs: Double,
                                         cpu: (userMs: Double, sysMs: Double)) -> BenchmarkSample {
        let bytes = frame.buffer.bindMemory(to: UInt8.self, capacity: 4)
        let input = InProcessZeroCopyRenderer.BenchmarkSampleInput(
            mode: config.copyFrames ? "multi_process_ipc_copy" : "multi_process_ipc_ack",
            width: config.width,
            height: config.height,
            drawCalls: config.drawCalls,
            warmupFrames: config.warmupFrames,
            latenciesMs: latencies,
            wallMs: wallMs,
            cpuUserMs: cpu.userMs,
            cpuSysMs: cpu.sysMs,
            zeroCopySurfaceActive: false,
            firstPixel: config.copyFrames ? [bytes[0], bytes[1], bytes[2], bytes[3]] : []
        )
        var sample = InProcessZeroCopyRenderer.makeSample(input)
        let image = Data(bytes: frame.buffer, count: frame.bytes)
        if config.copyFrames {
            sample.imageSHA256 = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        }
        sample.submittedCommands = UInt64(config.drawCalls * (config.frames + config.warmupFrames))
        sample.gpuCompletedFrames = UInt64(config.frames + config.warmupFrames)
        return sample
    }
}
