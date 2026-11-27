// SPDX-License-Identifier: GPL-3.0-or-later
// Zero-privilege full TCP+UDP+ICMP high-QoS Unix-socket proxy lifecycle manager.

import Darwin
import Foundation

/// Active local Unix-socket endpoint owned by Malt's bundled zero-privilege network proxy.
public struct ManagedUserNetProxyEndpoint: Equatable, Sendable {
    public let vmIdentifier: String
    public let socketPath: String
    public let qosUserInteractive: Bool
    public let processIdentifier: Int32

    public init(
        vmIdentifier: String,
        socketPath: String,
        qosUserInteractive: Bool,
        processIdentifier: Int32
    ) {
        self.vmIdentifier = vmIdentifier
        self.socketPath = socketPath
        self.qosUserInteractive = qosUserInteractive
        self.processIdentifier = processIdentifier
    }
}

/// Abstracts spawning and terminating the proxy process for deterministic testing.
public struct ManagedUserNetProxyProcessHandle: Sendable {
    public let processIdentifier: Int32
    public let isAlive: @Sendable () -> Bool
    public let terminate: @Sendable () -> Void

    public init(
        processIdentifier: Int32,
        isAlive: @escaping @Sendable () -> Bool,
        terminate: @escaping @Sendable () -> Void
    ) {
        self.processIdentifier = processIdentifier
        self.isAlive = isAlive
        self.terminate = terminate
    }
}

/// Result of spawning the bundled user-space network proxy.
public struct ManagedUserNetSpawnResult: Sendable {
    public let handle: ManagedUserNetProxyProcessHandle
    public let endpoint: String
    public let qosUserInteractive: Bool

    public init(handle: ManagedUserNetProxyProcessHandle, endpoint: String, qosUserInteractive: Bool) {
        self.handle = handle
        self.endpoint = endpoint
        self.qosUserInteractive = qosUserInteractive
    }
}

