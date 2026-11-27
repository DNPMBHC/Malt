// SPDX-License-Identifier: GPL-3.0-or-later
// Static snapshot, shader cache, and read-only guest script helpers for GameTelemetryCollector.

import Foundation

enum GameTelemetryCollectorHelpers {
    static func displaySnapshot(from context: GameTelemetrySessionContext) -> TelemetryDisplayInputSnapshot {
        let policyText: String
        switch context.settings.displayPolicy {
        case .automatic: policyText = "automatic"
        case .fixed(let width, let height): policyText = "\(width)x\(height)"
        }
        let env = context.settings.containerEnvironment
        return TelemetryDisplayInputSnapshot(
            displayPolicy: policyText,
            fpsLimit: 120,
            appShellFullscreenEnabled: context.engineKind == .antiCheatVM,
            keepCursorVisibleOnInhibit: env["UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT"] == "1",
            pureRelativeMouse: env["UTM_PURE_RELATIVE_MOUSE"] == "1",
            mouseCoalesceMicros: context.settings.enableMouseCoalescing ? 1500 : 0,
            blockAccidentalShortcuts: context.settings.blockAccidentalShortcuts,
            blockLeftCommandKey: context.settings.enableKeyMapping,
            persistentCacheEnabled: context.settings.enablePersistentCache,
            graphicsBackend: context.settings.graphicsBackend.rawValue,
            metalFXUpscaleFactor: context.settings.graphicsBackend.metalFXUpscaleFactor,
            displayPresentMode: context.settings.displayPresentMode.rawValue,
            hvfTSOEnabled: context.settings.enableHVFTSO,
            neptuneProfilerEnabled: context.settings.enableNeptuneProfiler
                || context.settings.enablePerformanceTelemetryLogging
        )
    }

    static func hardwareFingerprint(from context: GameTelemetrySessionContext) -> TelemetryHardwareFingerprint {
        TelemetryHardwareFingerprint(
            chipName: context.hardware.chipName,
            totalCores: context.hardware.totalCores,
            performanceCores: context.hardware.performanceCores,
            efficiencyCores: context.hardware.efficiencyCores,
            physicalMemoryGiB: context.hardware.physicalMemoryGiB,
            displayRefreshRateHz: context.hardware.displayRefreshRateHz,
            allocatedVCPU: context.settings.virtualCPUCount,
            allocatedRAMMiB: context.settings.memoryMiB,
            presetTier: context.settings.presetTier.rawValue,
            appVersion: context.appVersion
        )
    }

    static func measureShaderCache(fileManager: FileManager = .default) -> (files: Int, bytes: Int64) {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: "Library/Containers/com.utmapp.UTM/Data/Library/Caches/dxmt-shader-cache"),
            home.appending(path: "Library/Caches/dxmt-shader-cache"),
            home.appending(path: "Library/Caches/DXMT"),
            home.appending(path: "Library/Application Support/com.isaacmarovitz.Whisky/ShaderCache")
        ]
        var totalFiles = 0
        var totalBytes: Int64 = 0
        for root in candidates where fileManager.fileExists(atPath: root.path(percentEncoded: false)) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true {
                    totalFiles += 1
                    totalBytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return (totalFiles, totalBytes)
    }

    static func makeFilename(gameName: String, startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let asciiAllowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        let rawSlug = String(gameName.unicodeScalars.map { asciiAllowed.contains($0) ? Character($0) : "_" })
        let collapsed = rawSlug.split(separator: "_").joined(separator: "_")
        let slug = collapsed.isEmpty ? "session" : String(collapsed.prefix(32))
        return "telemetry-\(formatter.string(from: startedAt))-\(slug).json"
    }

    static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func guestReadOnlySnapshotScript(sinceISO: String) -> String {
        let filterPattern = "(?i)(avg\\.?\\s*frametime|fps|work:|slack:|slop:|"
            + "burst\\\\s*loss|ping[:=\\\\s]+|256.*(ack|packet))"
        return """
        $ErrorActionPreference='SilentlyContinue';
        $since=[DateTime]::Parse('\(sinceISO)').ToLocalTime();
        $cFree=$null; $fFree=$null;
        try { $d=Get-PSDrive -Name C; if ($d) { $cFree=[Math]::Round($d.Free/1GB,2) } } catch {};
        try { $d=Get-PSDrive -Name F; if ($d) { $fFree=[Math]::Round($d.Free/1GB,2) } } catch {};
        $ev26=0; $crash=0;
        try { $ev26=@(Get-WinEvent -FilterHashtable @{LogName='System';Id=26;StartTime=$since}).Count } catch {};
        try {
          $crash=@(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=$since}).Count
        } catch {};
        $logText='';
        $paths=@(
          "F:\\VALORANT_CN\\Tencent Games\\VALORANT\\live\\ShooterGame\\Saved\\Logs\\ShooterGame.log",
          "$env:LOCALAPPDATA\\VALORANT\\Saved\\Logs\\ShooterGame.log",
          "C:\\Users\\*\\AppData\\Local\\VALORANT\\Saved\\Logs\\ShooterGame.log"
        );
        $logFile=$paths | ForEach-Object { Get-Item -Path $_ } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1;
        if ($logFile) {
          $lines=Get-Content -LiteralPath $logFile.FullName -Tail 4000 | Where-Object {
            $_ -match '\(filterPattern)'
          } | Select-Object -Last 600;
          $logText=($lines -join "`n");
        };
        @{
          driveCFreeGiB=$cFree; driveFFreeGiB=$fFree;
          event26Count=$ev26; backgroundCrashCount=$crash; shooterLogExcerpt=$logText
        } | ConvertTo-Json -Compress
        """
    }
}

