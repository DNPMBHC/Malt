// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for Malt 6-dimension read-only performance & FPS telemetry logging.

import Foundation
import XCTest
@testable import WhiskyKit

final class GameTelemetryCollectorTests: XCTestCase {
    func testTelemetrySettingDefaultsFalseAndPersists() throws {
        let suiteName = "malt.telemetry.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = UnifiedLaunchSettings.load(defaults: defaults)
        XCTAssertFalse(initial.enablePerformanceTelemetryLogging)

        defaults.set(true, forKey: "unifiedEnablePerformanceTelemetryLogging")
        let enabled = UnifiedLaunchSettings.load(defaults: defaults)
        XCTAssertTrue(enabled.enablePerformanceTelemetryLogging)

        let entry = UnifiedGameEntry(
            name: "VALORANT",
            executablePath: #"F:\VALORANT\live\VALORANT.exe"#,
            engineKind: .antiCheatVM,
            presetTier: .maxPerformance,
            inheritsGlobalPerformanceSettings: false
        )
        let hardware = HardwareProfileSnapshot(
            chipName: "Apple M3", totalCores: 8, performanceCores: 4,
            efficiencyCores: 4, physicalMemoryGiB: 16, displayRefreshRateHz: 120,
            recommendedStoragePath: "/Volumes/Test"
        )
        let resolved = enabled.resolved(for: entry, hardware: hardware)
        XCTAssertTrue(resolved.enablePerformanceTelemetryLogging)
    }

    func testDistributionComputesPercentiles() {
        let values = (1...100).map(Double.init)
        let dist = GameTelemetryMath.distribution(of: values)
        XCTAssertEqual(dist.count, 100)
        XCTAssertEqual(dist.mean, 50.5, accuracy: 0.01)
        XCTAssertEqual(dist.p50, 50.0, accuracy: 0.01)
        XCTAssertEqual(dist.p5Low, 5.0, accuracy: 0.01)
        XCTAssertEqual(dist.p1Low, 1.0, accuracy: 0.01)
        XCTAssertEqual(dist.p01Low, 1.0, accuracy: 0.01)
        XCTAssertEqual(dist.p95, 95.0, accuracy: 0.01)
        XCTAssertEqual(dist.minValue, 1.0, accuracy: 0.01)
        XCTAssertEqual(dist.maxValue, 100.0, accuracy: 0.01)
    }