/// Manages the lifecycle of the bundled `malt-net-proxy` helper on a private Unix or loopback socket.
public actor ManagedUserNetProxyService {
    public typealias Spawner = @Sendable (String, String) async throws -> ManagedUserNetSpawnResult

    private struct ActiveState {
        let endpoint: ManagedUserNetProxyEndpoint
        let handle: ManagedUserNetProxyProcessHandle
    }

    private var active: ActiveState?
    private let spawner: Spawner
    private let socketDirectoryOverride: URL?

    public init(socketDirectory: URL? = nil, spawner: Spawner? = nil) {
        self.socketDirectoryOverride = socketDirectory
        self.spawner = spawner ?? Self.defaultSpawn
    }

    public func activeEndpoint() -> ManagedUserNetProxyEndpoint? {
        guard let current = active, current.handle.isAlive() else { return nil }
        return current.endpoint
    }

    /// Starts (or reuses) the high-QoS Unix-socket proxy for the target VM.
    public func ensureRunning(
        binaryPath: String,
        vmIdentifier: String
    ) async throws -> ManagedUserNetProxyEndpoint {
        if let current = active,
           current.endpoint.vmIdentifier.caseInsensitiveCompare(vmIdentifier) == .orderedSame,
           current.handle.isAlive(),
           Self.isEndpointReady(current.endpoint.socketPath) {
            return current.endpoint
        }
        stop()

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw UnifiedOrchestrationError.backendUnavailable("随包零特权网络代理组件缺失或不可执行。")
        }
        let listenTarget: String
        if let overrideDir = socketDirectoryOverride {
            let socketURL = try prepareSocketURL(vmIdentifier: vmIdentifier, directory: overrideDir)
            listenTarget = "unix://" + socketURL.path(percentEncoded: false)
        } else {
            // Sandboxed QEMUHelper.xpc permits loopback client sockets via com.apple.security.network.client.
            listenTarget = "127.0.0.1:0"
        }
        let spawned = try await spawner(binaryPath, listenTarget)
        let endpoint = ManagedUserNetProxyEndpoint(
            vmIdentifier: vmIdentifier,
            socketPath: spawned.endpoint,
            qosUserInteractive: spawned.qosUserInteractive,
            processIdentifier: spawned.handle.processIdentifier
        )
        active = ActiveState(endpoint: endpoint, handle: spawned.handle)
        return endpoint
    }

    /// Stops the proxy cleanly and removes its Unix socket file if applicable.
    public func stop() {
        guard let current = active else { return }
        active = nil
        current.handle.terminate()
        let raw = current.endpoint.socketPath
        if raw.hasPrefix("/") {
            try? FileManager.default.removeItem(atPath: raw)
        } else if raw.hasPrefix("unix://") {
            try? FileManager.default.removeItem(atPath: String(raw.dropFirst(7)))
        }
    }

    public nonisolated static func defaultSocketDirectory() -> URL {
        URL(filePath: "/tmp/malt-net-\(getuid())", directoryHint: .isDirectory)
    }

    private func prepareSocketURL(vmIdentifier: String, directory dir: URL) throws -> URL {
        let dirPath = dir.path(percentEncoded: false)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirPath)
        let cleanPrefix = String(vmIdentifier.lowercased().filter { $0.isHexDigit }.prefix(8))
        let name = "p-\(cleanPrefix.isEmpty ? "vm" : cleanPrefix).sock"
        let socketURL = dir.appending(path: name)
        guard socketURL.path(percentEncoded: false).utf8.count < 100 else {
            throw UnifiedOrchestrationError.backendUnavailable("代理 Unix Socket 路径过长，无法建立网络通道。")
        }
        return socketURL
    }

    private static func isEndpointReady(_ endpoint: String) -> Bool {
        if endpoint.hasPrefix("/") {
            return isPrivateSocket(endpoint)
        }
        if endpoint.hasPrefix("unix://") {
            return isPrivateSocket(String(endpoint.dropFirst(7)))
        }
        return endpoint.contains(":")
    }

    private static func isPrivateSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && (info.st_mode & 0o777) == 0o600
    }

    private static func defaultSpawn(
        binaryPath: String, listenTarget: String
    ) async throws -> ManagedUserNetSpawnResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(filePath: binaryPath)
        process.arguments = ["-listen", listenTarget]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let readyLine = await readReadyLine(from: stdoutPipe)
        guard let readyLine, readyLine.hasPrefix("READY ") else {
            process.terminate()
            throw UnifiedOrchestrationError.commandFailed("零特权网络代理未在规定时间内就绪。")
        }
        let tokens = readyLine.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else {
            process.terminate()
            throw UnifiedOrchestrationError.commandFailed("零特权网络代理未返回有效监听端点。")
        }
        let handle = ManagedUserNetProxyProcessHandle(
            processIdentifier: process.processIdentifier,
            isAlive: { process.isRunning },
            terminate: {
                if process.isRunning {
                    process.terminate()
                    let deadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < deadline { usleep(20_000) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        )
        return ManagedUserNetSpawnResult(
            handle: handle, endpoint: tokens[1], qosUserInteractive: readyLine.contains("QOS_INTERACTIVE=true")
        )
    }

    private static func readReadyLine(from pipe: Pipe) async -> String? {
        let readTask = Task.detached(priority: .userInitiated) { () -> String? in
            var buffer = Data()
            let handle = pipe.fileHandleForReading
            while buffer.count < 1024 {
                guard let chunk = try? handle.read(upToCount: 1), !chunk.isEmpty else { break }
                if chunk[0] == 0x0A { break }
                buffer.append(chunk)
            }
            return String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await readTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Safely rewrites a stopped playable container's QEMU netdev stream to point at a managed Unix socket.
enum ManagedUserNetConfigRewriter {
    static let backupFilename = ".managed-net-backup.plist"

    @discardableResult
    static func applyUnixSocketStream(
        bundlePath: String, socketPath: String, fileManager: FileManager = .default
    ) throws -> Bool {
        let bundle = URL(filePath: bundlePath).standardizedFileURL
        guard !ContainerProvisioningPipeline.isProtectedBundle(bundle, fileManager: fileManager) else {
            throw UnifiedOrchestrationError.backendUnavailable("禁止修改受保护母盘或冷备容器的网络配置。")
        }
        let configURL = bundle.appending(path: "config.plist")
        let original = try Data(contentsOf: configURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var config = try PropertyListSerialization.propertyList(
            from: original, options: [], format: &format) as? [String: Any] else {
            throw UnifiedOrchestrationError.backendUnavailable("无法解析容器网络配置。")
        }
        let macAddress = existingMacAddress(in: config) ?? generateStableUnicastMAC(from: config)
        var qemu = config["QEMU"] as? [String: Any] ?? [:]
        var args = extractStringArguments(from: qemu)
        let netdevVal = netdevStreamValue(for: socketPath)
        let devVal = "virtio-net-pci,netdev=net0,mac=\(macAddress),ioeventfd=on"
        args = removePair(args, flag: "-global", matchPrefix: "virtio-net-pci.rx_queue_size=")
        args = upsertPair(args, flag: "-netdev", value: netdevVal, matchPrefix: "stream,id=net0,")
        args = upsertPair(args, flag: "-device", value: devVal, matchPrefix: "virtio-net-pci,netdev=net0,")
        for token in args where token.hasPrefix("-") {
            guard ContainerProvisioningConstants.allowedQEMUFlags.contains(token) else {
                throw UnifiedOrchestrationError.backendUnavailable("检测到非白名单 QEMU 网络参数，已拒绝写入。")
            }
        }
        let backupURL = bundle.appending(path: backupFilename)
        let backupPath = backupURL.path(percentEncoded: false)
        if !fileManager.fileExists(atPath: backupPath) {
            try original.write(to: backupURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
        }
        config["Network"] = []
        qemu["AdditionalArguments"] = args
        config["QEMU"] = qemu
        let encoded = try PropertyListSerialization.data(fromPropertyList: config, format: format, options: 0)
        if encoded == original { return false }
        try encoded.write(to: configURL, options: .atomic)
        return true
    }

    private static func extractStringArguments(from qemu: [String: Any]) -> [String] {
        if let strings = qemu["AdditionalArguments"] as? [String] { return strings }
        if let dicts = qemu["AdditionalArguments"] as? [[String: Any]] {
            return dicts.compactMap { $0["Argument"] as? String }
        }
        return []
    }

    private static func netdevStreamValue(for endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("unix://") {
            return "stream,id=net0,server=off,addr.type=unix,path=\(trimmed.dropFirst(7))"
        }
        if trimmed.hasPrefix("/") {
            return "stream,id=net0,server=off,addr.type=unix,path=\(trimmed)"
        }
        let cleaned = trimmed.hasPrefix("tcp://") ? String(trimmed.dropFirst(6)) : trimmed
        let parts = cleaned.split(separator: ":", maxSplits: 1).map(String.init)
        let host = parts.first ?? "127.0.0.1"
        let port = parts.count > 1 ? parts[1] : "0"
        return "stream,id=net0,server=off,addr.type=inet,addr.host=\(host),addr.port=\(port)"
    }

    private static func existingMacAddress(in config: [String: Any]) -> String? {
        if let nics = config["Network"] as? [[String: Any]],
           let mac = nics.first?["MacAddress"] as? String, !mac.isEmpty {
            return mac
        }
        let qemu = config["QEMU"] as? [String: Any] ?? [:]
        let args = extractStringArguments(from: qemu)
        for arg in args where arg.contains("virtio-net-pci,netdev=net0,") {
            if let range = arg.range(of: #"mac=([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})"#, options: .regularExpression) {
                return String(arg[range].dropFirst(4))
            }
        }
        return nil
    }

    private static func generateStableUnicastMAC(from config: [String: Any]) -> String {
        let uuid = ((config["Information"] as? [String: Any])?["UUID"] as? String ?? UUID().uuidString)
            .filter { $0.isHexDigit }.uppercased()
        let chars = Array(uuid.padding(toLength: 10, withPad: "A", startingAt: 0))
        return "52:54:\(chars[0])\(chars[1]):\(chars[2])\(chars[3]):\(chars[4])\(chars[5]):\(chars[6])\(chars[7])"
    }

    private static func removePair(_ args: [String], flag: String, matchPrefix: String) -> [String] {
        var out: [String] = []
        var idx = 0
        while idx < args.count {
            if idx + 1 < args.count && args[idx] == flag && args[idx + 1].hasPrefix(matchPrefix) {
                idx += 2
                continue
            }
            out.append(args[idx])
            idx += 1
        }
        return out
    }

    private static func upsertPair(_ args: [String], flag: String, value: String, matchPrefix: String) -> [String] {
        var out: [String] = []
        var idx = 0
        var replaced = false
        while idx < args.count {
            if idx + 1 < args.count && args[idx] == flag && args[idx + 1].hasPrefix(matchPrefix) {
                if !replaced { out.append(contentsOf: [flag, value]); replaced = true }
                idx += 2
                continue
            }
            out.append(args[idx])
            idx += 1
        }
        if !replaced { out.append(contentsOf: [flag, value]) }
        return out
    }
}
