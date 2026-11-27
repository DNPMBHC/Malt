// SPDX-License-Identifier: GPL-3.0-or-later
// Shared container status lights, .utm import flow, official Windows 11 ARM64 guide, and provisioning wizard.

import AppKit
import SwiftUI
import WhiskyKit

/// Shared container onboarding & provisioning panel used by FirstRunOnboardingView and UnifiedRuntimeStorageView.
@MainActor
struct ContainerProvisioningPanel: View {
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    @ObservedObject var preferences: UnifiedPreferencesModel
    let healthMap: [String: Bool]
    let resolvedPaths: ResolvedRuntimePaths?
    let onContainerChanged: () -> Void

    @StateObject private var provisioningService: ContainerProvisioningService
    @State private var selectedImportURL: URL?
    @State private var showImportConfirmation = false
    @State private var showRollbackConfirmation = false
    @State private var showCreationGuide = false
    @State private var showAutoDeploySheet = false
    @State private var isImporting = false
    @State private var isRollingBack = false
    @State private var isCompactingDisk = false
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    init(
        orchestrator: UnifiedRuntimeOrchestrator,
        preferences: UnifiedPreferencesModel,
        healthMap: [String: Bool],
        resolvedPaths: ResolvedRuntimePaths?,
        onContainerChanged: @escaping () -> Void
    ) {
        self.orchestrator = orchestrator
        self.preferences = preferences
        self.healthMap = healthMap
        self.resolvedPaths = resolvedPaths
        self.onContainerChanged = onContainerChanged
        _provisioningService = StateObject(
            wrappedValue: ContainerProvisioningService(configuration: orchestrator.configuration)
        )
    }

    private var engineReady: Bool {
        healthMap["embedded_helper_ready"] ?? false || healthMap["anti_cheat_vm_ready"] ?? false
    }

    private var activeContainerPath: String? {
        resolvedPaths?.playableVMBundlePath
    }

    private var containerReady: Bool {
        (healthMap["playable_vm_discovered"] ?? false) && activeContainerPath != nil
    }

