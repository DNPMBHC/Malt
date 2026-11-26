// SPDX-License-Identifier: GPL-3.0-or-later
// Four-stage automated container provisioning, guest optimization injection, and lossless rollback service.

import Combine
import Foundation

/// Stages of the automated managed-container provisioning and optimization pipeline.
public enum ContainerProvisioningStage: String, Codable, CaseIterable, Sendable {
    case verifySourceContainer
    case configureHardwarePipeline
    case applyGuestOptimization
    case verifyGraphicsAndNetwork

    public var displayTitle: String {
        switch self {
        case .verifySourceContainer:
            return "校验受管容器与安全边界"
        case .configureHardwarePipeline:
            return "配置硬件与多队列管线"
        case .applyGuestOptimization:
            return "注入中文/免更新/突发稳帧精简优化"
        case .verifyGraphicsAndNetwork:
            return "核验 WHQL 图形驱动、着色器缓存与低延迟网络"
        }
    }
}

/// Execution state for an individual provisioning stage.
public enum ProvisioningStepState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

/// Per-stage progress and outcome report.
public struct ProvisioningStepReport: Identifiable, Codable, Equatable, Sendable {
    public var id: ContainerProvisioningStage { stage }
    public let stage: ContainerProvisioningStage
    public let state: ProvisioningStepState
    public let detail: String

    public init(stage: ContainerProvisioningStage, state: ProvisioningStepState, detail: String) {
        self.stage = stage
        self.state = state
        self.detail = detail
    }
}

/// Full outcome of a provisioning and optimization run.
public struct ContainerProvisioningReport: Codable, Equatable, Sendable {
    public let containerPath: String
    public let steps: [ProvisioningStepReport]
    public let allPassed: Bool
    public let completedAt: Date

    public init(
        containerPath: String,
        steps: [ProvisioningStepReport],
        allPassed: Bool,
        completedAt: Date = Date()
    ) {
        self.containerPath = containerPath
        self.steps = steps
        self.allPassed = allPassed
        self.completedAt = completedAt
    }
}

/// Orchestrates 4-step container hardware configuration, guest-optimizer v3.1 injection,
/// graphics/network verification, resumable retry, APFS CoW derivation, and lossless rollback.
public final class ContainerProvisioningService: ObservableObject, @unchecked Sendable {
    @Published public private(set) var steps: [ProvisioningStepReport]
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var lastReport: ContainerProvisioningReport?

    private let configuration: UnifiedOrchestratorConfiguration
    private let fileManager: FileManager
    private let commandRunner: UnifiedRuntimeOrchestrator.CommandRunner
    private let hardwareProfileProvider: @Sendable () -> HardwareProfileSnapshot
    private let stopVerifier: (@Sendable (String, String) async throws -> Void)?
    private let guestExecutor: ContainerProvisioningGuestExecutor

    public init(
        configuration: UnifiedOrchestratorConfiguration = UnifiedOrchestratorConfiguration(),
        fileManager: FileManager = .default,
        commandRunner: UnifiedRuntimeOrchestrator.CommandRunner? = nil,
        hardwareProfileProvider: (@Sendable () -> HardwareProfileSnapshot)? = nil,
        vmnetStatusProvider: (@Sendable () -> NativeVMNetStatus)? = nil,
        shaderCacheOverrideURL: URL? = nil,
        stopVerifier: (@Sendable (String, String) async throws -> Void)? = nil,
        guestReadinessVerifier: (@Sendable (String, String) async throws -> Void)? = nil
    ) {
        let runner: UnifiedRuntimeOrchestrator.CommandRunner = commandRunner ?? { exe, args, env in
            try await OrchestratorProcessRunner.run(executable: exe, arguments: args, environment: env)
        }
        self.configuration = configuration
        self.fileManager = fileManager
        self.commandRunner = runner
        self.hardwareProfileProvider = hardwareProfileProvider ?? { HardwareAutoTuner().detectHardwareProfile() }
        self.stopVerifier = stopVerifier
        self.guestExecutor = ContainerProvisioningGuestExecutor(
            configuration: configuration,
            commandRunner: runner,
            vmnetStatusProvider: vmnetStatusProvider ?? { UnifiedRuntimeDiscovery.detectNativeVMNetStatus() },
            shaderCacheOverrideURL: shaderCacheOverrideURL,
            guestReadinessVerifier: guestReadinessVerifier
        )
        self.steps = Self.initialSteps()
    }

    /// Official Microsoft Windows 11 ARM64 download guide URL (Malt never distributes OS images).
    public static func officialWindowsARM64GuideURL() -> URL {
        URL(string: "https://www.microsoft.com/software-download/windows11arm64") ?? URL(filePath: "/")
    }

