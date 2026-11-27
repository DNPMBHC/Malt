// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end automated Windows 11 ARM64 container deployment, v3.2 debloat injection, and offline qcow2 compaction.

import Combine
import Foundation

/// Orchestrates zero-redistribution Windows 11 ARM64 installation, v3.2 guest debloat/optimization,
/// and offline sparse qcow2 compaction for new and existing managed containers.
public final class ContainerAutoDeployService: ObservableObject, @unchecked Sendable {
    @Published public private(set) var steps: [AutoDeployStepReport]
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var downloadProgress: WindowsImageDownloadProgress?
    @Published public private(set) var lastReport: AutoDeployReport?

    private let configuration: UnifiedOrchestratorConfiguration
    private let fileManager: FileManager
    private let commandRunner: UnifiedRuntimeOrchestrator.CommandRunner
    private let hardwareProfileProvider: @Sendable () -> HardwareProfileSnapshot
    private let bootstrapService: WindowsImageBootstrapService
    private let diskCompactor: ContainerDiskCompactor
    private let provisioningService: ContainerProvisioningService

    public init(
        configuration: UnifiedOrchestratorConfiguration = UnifiedOrchestratorConfiguration(),
        fileManager: FileManager = .default,
        commandRunner: UnifiedRuntimeOrchestrator.CommandRunner? = nil,
        hardwareProfileProvider: (@Sendable () -> HardwareProfileSnapshot)? = nil,
        bootstrapService: WindowsImageBootstrapService? = nil,
        diskCompactor: ContainerDiskCompactor? = nil,
        provisioningService: ContainerProvisioningService? = nil
    ) {
        let runner: UnifiedRuntimeOrchestrator.CommandRunner = commandRunner ?? { exe, args, env in
            try await OrchestratorProcessRunner.run(executable: exe, arguments: args, environment: env)
        }
        let hwProvider = hardwareProfileProvider ?? { HardwareAutoTuner().detectHardwareProfile() }
        self.configuration = configuration
        self.fileManager = fileManager
        self.commandRunner = runner
        self.hardwareProfileProvider = hwProvider
        let resolved = UnifiedRuntimeDiscovery.resolve(configuration: configuration, fileManager: fileManager)
        let helperApp = resolved.containerHelperBinaryPath.map {
            URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .path(percentEncoded: false)
        }
        self.bootstrapService = bootstrapService ?? WindowsImageBootstrapService(commandRunner: runner)
        self.diskCompactor = diskCompactor ?? ContainerDiskCompactor(
            helperAppPath: helperApp, pythonExecutablePath: resolved.pythonExecutablePath, commandRunner: runner
        )
        self.provisioningService = provisioningService ?? ContainerProvisioningService(
            configuration: configuration, fileManager: fileManager,
            commandRunner: runner, hardwareProfileProvider: hwProvider
        )
        self.steps = Self.initialSteps()
    }

