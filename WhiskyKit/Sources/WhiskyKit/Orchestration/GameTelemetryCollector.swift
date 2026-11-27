// SPDX-License-Identifier: GPL-3.0-or-later
// Low-overhead, strictly read-only performance and FPS telemetry collector for Malt.

import Foundation

/// Immutable metadata captured when a telemetry session begins.
public struct GameTelemetrySessionContext: Sendable {
    public let gameName: String
    public let engineKind: UnifiedEngineKind
    public let executablePath: String
    public let settings: UnifiedLaunchSettings
    public let hardware: HardwareProfileSnapshot
    public let networkMode: String
    public let appVersion: String
    public let controlBinaryPath: String?
    public let vmIdentifier: String?
    public let helperBinaryPath: String?

    public init(
        gameName: String,
        engineKind: UnifiedEngineKind,
        executablePath: String,
        settings: UnifiedLaunchSettings,
        hardware: HardwareProfileSnapshot,
        networkMode: String,
        appVersion: String,
        controlBinaryPath: String? = nil,
        vmIdentifier: String? = nil,
        helperBinaryPath: String? = nil
    ) {
        self.gameName = gameName
        self.engineKind = engineKind
        self.executablePath = executablePath
        self.settings = settings
        self.hardware = hardware
        self.networkMode = networkMode
        self.appVersion = appVersion
        self.controlBinaryPath = controlBinaryPath
        self.vmIdentifier = vmIdentifier
        self.helperBinaryPath = helperBinaryPath
    }
}

private struct GuestTelemetrySnapshot: Decodable, Sendable {
    let driveCFreeGiB: Double?
    let driveFFreeGiB: Double?
    let event26Count: Int?
    let backgroundCrashCount: Int?
    let shooterLogExcerpt: String?
}