    /// Safely derives a writable managed working copy from a read-only golden template using APFS CoW.
    public func deriveManagedCopy(fromGoldenPath goldenPath: String, destinationPath: String) async throws -> String {
        try await ContainerProvisioningPipeline.deriveManagedCopy(
            fromGoldenPath: goldenPath, destinationPath: destinationPath,
            fileManager: fileManager, commandRunner: commandRunner
        )
    }

    /// Runs the 4-stage automated provisioning & optimization pipeline with resumable retry support.
    public func provisionAndOptimize(
        containerPath: String,
        settings: UnifiedLaunchSettings = UnifiedLaunchSettings()
    ) async throws -> ContainerProvisioningReport {
        await MainActor.run {
            self.isRunning = true
            self.steps = Self.initialSteps()
        }
        defer { Task { @MainActor in self.isRunning = false } }

        let resolved = UnifiedRuntimeDiscovery.resolve(configuration: configuration, fileManager: fileManager)
        var currentSteps = Self.initialSteps()
        var checkpoint: ContainerProvisioningCheckpoint?

        let containerUUID = try await executeStage(
            .verifySourceContainer, containerPath: containerPath, steps: &currentSteps,
            runningDetail: "正在核验容器结构、Secure Boot 与只读边界…"
        ) {
            let uuid = try ContainerProvisioningPipeline.verifySourceContainer(
                at: containerPath, fileManager: self.fileManager)
            checkpoint = ContainerProvisioningPipeline.loadCheckpoint(at: containerPath, expectedUUID: uuid)
                ?? ContainerProvisioningCheckpoint(schemaVersion: 1, containerUUID: uuid, succeededStages: [])
            return (uuid, "受管工作副本校验通过，Secure Boot 合规。")
        }
        try await executeResumableStage(
            ResumableStageSpec(
                stage: .configureHardwarePipeline, containerPath: containerPath,
                skippedDetail: "断点续跑：硬件与多队列管线已完成配置。",
                runningDetail: "正在配置 RAM/vCPU、VirtIO-Blk 多队列与外设管线…"),
            checkpoint: &checkpoint, steps: &currentSteps
        ) {
            try await self.verifyStoppedBeforeHardwareChange(
                containerPath: containerPath, vmIdentifier: containerUUID, resolved: resolved)
            return try ContainerProvisioningPipeline.configureHardwarePipeline(
                bundlePath: containerPath, settings: settings,
                hardware: self.hardwareProfileProvider(), fileManager: self.fileManager).summary
        }
        try await executeResumableStage(
            ResumableStageSpec(
                stage: .applyGuestOptimization, containerPath: containerPath,
                skippedDetail: "断点续跑：来宾精简优化 v3.1 已核验生效。",
                runningDetail: "正在通过 QGA 注入并核验 guest-optimizer v3.1…"),
            checkpoint: &checkpoint, steps: &currentSteps
        ) {
            try await self.guestExecutor.runGuestOptimization(
                vmIdentifier: containerUUID, resolved: resolved, fileManager: self.fileManager)
        }
        _ = try await executeStage(
            .verifyGraphicsAndNetwork, containerPath: containerPath, steps: &currentSteps,
            runningDetail: "正在核验 WHQL viogpu3d、着色器缓存与非 slirp 网络…"
        ) {
            ((), try await self.guestExecutor.verifyGraphicsAndNetwork(
                vmIdentifier: containerUUID, resolved: resolved, fileManager: self.fileManager))
        }
        ContainerProvisioningPipeline.clearCheckpoint(at: containerPath, fileManager: fileManager)
        return await finalizeReport(containerPath: containerPath, steps: currentSteps)
    }

    /// Losslessly rolls back guest-optimizer v3.1 tweaks (via QGA when reachable) and hardware backup.
    public func rollbackOptimization(containerPath: String) async throws {
        await MainActor.run { self.isRunning = true }
        defer { Task { @MainActor in self.isRunning = false } }

        let uuid = try ContainerProvisioningPipeline.verifySourceContainer(
            at: containerPath, fileManager: fileManager
        )
        let resolved = UnifiedRuntimeDiscovery.resolve(configuration: configuration, fileManager: fileManager)
        var guestRolledBack = false

        if let control = guestExecutor.resolvedControlBinary(resolved: resolved, fileManager: fileManager),
           let rollbackScript = resolved.optimizerRollbackScriptPath,
           let profilePath = resolved.optimizerProfilePath,
           fileManager.isReadableFile(atPath: rollbackScript),
           fileManager.isReadableFile(atPath: profilePath),
           await guestExecutor.isGuestAgentReachable(controlBinary: control, vmIdentifier: uuid) {
            try await guestExecutor.runGuestRollback(
                controlBinary: control, vmIdentifier: uuid,
                rollbackScriptPath: rollbackScript, profilePath: profilePath
            )
            guestRolledBack = true
        }

        let hardwareRestored = try ContainerProvisioningPipeline.restoreHardwareBackupIfPresent(
            bundlePath: containerPath, fileManager: fileManager
        )
        ContainerProvisioningPipeline.clearCheckpoint(at: containerPath, fileManager: fileManager)

        guard guestRolledBack || hardwareRestored else {
            throw UnifiedOrchestrationError.backendUnavailable(
                "未检测到可回滚的硬件备份，且容器 QGA 不可达。请先启动容器并登录 Windows 后再执行来宾优化回滚。"
            )
        }
    }
}