    /// Creates a compliant `.utm` container skeleton with sparse `qcow2` disk and mounted install media.
    public func createContainerSkeleton(
        at bundleURL: URL,
        diskSizeGiB: Int = 64,
        windowsISOURL: URL,
        bootstrapISOURL: URL,
        settings: UnifiedLaunchSettings = UnifiedLaunchSettings()
    ) async throws -> String {
        let standardized = bundleURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "utm" else {
            throw UnifiedOrchestrationError.backendUnavailable("目标容器目录必须以 .utm 结尾。")
        }
        guard !ContainerProvisioningPipeline.isProtectedBundle(standardized, fileManager: fileManager) else {
            throw UnifiedOrchestrationError.backendUnavailable("目标名称不可使用受保护母盘或冷备名称。")
        }
        guard !fileManager.fileExists(atPath: standardized.path(percentEncoded: false)) else {
            throw UnifiedOrchestrationError.backendUnavailable("目标位置已存在同名容器，请更换名称或目录。")
        }

        let dataDir = standardized.appending(path: "Data", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        do {
            let vmUUID = UUID().uuidString.uppercased()
            let diskUUID = UUID().uuidString.uppercased()
            let diskURL = dataDir.appending(path: "\(diskUUID).qcow2")
            try await diskCompactor.createSparseQCow2(at: diskURL, sizeGiB: diskSizeGiB)

            try await stageMediaFile(
                from: windowsISOURL,
                to: dataDir.appending(path: ContainerAutoDeployConfigBuilder.windowsInstallFilename)
            )
            try await stageMediaFile(
                from: bootstrapISOURL,
                to: dataDir.appending(path: ContainerAutoDeployConfigBuilder.bootstrapFilename)
            )

            let hardware = hardwareProfileProvider()
            let preset = UnifiedLaunchSettings.containerPreset(settings.presetTier, hardware: hardware)
            let spec = ContainerAutoDeployConfigBuilder.Spec(
                vmUUID: vmUUID,
                diskUUID: diskUUID,
                containerName: standardized.deletingPathExtension().lastPathComponent,
                cpuCount: settings.virtualCPUCount ?? preset.virtualCPUCount,
                memoryMiB: settings.memoryMiB ?? preset.memoryMiB
            )
            try ContainerAutoDeployConfigBuilder.writeSkeletonConfigAndMetadata(
                spec: spec, bundleURL: standardized, fileManager: fileManager
            )
            return vmUUID
        } catch {
            try? fileManager.removeItem(at: standardized)
            throw error
        }
    }

    /// Removes temporary Windows/bootstrap ISOs from `config.plist` and deletes their copies under `Data/`.
    public func ejectInstallMedia(in bundleURL: URL) throws {
        try ContainerAutoDeployConfigBuilder.ejectInstallMedia(in: bundleURL, fileManager: fileManager)
    }

    /// Runs offline sparse compaction on an existing stopped, managed container.
    public func compactExistingContainer(at bundlePath: String) async throws -> ContainerDiskCompactionReport {
        try await diskCompactor.compactContainerSystemDisk(bundlePath: bundlePath, fileManager: fileManager)
    }

    /// Executes the complete 6-stage automated Windows 11 ARM64 container creation, debloat, and compaction workflow.
    public func deployNewContainer(request: AutoDeployRequest) async throws -> AutoDeployReport {
        await MainActor.run {
            self.isRunning = true
            self.downloadProgress = nil
            self.steps = Self.initialSteps()
        }
        defer { Task { @MainActor in self.isRunning = false; self.downloadProgress = nil } }

        let resolved = UnifiedRuntimeDiscovery.resolve(configuration: configuration, fileManager: fileManager)
        let bundleURL = normalizedBundleURL(for: request)
        let bundlePath = bundleURL.path(percentEncoded: false)
        var currentSteps = Self.initialSteps()

        let isoURL = try await executeStage(
            .prepareWindowsImage, containerPath: bundlePath, steps: &currentSteps,
            runningDetail: "正在准备并校验官方 Windows 11 ARM64 镜像…"
        ) { try await self.prepareImage(request: request) }

        let bootstrapISO = try await executeStage(
            .buildBootstrapMedia, containerPath: bundlePath, steps: &currentSteps,
            runningDetail: "正在打包 autounattend.xml、驱动与优化脚本…"
        ) { try await self.buildBootstrapMedia(request: request, resolved: resolved) }
        defer { try? fileManager.removeItem(at: bootstrapISO) }

        let vmUUID = try await executeStage(
            .createContainerSkeleton, containerPath: bundlePath, steps: &currentSteps,
            runningDetail: "正在创建 UEFI/TPM 2.0 容器与 \(request.diskSizeGiB) GiB 稀疏系统盘…"
        ) {
            let uuid = try await self.createContainerSkeleton(
                at: bundleURL, diskSizeGiB: request.diskSizeGiB,
                windowsISOURL: isoURL, bootstrapISOURL: bootstrapISO, settings: request.launchSettings
            )
            return (uuid, "容器骨架与稀疏系统盘创建完成（UUID: \(uuid.prefix(8))…）。")
        }

        let compaction = try await runInstallOptimizeAndCompact(
            bundleURL: bundleURL, vmUUID: vmUUID, resolved: resolved, request: request, steps: &currentSteps
        )
        return await finalizeReport(
            containerPath: bundlePath, vmUUID: vmUUID, steps: currentSteps, compaction: compaction
        )
    }
}

private extension ContainerAutoDeployService {
    func runInstallOptimizeAndCompact(
        bundleURL: URL, vmUUID: String, resolved: ResolvedRuntimePaths,
        request: AutoDeployRequest, steps: inout [AutoDeployStepReport]
    ) async throws -> ContainerDiskCompactionReport {
        let bundlePath = bundleURL.path(percentEncoded: false)
        _ = try await executeStage(
            .runUnattendedInstall, containerPath: bundlePath, steps: &steps,
            runningDetail: "已启动无人值守安装，等待 Windows 首登、驱动与 QGA 就绪…"
        ) {
            try await self.runUnattendedInstall(
                bundlePath: bundlePath, vmUUID: vmUUID, resolved: resolved, request: request
            )
            return ((), "Windows 11 ARM64 安装完成，QGA 与首次驱动注入已就绪。")
        }

        _ = try await executeStage(
            .injectOptimizationAndTrim, containerPath: bundlePath, steps: &steps,
            runningDetail: "正在执行 v3.2 精简（移除 OneDrive/禁用休眠/CompactOS/WinSxS 清理/ReTrim/MPO 修复）…"
        ) {
            let report = try await self.provisioningService.provisionAndOptimize(
                containerPath: bundlePath, settings: request.launchSettings
            )
            guard report.allPassed else {
                throw UnifiedOrchestrationError.commandFailed("容器内 v3.2 精简优化未全部通过核验。")
            }
            return ((), "v3.2 系统精简、去云同步、CompactOS 与图形网络核验全部通过。")
        }

        return try await executeStage(
            .compactAndRegister, containerPath: bundlePath, steps: &steps,
            runningDetail: "正在优雅关机、卸载安装介质并执行离线 qcow2 磁盘瘦身…"
        ) {
            try await self.gracefulShutdownAndWait(vmUUID: vmUUID, resolved: resolved, request: request)
            try self.ejectInstallMedia(in: bundleURL)
            let report = try await self.diskCompactor.compactContainerSystemDisk(
                bundlePath: bundlePath, fileManager: self.fileManager
            )
            let beforeText = String(format: "%.1f", report.beforeGiB)
            let afterText = String(format: "%.1f", report.afterGiB)
            return (
                report,
                "已卸载安装镜像并瘦身：\(beforeText) GiB → \(afterText) GiB（英文原版镜像联网后可在游戏库一键补齐中文输入法）。"
            )
        }
    }
    static func initialSteps() -> [AutoDeployStepReport] {
        AutoDeployStage.allCases.map {
            AutoDeployStepReport(stage: $0, state: .pending, detail: "等待执行")
        }
    }