/// Strictly read-only background telemetry collector with periodic flush and privacy redaction.
public actor GameTelemetryCollector {
    public typealias CommandRunner = UnifiedRuntimeOrchestrator.CommandRunner
    public typealias HelperRunningProbe = @Sendable (String) async -> Bool

    fileprivate struct ActiveSession {
        let id: UUID
        let context: GameTelemetrySessionContext
        let startedAt: Date
        let outputURL: URL
        let vmStatStart: (compressedPages: Int64, pageouts: Int64)
        let cacheStart: (files: Int, bytes: Int64)
        var samples: [TelemetryHostSample] = []
        var thermalCounts: [String: Int] = [:]
        var consecutiveHelperDown: Int = 0
        var lastGuestSnapshot: GuestTelemetrySnapshot?
        var monitorTask: Task<Void, Never>?
    }

    private let logsDirectoryURL: URL
    private let sampleIntervalSeconds: Double
    private let commandRunner: CommandRunner
    private let helperRunningProbe: HelperRunningProbe?
    private var activeSession: ActiveSession?
    private var latestWrittenURL: URL?

    public init(
        logsDirectoryURL: URL? = nil,
        sampleIntervalSeconds: Double = 2.0,
        commandRunner: CommandRunner? = nil,
        helperRunningProbe: HelperRunningProbe? = nil
    ) {
        self.logsDirectoryURL = logsDirectoryURL ?? Self.telemetryLogsDirectoryURL()
        self.sampleIntervalSeconds = max(0.2, sampleIntervalSeconds)
        self.commandRunner = commandRunner ?? { executable, arguments, environment in
            try await OrchestratorProcessRunner.run(
                executable: executable, arguments: arguments, environment: environment
            )
        }
        self.helperRunningProbe = helperRunningProbe
    }

    public static func telemetryLogsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return appSupport
            .appending(path: "com.isaacmarovitz.Whisky", directoryHint: .isDirectory)
            .appending(path: "TelemetryLogs", directoryHint: .isDirectory)
    }

    public static func neptuneProfileLogURL(fileManager: FileManager = .default) -> URL {
        let sandboxCaches = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.utmapp.UTM/Data/Library/Caches", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: sandboxCaches.path(percentEncoded: false)) {
            return sandboxCaches.appending(path: "neptune-latest.log")
        }
        return telemetryLogsDirectoryURL(fileManager: fileManager).appending(path: "neptune-latest.log")
    }

    public static func latestTelemetryLogURL(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let folder = directory ?? telemetryLogsDirectoryURL(fileManager: fileManager)
        guard let items = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return items
            .filter { $0.pathExtension.lowercased() == "json" }
            .max { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return leftDate < rightDate
            }
    }

    public func currentLogURL() -> URL? {
        activeSession?.outputURL ?? latestWrittenURL
    }

    @discardableResult
    public func startSession(context: GameTelemetrySessionContext) async -> URL {
        if activeSession != nil {
            await stopSession(reason: "superseded_by_new_launch")
        }
        try? FileManager.default.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessionID = UUID()
        let startedAt = Date()
        let outputURL = logsDirectoryURL.appending(
            path: GameTelemetryCollectorHelpers.makeFilename(gameName: context.gameName, startedAt: startedAt)
        )
        let vmStatStart = await readVMStat()
        let cacheStart = GameTelemetryCollectorHelpers.measureShaderCache()

        var session = ActiveSession(
            id: sessionID,
            context: context,
            startedAt: startedAt,
            outputURL: outputURL,
            vmStatStart: vmStatStart,
            cacheStart: cacheStart
        )
        let initialReport = buildReport(for: session, endedAt: startedAt, status: "recording", vmStatEnd: vmStatStart)
        writeReport(initialReport, to: outputURL)
        latestWrittenURL = outputURL

        let interval = sampleIntervalSeconds
        session.monitorTask = Task { [weak self] in
            await self?.runSamplingLoop(sessionID: sessionID, intervalSeconds: interval)
        }
        activeSession = session
        return outputURL
    }

    @discardableResult
    public func stopSession(reason: String = "completed") async -> URL? {
        guard var session = activeSession else { return latestWrittenURL }
        session.monitorTask?.cancel()
        session.monitorTask = nil
        activeSession = nil

        if session.context.engineKind == .antiCheatVM,
           let guestSnapshot = await collectGuestSnapshot(for: session.context, since: session.startedAt) {
            session.lastGuestSnapshot = guestSnapshot
        }
        let vmStatEnd = await readVMStat()
        let report = buildReport(for: session, endedAt: Date(), status: reason, vmStatEnd: vmStatEnd)
        writeReport(report, to: session.outputURL)
        latestWrittenURL = session.outputURL
        return session.outputURL
    }

    private func runSamplingLoop(sessionID: UUID, intervalSeconds: Double) async {
        let maxIterations = max(1, Int((4.0 * 3600.0) / intervalSeconds))
        for iteration in 1...maxIterations {
            try? await Task.sleep(for: .seconds(intervalSeconds))
            if Task.isCancelled { return }
            guard activeSession?.id == sessionID else { return }

            await recordOneHostSample(sessionID: sessionID)
            if iteration % 15 == 0 {
                await flushHeartbeat(sessionID: sessionID)
            }
            if await shouldAutoStopForHelperExit(sessionID: sessionID) {
                await stopSession(reason: "helper_exited")
                return
            }
        }
        if activeSession?.id == sessionID {
            await stopSession(reason: "max_duration_reached")
        }
    }

    private func recordOneHostSample(sessionID: UUID) async {
        let psResult = try? await commandRunner(
            "/bin/ps", ["-axo", "pid=,pcpu=,rss=,args="], ["__DEMOAPP_TIMEOUT_SECONDS": "3"]
        )
        let sample = GameTelemetryHostParser.parsePSOutput(psResult?.stdout ?? "")
        let thermal = GameTelemetryCollectorHelpers.thermalStateLabel(ProcessInfo.processInfo.thermalState)
        guard var session = activeSession, session.id == sessionID else { return }
        session.samples.append(sample)
        session.thermalCounts[thermal, default: 0] += 1
        activeSession = session
    }

    private func flushHeartbeat(sessionID: UUID) async {
        guard let latest = activeSession, latest.id == sessionID else { return }
        let vmStatNow = await readVMStat()
        let report = buildReport(for: latest, endedAt: Date(), status: "recording", vmStatEnd: vmStatNow)
        writeReport(report, to: latest.outputURL)
    }

    private func shouldAutoStopForHelperExit(sessionID: UUID) async -> Bool {
        guard let session = activeSession, session.id == sessionID,
              session.context.engineKind == .antiCheatVM,
              let helperPath = session.context.helperBinaryPath,
              let probe = helperRunningProbe else { return false }
        let isRunning = await probe(helperPath)
        guard var current = activeSession, current.id == sessionID else { return false }
        current.consecutiveHelperDown = isRunning ? 0 : (current.consecutiveHelperDown + 1)
        activeSession = current
        return current.consecutiveHelperDown >= 3
    }

    private func readVMStat() async -> (compressedPages: Int64, pageouts: Int64) {
        let result = try? await commandRunner("/usr/bin/vm_stat", [], ["__DEMOAPP_TIMEOUT_SECONDS": "3"])
        return GameTelemetryHostParser.parseVMStat(result?.stdout ?? "")
    }
}