    func testPrivacyRedactorStripsUserAndExternalVolumes() {
        let raw = "Loaded /Users/alice/Games/test.exe from "
            + "/Volumes/PrivateSSD/vms/win11.utm and /Volumes/Macintosh HD/ok"
        let redacted = GameTelemetryPrivacyRedactor.redact(raw, homeDirectory: "/Users/alice")
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("PrivateSSD"))
        XCTAssertTrue(redacted.contains("~/Games/test.exe"))
        XCTAssertTrue(redacted.contains("<EXTERNAL_VOLUME>/vms/win11.utm"))
        XCTAssertTrue(redacted.contains("/Volumes/Macintosh HD/ok"))
    }

    func testHostPSAndVMStatParsers() {
        let psOutput = [
            "  101 245.5 8388608 /Applications/Malt.app/Contents/MacOS/qemu-aarch64-softmmu",
            "  102  42.0  524288 /Applications/Malt.app/Contents/MacOS/qemu-render-server",
            "  103  12.5  262144 /Applications/Malt.app/Contents/MacOS/MaltContainerHelper",
            "  104   3.2   16384 /Applications/Malt.app/Contents/Resources/malt-net-proxy"
        ].joined(separator: "\n")
        let sample = GameTelemetryHostParser.parsePSOutput(psOutput)
        XCTAssertEqual(sample.qemuWorkerCPU, 245.5, accuracy: 0.01)
        XCTAssertEqual(sample.qemuWorkerRSSMiB, 8192.0, accuracy: 0.1)
        XCTAssertEqual(sample.qemuRenderCPU, 42.0, accuracy: 0.01)
        XCTAssertEqual(sample.qemuRenderRSSMiB, 512.0, accuracy: 0.1)
        XCTAssertEqual(sample.maltHelperCPU, 12.5, accuracy: 0.01)
        XCTAssertEqual(sample.maltHelperRSSMiB, 256.0, accuracy: 0.1)
        XCTAssertEqual(sample.maltNetProxyCPU, 3.2, accuracy: 0.01)
        XCTAssertEqual(sample.maltNetProxyRSSMiB, 16.0, accuracy: 0.1)

        let vmStat = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages occupied by compressor:            123456.
        Pageouts:                                 7890.
        """
        let parsedVM = GameTelemetryHostParser.parseVMStat(vmStat)
        XCTAssertEqual(parsedVM.compressedPages, 123_456)
        XCTAssertEqual(parsedVM.pageouts, 7890)
    }

    func testShooterGameLogParserExtractsFPSHitchesAndNetwork() {
        let logText = """
        [2026.11.26-12.00.01] Stat: FPS: 62.5 Work: 8.2ms Slack: 6.1ms Slop: 0.4ms
        [2026.11.26-12.00.02] Net: Ping: 28ms
        [2026.11.26-12.00.03] Warning: Shader compile hitch near /Users/bob/cache
        [2026.11.26-12.00.04] Stat: FPS: 3.1 Work: 290.0ms Slack: 12.0ms Slop: 1.5ms
        [2026.11.26-12.00.05] Net: Burst Loss detected, Ping: 245ms, 256-packet ack backlog
        [2026.11.26-12.00.06] Stat: FPS: 60.0 Work: 9.0ms Slack: 7.0ms Slop: 0.2ms
        """
        let parsed = GameTelemetryLogParser.parseShooterGameLog(logText, homeDirectory: "/Users/bob")
        XCTAssertEqual(parsed.fpsMetrics.source, "ShooterGame.log")
        XCTAssertEqual(parsed.fpsMetrics.fps.count, 3)
        XCTAssertEqual(parsed.fpsMetrics.criticalDropCount, 1)
        XCTAssertEqual(parsed.fpsMetrics.criticalDropsSample.count, 1)
        XCTAssertEqual(parsed.fpsMetrics.workMs.count, 3)
        XCTAssertEqual(parsed.fpsMetrics.slackMs.count, 3)
        XCTAssertEqual(parsed.fpsMetrics.slopMs.count, 3)
        XCTAssertEqual(parsed.burstLossCount, 1)
        XCTAssertEqual(parsed.highPingOver200MsCount, 1)
        XCTAssertEqual(parsed.ack256Count, 1)
        let joinedContext = parsed.fpsMetrics.criticalDropsSample[0].contextLines.joined(separator: "\n")
        XCTAssertFalse(joinedContext.contains("bob"))
        XCTAssertTrue(joinedContext.contains("~/cache"))
    }

    func testCollectorWritesRedactedSixDimensionReport() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "malt-telemetry-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let collector = makeMockCollector(logsDir: tempDir)
        let context = makeMockSessionContext()
        let url = await collector.startSession(context: context)
        try await Task.sleep(for: .milliseconds(350))
        _ = await collector.stopSession(reason: "test_complete")

        let data = try Data(contentsOf: url)
        let rawText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(rawText.contains("PrivateDisk"))

        let report = try JSONDecoder().decode(GameTelemetryReport.self, from: data)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.status, "test_complete")
        XCTAssertEqual(report.executablePathRedacted, "<EXTERNAL_VOLUME>/Games/VALORANT.exe")
        XCTAssertEqual(report.fpsMetrics.fps.mean, 61.5, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(report.hostMetrics.sampleCount, 1)
        XCTAssertEqual(report.hostMetrics.qemuWorker.cpuPercent.mean, 180.0, accuracy: 0.01)
        XCTAssertEqual(report.networkMetrics.activeMode, "malt_net_proxy")
        XCTAssertEqual(report.cacheAndGuestMetrics.guestDriveCFreeGiB, 42.5)
        XCTAssertEqual(report.displayInputSnapshot.displayPolicy, "1920x1200")
        XCTAssertTrue(report.displayInputSnapshot.keepCursorVisibleOnInhibit)
        XCTAssertEqual(report.hardwareFingerprint.allocatedVCPU, 8)
        XCTAssertEqual(report.hardwareFingerprint.allocatedRAMMiB, 10240)
    }

    private func makeMockCollector(logsDir: URL) -> GameTelemetryCollector {
        GameTelemetryCollector(
            logsDirectoryURL: logsDir,
            sampleIntervalSeconds: 0.2,
            commandRunner: { executable, _, _ in
                if executable == "/bin/ps" {
                    return OrchestratorCommandResult(
                        exitCode: 0,
                        stdout: "201 180.0 4194304 qemu-aarch64-softmmu\n202 25.0 262144 qemu-render-server\n",
                        stderr: ""
                    )
                }
                if executable == "/usr/bin/vm_stat" {
                    return OrchestratorCommandResult(
                        exitCode: 0,
                        stdout: "Pages occupied by compressor: 1000.\nPageouts: 50.\n",
                        stderr: ""
                    )
                }
                return OrchestratorCommandResult(
                    exitCode: 0,
                    stdout: """
                    {"driveCFreeGiB":42.5,"driveFFreeGiB":18.2,"event26Count":0,"backgroundCrashCount":0,\
                    "shooterLogExcerpt":"Stat: FPS: 61.5 Work: 8.0ms Slack: 7.0ms Slop: 0.3ms"}
                    """,
                    stderr: ""
                )
            }
        )
    }

    private func makeMockSessionContext() -> GameTelemetrySessionContext {
        let hardware = HardwareProfileSnapshot(
            chipName: "Apple M3", totalCores: 8, performanceCores: 4,
            efficiencyCores: 4, physicalMemoryGiB: 16, displayRefreshRateHz: 120,
            recommendedStoragePath: "/Volumes/PrivateDisk"
        )
        let settings = UnifiedLaunchSettings(
            presetTier: .balanced,
            enablePerformanceTelemetryLogging: true,
            displayPolicy: .fixed(width: 1920, height: 1200),
            virtualCPUCount: 8,
            memoryMiB: 10240
        )
        return GameTelemetrySessionContext(
            gameName: "VALORANT",
            engineKind: .antiCheatVM,
            executablePath: "/Volumes/PrivateDisk/Games/VALORANT.exe",
            settings: settings,
            hardware: hardware,
            networkMode: "malt_net_proxy",
            appVersion: "1.0.0",
            controlBinaryPath: "/mock/utmctl",
            vmIdentifier: UUID().uuidString
        )
    }
}