    func normalizedBundleURL(for request: AutoDeployRequest) -> URL {
        let trimmed = request.containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "malt-win11-arm64" : trimmed
        let finalName = baseName.lowercased().hasSuffix(".utm") ? baseName : "\(baseName).utm"
        return request.destinationDirectory.standardizedFileURL.appending(path: finalName, directoryHint: .isDirectory)
    }

    func prepareImage(request: AutoDeployRequest) async throws -> (URL, String) {
        switch request.imageSource {
        case let .localISO(url):
            let validated = try bootstrapService.validateWindowsARM64ISO(
                at: url, minimumSizeBytes: request.minimumISOSizeBytes, fileManager: fileManager
            )
            let sizeGiB = String(format: "%.2f", Double(validated.sizeBytes) / 1_073_741_824.0)
            return (validated.isoURL, "本地镜像校验通过（\(validated.formatSignature)，\(sizeGiB) GiB）。")
        case let .officialDownloadURL(url, expectedSHA256):
            let downloaded = try await bootstrapService.downloadOfficialISO(
                from: url, expectedSHA256: expectedSHA256, fileManager: fileManager
            ) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
            return (downloaded, "官方 Windows 11 ARM64 镜像已下载并校验通过。")
        }
    }

    func buildBootstrapMedia(
        request: AutoDeployRequest,
        resolved: ResolvedRuntimePaths
    ) async throws -> (URL, String) {
        var optimizerFiles: [URL] = []
        for path in [resolved.optimizerApplyScriptPath, resolved.optimizerProfilePath].compactMap({ $0 }) {
            optimizerFiles.append(URL(filePath: path))
        }
        let tempISO = fileManager.temporaryDirectory
            .appending(path: "malt-bootstrap-\(UUID().uuidString).iso")
        let built = try await bootstrapService.buildBootstrapISO(
            outputURL: tempISO,
            config: request.unattendedConfig,
            driverDirectory: request.driverDirectory,
            optimizerFiles: optimizerFiles,
            fileManager: fileManager
        )
        return (built, "已生成 MALTBOOT 无人值守与驱动注入引导镜像。")
    }