    private var isProvisioningBusy: Bool {
        isImporting || isRollingBack || isCompactingDisk || provisioningService.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow(
                title: "Malt 内嵌引擎组件",
                ready: engineReady,
                readyText: (healthMap["embedded_helper_ready"] ?? false) ? "随包组件已就绪" : "外部引擎可用",
                missingText: "组件未就绪"
            )
            Divider()
            statusRow(
                title: "Windows 11 ARM64 受管工作容器",
                ready: containerReady,
                readyText: activeContainerPath.map {
                    "已关联：\(URL(filePath: $0).lastPathComponent)"
                } ?? "已导入受管容器",
                missingText: "尚未导入受管容器（引擎就绪不代表系统已安装）"
            )

            actionsRow

            ManagedContainerListSection(
                orchestrator: orchestrator,
                isBusy: isProvisioningBusy,
                onFeedback: { msg, isError in finishFeedback(msg, isError: isError) },
                onChanged: onContainerChanged
            )

            if showCreationGuide {
                creationGuideBox
            }

            if let containerPath = activeContainerPath, containerReady {
                Divider()
                ContainerOptimizationSection(
                    provisioningService: provisioningService,
                    isBusy: isProvisioningBusy,
                    isRollingBack: isRollingBack,
                    isCompactingDisk: isCompactingDisk,
                    onApplyOptimization: { runProvisioning(at: containerPath) },
                    onCompactDisk: { runDiskCompaction(at: containerPath) },
                    onRequestRollback: { showRollbackConfirmation = true }
                )
            }

            if let feedbackMessage {
                AppStatusLabel(
                    text: feedbackMessage,
                    systemImage: feedbackIsError ? "exclamationmark.triangle" : "checkmark.circle",
                    tint: feedbackIsError ? .orange : .green
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("导入所选受管容器？", isPresented: $showImportConfirmation) {
            Button("确认实例已完全关闭，且非模板或冷备", action: performImport)
            Button("取消", role: .cancel) { selectedImportURL = nil }
        } message: {
            Text("仅登记你明确选择的 .utm 受管容器，不复制系统盘、不分发系统镜像、也不会启动容器。")
        }
        .confirmationDialog("回滚容器优化配置？", isPresented: $showRollbackConfirmation) {
            Button("确认回滚优化", role: .destructive) {
                if let path = activeContainerPath { runRollback(at: path) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将容器配置与来宾优化还原至注入前备份状态；请确保容器已完全关闭。")
        }
        .sheet(isPresented: $showAutoDeploySheet) {
            AutomatedContainerDeploySheet(orchestrator: orchestrator, preferences: preferences) { report in
                feedbackIsError = !report.allPassed
                feedbackMessage = "已完成新建容器部署并登记：\(URL(filePath: report.containerPath).lastPathComponent)。"
                onContainerChanged()
            }
        }
    }

    private var actionsRow: some View {
        AppAdaptiveRow {
            HStack(spacing: 8) {
                Button { showAutoDeploySheet = true } label: {
                    Label("一键创建并精简 Win11 容器", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProvisioningBusy)

                Button(action: pickContainerBundle) {
                    HStack(spacing: 6) {
                        if isImporting { ProgressView().controlSize(.small) } else {
                            Image(systemName: "folder.badge.plus")
                        }
                        Text(isImporting ? "正在导入…" : "导入已有容器（.utm）")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isProvisioningBusy)
            }
        } trailing: {
            Button(showCreationGuide ? "收起指引" : "官方镜像指引") {
                showCreationGuide.toggle()
            }
            .buttonStyle(.bordered)
        }
    }

    private var creationGuideBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("合法获取与创建 Windows 11 ARM64 容器指引")
                .font(.subheadline.weight(.medium))
            Text("1. 请从微软官方通道获取正版 Windows 11 ARM64 镜像或 VHDX，Malt 不分发任何系统镜像。\n"
                 + "2. 使用本机容器工具完成系统安装、首次桌面登录与来宾工具安装后，先正常关机。\n"
                 + "3. 点击上方「导入已有受管容器（.utm）」关联该容器，即可继续应用精简与优化注入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: ContainerProvisioningService.officialWindowsARM64GuideURL()) {
                Label("打开微软官方 Windows 11 ARM64 获取页面", systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(title: String, ready: Bool, readyText: String, missingText: String) -> some View {
        AppAdaptiveRow {
            Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        } trailing: {
            AppStatusLabel(
                text: ready ? readyText : missingText,
                systemImage: ready ? "checkmark.circle" : "circle.dashed",
                tint: ready ? .green : .secondary
            ).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension ContainerProvisioningPanel {
    func pickContainerBundle() {
        let panel = NSOpenPanel()
        panel.title = "选择已有 Windows 11 ARM64 受管容器（.utm）"
        panel.message = "请选择已安装来宾工具且已完全关闭的 .utm 容器包。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedImportURL = url
        showImportConfirmation = true
    }

    func finishFeedback(_ message: String, isError: Bool, refresh: Bool = false) {
        feedbackIsError = isError
        feedbackMessage = isError ? InstalledGameDiscoverySection.redactedMessage(message) : message
        if refresh { onContainerChanged() }
    }

    func performImport() {
        guard let url = selectedImportURL else { return }
        selectedImportURL = nil
        isImporting = true
        feedbackMessage = nil
        Task {
            do {
                let imported = try await orchestrator.importPlayableContainer(at: url, confirmedStopped: true)
                let name = URL(filePath: imported.bundlePath).lastPathComponent
                isImporting = false
                finishFeedback("已关联受管容器「\(name)」。", isError: false, refresh: true)
            } catch {
                isImporting = false
                finishFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    func runProvisioning(at containerPath: String) {
        feedbackMessage = nil
        let settings = preferences.runtimeSettings
        Task {
            do {
                let report = try await provisioningService.provisionAndOptimize(
                    containerPath: containerPath, settings: settings
                )
                let msg = report.allPassed
                    ? "4 步性能精简与优化注入已完成并核验通过。"
                    : "部分步骤未完成，请查看下方逐项回执并重试。"
                finishFeedback(msg, isError: !report.allPassed, refresh: true)
            } catch {
                finishFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    func runDiskCompaction(at containerPath: String) {
        isCompactingDisk = true
        feedbackMessage = nil
        let service = ContainerAutoDeployService(configuration: orchestrator.configuration)
        Task {
            do {
                let report = try await service.compactExistingContainer(at: containerPath)
                let msg = String(
                    format: "容器磁盘瘦身完成：%.1f GiB → %.1f GiB（释放 %.1f GiB）。",
                    report.beforeGiB, report.afterGiB, report.reclaimedGiB
                )
                isCompactingDisk = false
                finishFeedback(msg, isError: false, refresh: true)
            } catch {
                isCompactingDisk = false
                finishFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    func runRollback(at containerPath: String) {
        isRollingBack = true
        feedbackMessage = nil
        Task {
            do {
                try await provisioningService.rollbackOptimization(containerPath: containerPath)
                isRollingBack = false
                finishFeedback("已无损回滚容器优化配置。", isError: false, refresh: true)
            } catch {
                isRollingBack = false
                finishFeedback(error.localizedDescription, isError: true)
            }
        }
    }
}

@MainActor
private struct ContainerOptimizationSection: View {
    @ObservedObject var provisioningService: ContainerProvisioningService
    let isBusy: Bool
    let isRollingBack: Bool
    let isCompactingDisk: Bool
    let onApplyOptimization: () -> Void
    let onCompactDisk: () -> Void
    let onRequestRollback: () -> Void

    private var completedStepsCount: Int {
        provisioningService.steps.filter { $0.state == .succeeded || $0.state == .skipped }.count
    }

    private var progressFraction: Double {
        guard !provisioningService.steps.isEmpty else { return 0 }
        return Double(completedStepsCount) / Double(provisioningService.steps.count)
    }

    private var showProgressDetails: Bool {
        provisioningService.isRunning || provisioningService.lastReport != nil
            || provisioningService.steps.contains { $0.state != .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("一键精简优化与成果注入")
                        .font(.subheadline.weight(.medium))
                    Text("自动配置多队列硬件管线、guest-optimizer v3.2（移除云同步/禁休眠/CompactOS/MPO 修复）与磁盘瘦身。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                HStack(spacing: 8) {
                    Button(action: onApplyOptimization) {
                        HStack(spacing: 6) {
                            if provisioningService.isRunning { ProgressView().controlSize(.small) } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(provisioningService.isRunning ? "正在注入…" : "应用 v3.2 精简优化")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)

                    Button(action: onCompactDisk) {
                        HStack(spacing: 5) {
                            if isCompactingDisk { ProgressView().controlSize(.small) } else {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                            }
                            Text(isCompactingDisk ? "瘦身中…" : "容器磁盘瘦身")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                    Button(isRollingBack ? "回滚中…" : "回滚优化", role: .destructive, action: onRequestRollback)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }
            }

            if showProgressDetails {
                ProgressView(value: progressFraction, total: 1.0)
                    .progressViewStyle(.linear)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(provisioningService.steps) { step in
                        stepRow(step)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func stepRow(_ step: ProvisioningStepReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stepIcon(for: step.state)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.stage.displayTitle)
                    .font(.caption.weight(.semibold))
                Text(InstalledGameDiscoverySection.redactedMessage(step.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stepIcon(for state: ProvisioningStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded, .skipped:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