private extension ContainerProvisioningService {
    static func initialSteps() -> [ProvisioningStepReport] {
        ContainerProvisioningStage.allCases.map {
            ProvisioningStepReport(stage: $0, state: .pending, detail: "等待执行")
        }
    }

    func updateStep(
        _ stage: ContainerProvisioningStage, state: ProvisioningStepState,
        detail: String, in steps: inout [ProvisioningStepReport]
    ) async {
        if let idx = steps.firstIndex(where: { $0.stage == stage }) {
            steps[idx] = ProvisioningStepReport(stage: stage, state: state, detail: detail)
        }
        let snapshot = steps
        await MainActor.run { self.steps = snapshot }
    }

    func executeStage<Value>(
        _ stage: ContainerProvisioningStage,
        containerPath: String,
        steps: inout [ProvisioningStepReport],
        runningDetail: String,
        operation: () async throws -> (Value, String)
    ) async throws -> Value {
        await updateStep(stage, state: .running, detail: runningDetail, in: &steps)
        do {
            let (value, detail) = try await operation()
            await updateStep(stage, state: .succeeded, detail: detail, in: &steps)
            return value
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await updateStep(stage, state: .failed, detail: message, in: &steps)
            let report = ContainerProvisioningReport(
                containerPath: containerPath, steps: steps, allPassed: false, completedAt: Date()
            )
            await MainActor.run { self.lastReport = report }
            throw error
        }
    }

    struct ResumableStageSpec {
        let stage: ContainerProvisioningStage
        let containerPath: String
        let skippedDetail: String
        let runningDetail: String
    }

    func finalizeReport(containerPath: String, steps: [ProvisioningStepReport]) async -> ContainerProvisioningReport {
        let report = ContainerProvisioningReport(
            containerPath: containerPath, steps: steps, allPassed: true, completedAt: Date()
        )
        await MainActor.run {
            self.lastReport = report
            self.isRunning = false
        }
        return report
    }

    func executeResumableStage(
        _ spec: ResumableStageSpec,
        checkpoint: inout ContainerProvisioningCheckpoint?,
        steps: inout [ProvisioningStepReport],
        operation: () async throws -> String
    ) async throws {
        if checkpoint?.succeededStages.contains(spec.stage.rawValue) == true {
            await updateStep(spec.stage, state: .skipped, detail: spec.skippedDetail, in: &steps)
            return
        }
        _ = try await executeStage(
            spec.stage, containerPath: spec.containerPath, steps: &steps, runningDetail: spec.runningDetail
        ) {
            let detail = try await operation()
            return ((), detail)
        }
        if var current = checkpoint {
            if !current.succeededStages.contains(spec.stage.rawValue) {
                current.succeededStages.append(spec.stage.rawValue)
            }
            checkpoint = current
            ContainerProvisioningPipeline.saveCheckpoint(current, at: spec.containerPath, fileManager: fileManager)
        }
    }

    func verifyStoppedBeforeHardwareChange(
        containerPath: String, vmIdentifier: String, resolved: ResolvedRuntimePaths
    ) async throws {
        if let stopVerifier {
            try await stopVerifier(containerPath, vmIdentifier)
            return
        }
        guard let control = guestExecutor.resolvedControlBinary(resolved: resolved, fileManager: fileManager) else {
            return
        }
        let status = try await commandRunner(
            control, ["status", "--hide", vmIdentifier], ["__DEMOAPP_TIMEOUT_SECONDS": "5"]
        )
        try ContainerGuestDispatcher.requireAutomationAccess(status)
        if status.exitCode == 0 {
            let state = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if state != "stopped" && !state.isEmpty {
                throw UnifiedOrchestrationError.backendUnavailable(
                    "容器尚未完全关闭（当前状态：\(state)），请先正常关机再配置硬件管线。"
                )
            }
        }
    }
}
