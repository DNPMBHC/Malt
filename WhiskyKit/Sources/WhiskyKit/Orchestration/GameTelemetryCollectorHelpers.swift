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
            persistentCacheEnabled: context.settings.enablePersistentCache
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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(
            gameName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let slug = sanitized.isEmpty ? "session" : String(sanitized.prefix(32))
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
        let filterPattern = "(?i)(fps|frametime|work:|slack:|slop:|burst\\\\s*loss|ping[:=\\\\s]+|256.*(ack|packet))"
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
          "$env:LOCALAPPDATA\\VALORANT\\Saved\\Logs\\ShooterGame.log",
          "C:\\Users\\*\\AppData\\Local\\VALORANT\\Saved\\Logs\\ShooterGame.log"
        );
        $logFile=$paths | ForEach-Object { Get-Item -Path $_ } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1;
        if ($logFile) {
          $lines=Get-Content -LiteralPath $logFile.FullName -Tail 2500 | Where-Object {
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