private extension GameTelemetryCollector {
    func collectGuestSnapshot(
        for context: GameTelemetrySessionContext,
        since startedAt: Date
    ) async -> GuestTelemetrySnapshot? {
        guard let control = context.controlBinaryPath,
              let vmID = context.vmIdentifier else { return nil }
        let sinceISO = ISO8601DateFormatter().string(from: startedAt)
        let script = GameTelemetryCollectorHelpers.guestReadOnlySnapshotScript(sinceISO: sinceISO)
        let encoded = ContainerGuestDispatcher.encodedPowerShell(script)
        let result = try? await commandRunner(
            control,
            ["exec", vmID, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand", encoded],
            ["__DEMOAPP_TIMEOUT_SECONDS": "12"]
        )
        guard let stdout = result?.stdout, result?.exitCode == 0,
              let startIdx = stdout.firstIndex(of: "{"),
              let endIdx = stdout.lastIndex(of: "}"),
              startIdx <= endIdx,
              let data = String(stdout[startIdx...endIdx]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GuestTelemetrySnapshot.self, from: data)
    }

    func buildReport(
        for session: ActiveSession,
        endedAt: Date,
        status: String,
        vmStatEnd: (compressedPages: Int64, pageouts: Int64)
    ) -> GameTelemetryReport {
        let formatter = ISO8601DateFormatter()
        let parsedLog = GameTelemetryLogParser.parseShooterGameLog(
            session.lastGuestSnapshot?.shooterLogExcerpt ?? ""
        )
        let cacheEnd = GameTelemetryCollectorHelpers.measureShaderCache()
        let hostMetrics = TelemetryHostMetrics(
            sampleIntervalSeconds: sampleIntervalSeconds,
            sampleCount: session.samples.count,
            qemuWorker: processStats(session.samples, cpu: \.qemuWorkerCPU, rss: \.qemuWorkerRSSMiB),
            qemuRenderServer: processStats(session.samples, cpu: \.qemuRenderCPU, rss: \.qemuRenderRSSMiB),
            maltHelper: processStats(session.samples, cpu: \.maltHelperCPU, rss: \.maltHelperRSSMiB),
            maltNetProxy: processStats(session.samples, cpu: \.maltNetProxyCPU, rss: \.maltNetProxyRSSMiB),
            thermalStateCounts: session.thermalCounts,
            vmStatCompressedPagesDelta: vmStatEnd.compressedPages - session.vmStatStart.compressedPages,
            vmStatPageoutsDelta: vmStatEnd.pageouts - session.vmStatStart.pageouts
        )
        let networkMetrics = TelemetryNetworkMetrics(
            activeMode: session.context.networkMode,
            burstLossCount: parsedLog.burstLossCount,
            highPingOver200MsCount: parsedLog.highPingOver200MsCount,
            ack256Count: parsedLog.ack256Count
        )
        let cacheGuest = TelemetryCacheAndGuestMetrics(
            dxmtCacheFilesStart: session.cacheStart.files,
            dxmtCacheFilesEnd: cacheEnd.files,
            dxmtCacheBytesStart: session.cacheStart.bytes,
            dxmtCacheBytesEnd: cacheEnd.bytes,
            guestDriveCFreeGiB: session.lastGuestSnapshot?.driveCFreeGiB,
            guestDriveFFreeGiB: session.lastGuestSnapshot?.driveFFreeGiB,
            guestSystemEvent26Count: session.lastGuestSnapshot?.event26Count,
            guestBackgroundCrashCount: session.lastGuestSnapshot?.backgroundCrashCount
        )
        return GameTelemetryReport(
            schemaVersion: 1,
            sessionID: session.id.uuidString,
            gameName: session.context.gameName,
            engineKind: session.context.engineKind.rawValue,
            executablePathRedacted: GameTelemetryPrivacyRedactor.redact(session.context.executablePath),
            startedAtUTC: formatter.string(from: session.startedAt),
            endedAtUTC: formatter.string(from: endedAt),
            durationSeconds: max(0, (endedAt.timeIntervalSince(session.startedAt) * 100).rounded() / 100),
            status: status,
            fpsMetrics: parsedLog.fpsMetrics,
            hostMetrics: hostMetrics,
            networkMetrics: networkMetrics,
            cacheAndGuestMetrics: cacheGuest,
            displayInputSnapshot: GameTelemetryCollectorHelpers.displaySnapshot(from: session.context),
            hardwareFingerprint: GameTelemetryCollectorHelpers.hardwareFingerprint(from: session.context),
            neptunePresentSummary: readNeptunePresentSummary()
        )
    }

    func readNeptunePresentSummary() -> TelemetryNeptunePresentSummary? {
        let candidates = [
            logsDirectoryURL.appending(path: "neptune-latest.log"),
            Self.neptuneProfileLogURL()
        ]
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let maxReadBytes: UInt64 = 65_536
        if fileSize > maxReadBytes {
            try? handle.seek(toOffset: fileSize - maxReadBytes)
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return GameTelemetryLogParser.parseNeptuneProfileLog(text)
    }

    func processStats(
        _ samples: [TelemetryHostSample],
        cpu: KeyPath<TelemetryHostSample, Double>,
        rss: KeyPath<TelemetryHostSample, Double>
    ) -> TelemetryProcessStats {
        TelemetryProcessStats(
            cpuPercent: GameTelemetryMath.distribution(of: samples.map { $0[keyPath: cpu] }),
            rssMiB: GameTelemetryMath.distribution(of: samples.map { $0[keyPath: rss] })
        )
    }

    func writeReport(_ report: GameTelemetryReport, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path(percentEncoded: false))
    }
}
