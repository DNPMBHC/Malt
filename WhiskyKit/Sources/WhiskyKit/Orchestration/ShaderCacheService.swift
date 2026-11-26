// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

public struct ShaderCacheTarget: Hashable, Sendable {
    public let label: String
    public let url: URL
    public init(label: String, url: URL) { self.label = label; self.url = url.standardizedFileURL }
}

public struct ShaderCacheIssue: Equatable, Sendable {
    public let label: String
    public let message: String
}

public struct ShaderCacheSummary: Equatable, Sendable {
    public let byteCount: Int64
    public let failures: [ShaderCacheIssue]
}

public enum ShaderCacheActivityState: Equatable, Sendable { case idle, active, unknown }

public struct ShaderCacheCleanupResult: Equatable, Sendable {
    public let removedCount: Int
    public let removedBytes: Int64
    public let failures: [ShaderCacheIssue]
    public let activityState: ShaderCacheActivityState
    public var wasBlocked: Bool { activityState != .idle }
}

/// Measurement and cleanup share one explicit list of managed cache targets.
public struct ShaderCacheService: @unchecked Sendable {
    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func targets(bottleURLs: [URL], cachesDirectory: URL? = nil,
                        darwinCacheDirectory: URL? = nil) -> [ShaderCacheTarget] {
        var result: [ShaderCacheTarget] = []
        if let directory = cachesDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            result.append(.init(label: "共享 DXMT", url: directory.appending(path: "dxmt-shader-cache")))
        }
        if let directory = darwinCacheDirectory ?? Self.darwinUserCacheDirectory() {
            result.append(.init(label: "共享 D3DMetal", url: directory.appending(path: "d3dm")))
        }
        for (index, bottle) in Array(Set(bottleURLs.map(\.standardizedFileURL)))
            .sorted(by: { $0.path < $1.path }).enumerated() {
            result.append(.init(label: "兼容容器 \(index + 1) DXMT", url: bottle.appending(path: "dxmt_shader_cache")))
            result.append(.init(label: "兼容容器 \(index + 1) DXVK", url: bottle.appending(path: "dxvk_state_cache")))
        }
        return uniqueTargets(result)
    }

    public func measure(targets: [ShaderCacheTarget]) -> ShaderCacheSummary {
        var bytes: Int64 = 0
        var failures: [ShaderCacheIssue] = []
        for target in uniqueTargets(targets) {
            let summary = inspect(target)
            bytes = Self.add(bytes, summary.byteCount)
            failures += summary.failures
        }
        return ShaderCacheSummary(byteCount: bytes, failures: failures)
    }

    /// Rechecks activity before each removal. Unknown activity always fails closed.
    public func clear(
        targets: [ShaderCacheTarget],
        activityCheck: () -> ShaderCacheActivityState = { Self.processActivity() }
    ) -> ShaderCacheCleanupResult {
        var removedCount = 0
        var removedBytes: Int64 = 0
        var failures: [ShaderCacheIssue] = []
        var activity = activityCheck()
        guard activity == .idle else {
            return .init(removedCount: 0, removedBytes: 0, failures: [], activityState: activity)
        }
        for target in uniqueTargets(targets) {
            activity = activityCheck()
            guard activity == .idle else { break }
            let summary = inspect(target)
            guard summary.failures.isEmpty else { failures += summary.failures; continue }
            guard fileManager.fileExists(atPath: target.url.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: target.url)
                removedCount += 1
                removedBytes = Self.add(removedBytes, summary.byteCount)
            } catch { failures.append(Self.issue(target, error)) }
        }
        return .init(removedCount: removedCount, removedBytes: removedBytes,
                     failures: failures, activityState: activity)
    }

    public static func processActivity(additionalExecutableNames: [String] = []) -> ShaderCacheActivityState {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let snapshot = String(data: data, encoding: .utf8) else { return .unknown }
            return classifyProcessSnapshot(snapshot, additionalExecutableNames: additionalExecutableNames)
        } catch { return .unknown }
    }

    public static func classifyProcessSnapshot(_ snapshot: String,
                                               additionalExecutableNames: [String] = []) -> ShaderCacheActivityState {
        let commands = snapshot.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !commands.isEmpty else { return .unknown }
        let additional = Set(additionalExecutableNames.map { $0.lowercased() }.filter { !$0.isEmpty })
        for command in commands {
            let executable = URL(filePath: command).lastPathComponent.lowercased()
            if executable.hasPrefix("wine") || executable.hasPrefix("qemu") || executable.hasPrefix("utm")
                || executable.hasSuffix(".exe") || additional.contains(executable) { return .active }
        }
        return .idle
    }

    private func inspect(_ target: ShaderCacheTarget) -> ShaderCacheSummary {
        var stack = [target.url]
        var total: Int64 = 0
        var failures: [ShaderCacheIssue] = []
        while let url = stack.popLast() {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    if url == target.url {
                        failures.append(.init(label: target.label, message: "缓存根目录为符号链接，已跳过。"))
                    }
                    continue
                }
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    stack += try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                } else if attributes[.type] as? FileAttributeType == .typeRegular {
                    total = Self.add(total, max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0))
                }
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain,
                   failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError,
                   url == target.url { continue }
                failures.append(Self.issue(target, error))
            }
        }
        return .init(byteCount: total, failures: failures)
    }

    private func uniqueTargets(_ targets: [ShaderCacheTarget]) -> [ShaderCacheTarget] {
        var seen = Set<URL>()
        return targets.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }

    private static func issue(_ target: ShaderCacheTarget, _ error: Error) -> ShaderCacheIssue {
        .init(label: target.label, message: "无法访问或清理此缓存（错误代码 \((error as NSError).code)）。")
    }

    private static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func darwinUserCacheDirectory() -> URL? {
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length) > 1 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8) else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