    func stageMediaFile(from source: URL, to destination: URL) async throws {
        let srcPath = source.standardizedFileURL.path(percentEncoded: false)
        let dstPath = destination.standardizedFileURL.path(percentEncoded: false)
        let clone = try? await commandRunner("/bin/cp", ["-c", srcPath, dstPath], ["__DEMOAPP_TIMEOUT_SECONDS": "60"])
        if clone?.exitCode == 0 && fileManager.fileExists(atPath: dstPath) {
            return
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
    }

    func resolvedControlBinary(resolved: ResolvedRuntimePaths) -> String? {
        if let explicit = configuration.containerControlBinaryURL {
            let path = explicit.path(percentEncoded: false)
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        guard let helper = resolved.containerHelperBinaryPath else { return nil }
        let path = URL(filePath: helper).deletingLastPathComponent()
            .appending(path: "utmctl").path(percentEncoded: false)
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    func runUnattendedInstall(
        bundlePath: String, vmUUID: String, resolved: ResolvedRuntimePaths, request: AutoDeployRequest
    ) async throws {
        guard let helperBinary = resolved.containerHelperBinaryPath,
              let controlBinary = resolvedControlBinary(resolved: resolved) else {
            throw UnifiedOrchestrationError.backendUnavailable("缺少内嵌容器引擎或 utmctl，无法执行自动安装。")
        }
        let helperApp = URL(filePath: helperBinary)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .path(percentEncoded: false)
        _ = try await commandRunner(
            "/usr/bin/open", ["-a", helperApp, bundlePath], ["__DEMOAPP_TIMEOUT_SECONDS": "15"]
        )
        for attempt in 0..<5 {
            let started = try? await commandRunner(
                controlBinary, ["start", "--hide", vmUUID], ["__DEMOAPP_TIMEOUT_SECONDS": "20"]
            )
            if started?.exitCode == 0 { break }
            if attempt < 4 { try await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        if request.pollIntervalSeconds >= 1.0 {
            await triggerOpticalBootKeypresses()
        }
        let deadline = Date().addingTimeInterval(max(1, request.installTimeoutSeconds))
        let pollNanos = UInt64(max(0.05, request.pollIntervalSeconds) * 1_000_000_000)
        while Date() < deadline {
            try Task.checkCancellation()
            let probe = try? await commandRunner(
                controlBinary,
                [
                    "exec", "--hide", vmUUID, "--cmd", "cmd.exe", "/c",
                    "if exist C:\\ProgramData\\Malt\\bootstrap.done echo MALT_BOOTSTRAP_DONE"
                ],
                ["__DEMOAPP_TIMEOUT_SECONDS": "10"]
            )
            if probe?.exitCode == 0 && probe?.stdout.contains("MALT_BOOTSTRAP_DONE") == true { return }
            try await Task.sleep(nanoseconds: pollNanos)
        }
        throw UnifiedOrchestrationError.commandFailed("等待 Windows 11 无人值守安装与来宾工具就绪超时。")
    }

    func triggerOpticalBootKeypresses() async {
        let safeSpace = "tell application \"System Events\" to if (name of first application process "
            + "whose frontmost is true) is \"UTM\" then tell process \"UTM\" to key code 49"
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try? await commandRunner("/usr/bin/osascript", ["-e", safeSpace], ["__DEMOAPP_TIMEOUT_SECONDS": "5"])
        }
    }

    func gracefulShutdownAndWait(
        vmUUID: String, resolved: ResolvedRuntimePaths, request: AutoDeployRequest
    ) async throws {
        guard let controlBinary = resolvedControlBinary(resolved: resolved) else { return }
        _ = try? await commandRunner(
            controlBinary,
            ["exec", "--hide", vmUUID, "--cmd", "shutdown.exe", "/s", "/t", "2"],
            ["__DEMOAPP_TIMEOUT_SECONDS": "15"]
        )
        let deadline = Date().addingTimeInterval(120)
        let pollNanos = UInt64(max(0.05, min(2.0, request.pollIntervalSeconds)) * 1_000_000_000)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try? await commandRunner(
                controlBinary, ["status", "--hide", vmUUID], ["__DEMOAPP_TIMEOUT_SECONDS": "5"]
            )
            let state = status?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if status?.exitCode == 0 && (state == "stopped" || state.isEmpty) {
                return
            }
            try await Task.sleep(nanoseconds: pollNanos)
        }
        throw UnifiedOrchestrationError.commandFailed("等待容器正常关机超时，未能执行离线磁盘瘦身。")
    }

    func updateStep(
        _ stage: AutoDeployStage, state: ProvisioningStepState, detail: String, in steps: inout [AutoDeployStepReport]
    ) async {
        if let idx = steps.firstIndex(where: { $0.stage == stage }) {
            steps[idx] = AutoDeployStepReport(stage: stage, state: state, detail: detail)
        }
        let snapshot = steps
        await MainActor.run { self.steps = snapshot }
    }

    func executeStage<Value>(
        _ stage: AutoDeployStage, containerPath: String, steps: inout [AutoDeployStepReport],
        runningDetail: String, operation: () async throws -> (Value, String)
    ) async throws -> Value {
        await updateStep(stage, state: .running, detail: runningDetail, in: &steps)
        do {
            let (value, detail) = try await operation()
            await updateStep(stage, state: .succeeded, detail: detail, in: &steps)
            return value
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await updateStep(stage, state: .failed, detail: message, in: &steps)
            let report = AutoDeployReport(
                containerPath: containerPath, vmUUID: "", steps: steps, compactionReport: nil, allPassed: false
            )
            await MainActor.run { self.lastReport = report }
            throw error
        }
    }

    func finalizeReport(
        containerPath: String, vmUUID: String, steps: [AutoDeployStepReport], compaction: ContainerDiskCompactionReport
    ) async -> AutoDeployReport {
        let report = AutoDeployReport(
            containerPath: containerPath, vmUUID: vmUUID, steps: steps, compactionReport: compaction, allPassed: true
        )
        await MainActor.run { self.lastReport = report; self.isRunning = false }
        return report
    }
}
