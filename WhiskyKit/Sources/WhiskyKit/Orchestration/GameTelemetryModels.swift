// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only telemetry report models, log/process parsers, and privacy redactor for Malt.

import Foundation

/// Summary statistics for a numeric series (FPS, CPU%, RSS MiB, frame times).
public struct TelemetryDistribution: Codable, Equatable, Sendable {
    public let count: Int
    public let mean: Double
    public let p50: Double
    public let p5Low: Double
    public let p1Low: Double
    public let p01Low: Double
    public let p95: Double
    public let minValue: Double
    public let maxValue: Double

    public static let empty = TelemetryDistribution(
        count: 0, mean: 0, p50: 0, p5Low: 0, p1Low: 0, p01Low: 0, p95: 0, minValue: 0, maxValue: 0
    )
}

/// A critical hitch (<5 FPS) entry with redacted nearby log context.
public struct TelemetryCriticalDrop: Codable, Equatable, Sendable {
    public let lineIndex: Int
    public let fps: Double
    public let contextLines: [String]
}

/// Dimension 1: Read-only FPS, frame time breakdown, and hitch attribution.
public struct TelemetryFPSMetrics: Codable, Equatable, Sendable {
    public let source: String
    public let fps: TelemetryDistribution
    public let workMs: TelemetryDistribution
    public let slackMs: TelemetryDistribution
    public let slopMs: TelemetryDistribution
    public let criticalDropCount: Int
    public let criticalDropsSample: [TelemetryCriticalDrop]

    public static let unavailable = TelemetryFPSMetrics(
        source: "unavailable", fps: .empty, workMs: .empty, slackMs: .empty,
        slopMs: .empty, criticalDropCount: 0, criticalDropsSample: []
    )
}

/// Per-process host CPU% and RSS MiB distribution.
public struct TelemetryProcessStats: Codable, Equatable, Sendable {
    public let cpuPercent: TelemetryDistribution
    public let rssMiB: TelemetryDistribution

    public static let empty = TelemetryProcessStats(cpuPercent: .empty, rssMiB: .empty)
}

/// Dimension 2: Host per-process CPU/RSS, thermal state, and memory pressure deltas.
public struct TelemetryHostMetrics: Codable, Equatable, Sendable {
    public let sampleIntervalSeconds: Double
    public let sampleCount: Int
    public let qemuWorker: TelemetryProcessStats
    public let qemuRenderServer: TelemetryProcessStats
    public let maltHelper: TelemetryProcessStats
    public let maltNetProxy: TelemetryProcessStats
    public let thermalStateCounts: [String: Int]
    public let vmStatCompressedPagesDelta: Int64
    public let vmStatPageoutsDelta: Int64
}

/// Dimension 3: Active network transport and game log network health counters.
public struct TelemetryNetworkMetrics: Codable, Equatable, Sendable {
    public let activeMode: String
    public let burstLossCount: Int
    public let highPingOver200MsCount: Int
    public let ack256Count: Int
}

/// Dimension 4: Shader cache growth and read-only guest disk/event health.
public struct TelemetryCacheAndGuestMetrics: Codable, Equatable, Sendable {
    public let dxmtCacheFilesStart: Int
    public let dxmtCacheFilesEnd: Int
    public let dxmtCacheBytesStart: Int64
    public let dxmtCacheBytesEnd: Int64
    public let guestDriveCFreeGiB: Double?
    public let guestDriveFFreeGiB: Double?
    public let guestSystemEvent26Count: Int?
    public let guestBackgroundCrashCount: Int?
}

/// Dimension 5: Display policy, fullscreen shell, cursor, and mouse input config.
public struct TelemetryDisplayInputSnapshot: Codable, Equatable, Sendable {
    public let displayPolicy: String
    public let fpsLimit: Int
    public let appShellFullscreenEnabled: Bool
    public let keepCursorVisibleOnInhibit: Bool
    public let pureRelativeMouse: Bool
    public let mouseCoalesceMicros: Int
    public let blockAccidentalShortcuts: Bool
    public let blockLeftCommandKey: Bool
    public let persistentCacheEnabled: Bool
    public var graphicsBackend: String?
    public var metalFXUpscaleFactor: String?
    public var displayPresentMode: String?
    public var hvfTSOEnabled: Bool?
    public var neptuneProfilerEnabled: Bool?
}

/// Dimension 6: Host hardware, allocated VM resources, and build fingerprint.
public struct TelemetryHardwareFingerprint: Codable, Equatable, Sendable {
    public let chipName: String
    public let totalCores: Int
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let physicalMemoryGiB: Int
    public let displayRefreshRateHz: Int
    public let allocatedVCPU: Int?
    public let allocatedRAMMiB: Int?
    public let presetTier: String
    public let appVersion: String
}