/// Host Metal presentation and Neptune microsecond profiler summary parsed from `neptune-latest.log`.
public struct TelemetryNeptunePresentSummary: Codable, Equatable, Sendable {
    public let presentMode: String
    public let scanoutFps: TelemetryDistribution
    public let presentFps: TelemetryDistribution
    public let ackMicros: TelemetryDistribution
    public let directBlitPercentMean: Double
    public let neptuneHotspotTail: [String]
}

extension GameTelemetryLogParser {
    private struct NeptuneAccumulator {
        var mode = "unknown"
        var scanoutFps: [Double] = []
        var ackMicros: [Double] = []
        var presentFps: [Double] = []
        var directBlitPct: [Double] = []
        var hotspots: [String] = []
    }

    public static func parseNeptuneProfileLog(
        _ content: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> TelemetryNeptunePresentSummary? {
        var acc = NeptuneAccumulator()
        for rawLine in content.split(whereSeparator: \.isNewline) {
            consumeNeptuneLine(String(rawLine), homeDirectory: homeDirectory, into: &acc)
        }
        guard !acc.scanoutFps.isEmpty || !acc.presentFps.isEmpty || !acc.hotspots.isEmpty else { return nil }
        let blitMean = acc.directBlitPct.isEmpty
            ? 0.0
            : ((acc.directBlitPct.reduce(0, +) / Double(acc.directBlitPct.count)) * 100).rounded() / 100
        return TelemetryNeptunePresentSummary(
            presentMode: acc.mode,
            scanoutFps: GameTelemetryMath.distribution(of: acc.scanoutFps),
            presentFps: GameTelemetryMath.distribution(of: acc.presentFps),
            ackMicros: GameTelemetryMath.distribution(of: acc.ackMicros),
            directBlitPercentMean: blitMean,
            neptuneHotspotTail: Array(acc.hotspots.suffix(40))
        )
    }

    private static func consumeNeptuneLine(
        _ line: String,
        homeDirectory: String,
        into acc: inout NeptuneAccumulator
    ) {
        if line.contains("[Malt-Present]") {
            parsePresentMetricsLine(line, into: &acc)
            return
        }
        if line.contains("[Malt-Renderer]") {
            if let val = firstCaptureDouble(in: line, pattern: #"present_fps=(\d+(?:\.\d+)?)"#) {
                acc.presentFps.append(val)
            }
            if let val = firstCaptureDouble(in: line, pattern: #"direct_blit_pct=(\d+(?:\.\d+)?)"#) {
                acc.directBlitPct.append(val)
            }
            return
        }
        if isNeptuneHotspotLine(line) {
            acc.hotspots.append(GameTelemetryPrivacyRedactor.redact(line, homeDirectory: homeDirectory))
        }
    }

    private static func parsePresentMetricsLine(_ line: String, into acc: inout NeptuneAccumulator) {
        if let range = line.range(of: "mode="),
           let token = line[range.upperBound...].split(whereSeparator: \.isWhitespace).first,
           !token.isEmpty {
            acc.mode = String(token)
        }
        if let val = firstCaptureDouble(in: line, pattern: #"scanout_fps=(\d+(?:\.\d+)?)"#) {
            acc.scanoutFps.append(val)
        }
        if let val = firstCaptureDouble(in: line, pattern: #"ack_us_avg=(\d+(?:\.\d+)?)"#) {
            acc.ackMicros.append(val)
        }
    }

    private static func isNeptuneHotspotLine(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("npt")
            || line.localizedCaseInsensitiveContains("neptune")
            || line.localizedCaseInsensitiveContains("profile")
    }
}