/// Top-level redacted 6-dimension performance telemetry report.
public struct GameTelemetryReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: String
    public let gameName: String
    public let engineKind: String
    public let executablePathRedacted: String
    public let startedAtUTC: String
    public let endedAtUTC: String
    public let durationSeconds: Double
    public let status: String
    public let fpsMetrics: TelemetryFPSMetrics
    public let hostMetrics: TelemetryHostMetrics
    public let networkMetrics: TelemetryNetworkMetrics
    public let cacheAndGuestMetrics: TelemetryCacheAndGuestMetrics
    public let displayInputSnapshot: TelemetryDisplayInputSnapshot
    public let hardwareFingerprint: TelemetryHardwareFingerprint
    public var neptunePresentSummary: TelemetryNeptunePresentSummary?
}

/// Pure statistical helpers for telemetry series.
public enum GameTelemetryMath {
    public static func distribution(of values: [Double]) -> TelemetryDistribution {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        return TelemetryDistribution(
            count: count,
            mean: rounded(sum / Double(count)),
            p50: rounded(percentile(sorted, 0.50)),
            p5Low: rounded(percentile(sorted, 0.05)),
            p1Low: rounded(percentile(sorted, 0.01)),
            p01Low: rounded(percentile(sorted, 0.001)),
            p95: rounded(percentile(sorted, 0.95)),
            minValue: rounded(sorted[0]),
            maxValue: rounded(sorted[count - 1])
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(1.0, max(0.0, fraction))
        let index = Int((clamped * Double(sorted.count - 1)).rounded(.down))
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

/// Privacy redactor stripping local home directory and private external volume names.
public enum GameTelemetryPrivacyRedactor {
    public static func redact(
        _ input: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        var result = input
        if !homeDirectory.isEmpty {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        result = replaceRegex(
            in: result,
            pattern: #"/Users/[^/\s"'\\]+"#,
            template: "~"
        )
        result = replaceRegex(
            in: result,
            pattern: #"/Volumes/(?!Macintosh HD(?:/|$))[^/\s"'\\]+"#,
            template: "<EXTERNAL_VOLUME>"
        )
        return result
    }

    private static func replaceRegex(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Single parsed host process sample bucketed by Malt/QEMU component.
public struct TelemetryHostSample: Equatable, Sendable {
    public let qemuWorkerCPU: Double
    public let qemuWorkerRSSMiB: Double
    public let qemuRenderCPU: Double
    public let qemuRenderRSSMiB: Double
    public let maltHelperCPU: Double
    public let maltHelperRSSMiB: Double
    public let maltNetProxyCPU: Double
    public let maltNetProxyRSSMiB: Double
}

/// Parses `ps` and `vm_stat` outputs without mutating any system state.
public enum GameTelemetryHostParser {
    public static func parsePSOutput(_ output: String) -> TelemetryHostSample {
        var workerCPU = 0.0, workerRSS = 0.0
        var renderCPU = 0.0, renderRSS = 0.0
        var helperCPU = 0.0, helperRSS = 0.0
        var proxyCPU = 0.0, proxyRSS = 0.0

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count >= 4,
                  let cpu = Double(parts[1]),
                  let rssKiB = Double(parts[2]) else { continue }
            let rssMiB = rssKiB / 1024.0
            let command = String(parts[3]).lowercased()

            if command.contains("qemu") && command.contains("render") {
                renderCPU += cpu
                renderRSS += rssMiB
            } else if command.contains("qemu-aarch64") || command.contains("qemu-system")
                || command.contains("qemuhelper") {
                workerCPU += cpu
                workerRSS += rssMiB
            } else if command.contains("malt-net-proxy") {
                proxyCPU += cpu
                proxyRSS += rssMiB
            } else if command.contains("maltcontainerhelper") || command.contains("utm-custom") {
                helperCPU += cpu
                helperRSS += rssMiB
            }
        }
        return TelemetryHostSample(
            qemuWorkerCPU: workerCPU, qemuWorkerRSSMiB: workerRSS,
            qemuRenderCPU: renderCPU, qemuRenderRSSMiB: renderRSS,
            maltHelperCPU: helperCPU, maltHelperRSSMiB: helperRSS,
            maltNetProxyCPU: proxyCPU, maltNetProxyRSSMiB: proxyRSS
        )
    }

    public static func parseVMStat(_ output: String) -> (compressedPages: Int64, pageouts: Int64) {
        var compressed: Int64 = 0
        var pageouts: Int64 = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            if lower.contains("pages occupied by compressor") {
                compressed = extractTrailingInt64(from: String(line))
            } else if lower.contains("pageouts:") {
                pageouts = extractTrailingInt64(from: String(line))
            }
        }
        return (compressed, pageouts)
    }

    private static func extractTrailingInt64(from line: String) -> Int64 {
        let digits = line.split(separator: ":").last?
            .trimmingCharacters(in: CharacterSet.decimalDigits.inverted) ?? ""
        return Int64(digits) ?? 0
    }
}

/// Parses read-only Unreal Engine / VALORANT `ShooterGame.log` excerpts.
public enum GameTelemetryLogParser {
    public struct ParsedLogResult: Equatable, Sendable {
        public let fpsMetrics: TelemetryFPSMetrics
        public let burstLossCount: Int
        public let highPingOver200MsCount: Int
        public let ack256Count: Int
    }

    private struct LogAccumulator {
        var fpsValues: [Double] = []
        var workValues: [Double] = []
        var slackValues: [Double] = []
        var slopValues: [Double] = []
        var criticalDrops: [TelemetryCriticalDrop] = []
        var criticalCount = 0
        var burstLossCount = 0
        var highPingCount = 0
        var ack256Count = 0
    }

    public static func parseShooterGameLog(
        _ content: String,
        sourceName: String = "ShooterGame.log",
        homeDirectory: String = NSHomeDirectory()
    ) -> ParsedLogResult {
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        var acc = LogAccumulator()
        for (index, line) in lines.enumerated() {
            consumeLine(line, index: index, allLines: lines, homeDirectory: homeDirectory, into: &acc)
        }
        let metrics = TelemetryFPSMetrics(
            source: acc.fpsValues.isEmpty ? "unavailable" : sourceName,
            fps: GameTelemetryMath.distribution(of: acc.fpsValues),
            workMs: GameTelemetryMath.distribution(of: acc.workValues),
            slackMs: GameTelemetryMath.distribution(of: acc.slackValues),
            slopMs: GameTelemetryMath.distribution(of: acc.slopValues),
            criticalDropCount: acc.criticalCount,
            criticalDropsSample: acc.criticalDrops
        )
        return ParsedLogResult(
            fpsMetrics: metrics,
            burstLossCount: acc.burstLossCount,
            highPingOver200MsCount: acc.highPingCount,
            ack256Count: acc.ack256Count
        )
    }

    private static func consumeLine(
        _ line: String,
        index: Int,
        allLines: [String],
        homeDirectory: String,
        into acc: inout LogAccumulator
    ) {
        let lower = line.lowercased()
        if lower.contains("burst loss") || lower.contains("burstloss") { acc.burstLossCount += 1 }
        if lower.contains("256") && (lower.contains("ack") || lower.contains("packet")) {
            acc.ack256Count += 1
        }
        if let ping = firstCaptureDouble(in: line, pattern: #"(?i)\bping[:=\s]+(\d+(?:\.\d+)?)\s*(?:ms)?"#),
           ping > 200.0 {
            acc.highPingCount += 1
        }
        if let fps = parseFPS(from: line) {
            acc.fpsValues.append(fps)
            recordCriticalDropIfNeeded(fps: fps, index: index, lines: allLines, home: homeDirectory, into: &acc)
        }
        if let work = firstCaptureDouble(in: line, pattern: #"(?i)\bwork[:=\s]+(\d+(?:\.\d+)?)\s*ms"#) {
            acc.workValues.append(work)
        }
        if let slack = firstCaptureDouble(in: line, pattern: #"(?i)\bslack[:=\s]+(\d+(?:\.\d+)?)\s*ms"#) {
            acc.slackValues.append(slack)
        }
        if let slop = firstCaptureDouble(in: line, pattern: #"(?i)\bslop[:=\s]+(\d+(?:\.\d+)?)\s*ms"#) {
            acc.slopValues.append(slop)
        }
    }

    private static func recordCriticalDropIfNeeded(
        fps: Double,
        index: Int,
        lines: [String],
        home: String,
        into acc: inout LogAccumulator
    ) {
        guard fps < 5.0 else { return }
        acc.criticalCount += 1
        guard acc.criticalDrops.count < 25 else { return }
        let startLine = max(0, index - 2)
        let endLine = min(lines.count - 1, index + 2)
        let context = (startLine...endLine).map {
            GameTelemetryPrivacyRedactor.redact(lines[$0], homeDirectory: home)
        }
        acc.criticalDrops.append(
            TelemetryCriticalDrop(lineIndex: index, fps: fps, contextLines: context)
        )
    }

    private static func parseFPS(from line: String) -> Double? {
        if let fps = firstCaptureDouble(in: line, pattern: #"(?i)\bfps[:=\s]+(\d+(?:\.\d+)?)"#),
           fps >= 0, fps <= 1000 { return fps }
        let avgPat = #"(?i)avg\.?\s*frametime\s*(?:\(ms\))?[:=\s]+(\d+(?:\.\d+)?)"#
        if let avgMs = firstCaptureDouble(in: line, pattern: avgPat), avgMs > 0.5, avgMs < 10_000 {
            return 1000.0 / avgMs
        }
        let ftPat = #"(?i)\bframetime[:=\s]+(\d+(?:\.\d+)?)\s*ms"#
        if let frameMs = firstCaptureDouble(in: line, pattern: ftPat), frameMs > 0.5, frameMs < 10_000 {
            return 1000.0 / frameMs
        }
        return nil
    }

    static func firstCaptureDouble(in line: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[valueRange])
    }
}
