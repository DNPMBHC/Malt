// SPDX-License-Identifier: GPL-3.0-or-later
// Optional service approval and explicit stopped-container configuration. Owner: @DNPMBHC

import AppKit
import Darwin
import SwiftUI
import WhiskyKit

@MainActor
struct NativeNetworkControls: View {
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    let hasKnownActiveLaunch: Bool
    @State private var containerPath: String?
    @State private var isBusy = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var restoreConfiguration = false
    @State private var showConfigurationConfirmation = false
    @State private var showRevokeConfirmation = false
    @State private var selectedImportURL: URL?
    @State private var showImportConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            serviceStatus
            serviceActions
            containerActions
            Text("服务就绪仅表示连接入口可用，不代表容器已使用原生网络或已能联网。")
                .font(.caption).foregroundStyle(.secondary)
            if let feedback {
                AppStatusLabel(
                    text: feedback, systemImage: feedbackIsError ? "exclamationmark.triangle" : "info.circle",
                    tint: feedbackIsError ? .orange : .secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            if isBusy { ProgressView().controlSize(.small) }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .task(id: isStartingState) {
            await pollWhileStarting()
        }
        .confirmationDialog("导入所选容器？", isPresented: $showImportConfirmation) {
            Button("确认实例已完全关闭，且不是模板或冷备", action: importContainer)
            Button("取消", role: .cancel) { selectedImportURL = nil }
        } message: {
            Text("仅登记您明确选择的实例，不复制系统盘或启动容器。请先完全关闭实例，且不要选择系统模板或冷备。")
        }
        .confirmationDialog("停用原生网络后台服务？", isPresented: $showRevokeConfirmation) {
            Button("停用服务", role: .destructive, action: revokeAuthorization)
            Button("取消", role: .cancel) { }
        } message: {
            Text("停用服务会中断仍在使用它的容器网络。请先完全关闭相关容器；此操作不会自动恢复容器网络配置。")
        }
        .confirmationDialog(
            restoreConfiguration ? "恢复所选容器原有网络配置？" : "应用原生网络配置到所选容器？",
            isPresented: $showConfigurationConfirmation
        ) {
            Button(restoreConfiguration ? "确认恢复配置" : "确认应用配置", action: configureContainer)
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完全关闭所选容器。系统将再次核验停止状态并拒绝不安全或已漂移的配置；此操作不会启动容器。")
        }
    }

    private var serviceStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原生网络服务")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                AppStatusLabel(
                    text: orchestrator.nativeNetworkPermissionState?.statusSummary ?? "请刷新授权状态。",
                    systemImage: statusIconName,
                    tint: statusTint
                )
                .fixedSize(horizontal: false, vertical: true)
                if isStartingState {
                    ProgressView().controlSize(.small)
                }
            }
            if isTimedOutState {
                Text("15 秒启动诊断已超时：请点击「申请原生网络授权」重试，或在「系统批准设置」检查后台项；若暂不启用，可继续使用共享网络。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var serviceActions: some View {
        AppAdaptiveRow {
            HStack(spacing: 8) {
                Button(authorizationButtonTitle) {
                    _ = orchestrator.requestNativeNetworkAuthorization()
                }
                .disabled(!canRequestAuthorization)
                Button("系统批准设置") { orchestrator.openNativeNetworkApprovalSettings() }
            }
        } trailing: {
            HStack(spacing: 8) {
                Button("刷新", action: refresh)
                Button("停用服务", role: .destructive) { showRevokeConfirmation = true }
                    .disabled(!canRevokeAuthorization)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy)
    }

    private var containerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(containerPath.map { "网络配置目标：\(URL(filePath: $0).lastPathComponent)" } ?? "尚未选择容器")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AppAdaptiveRow {
                Button("选择或导入容器", action: selectContainer)
            } trailing: {
                HStack(spacing: 8) {
                    Button("应用网络配置") { confirmConfiguration(restore: false) }
                        .disabled(containerPath == nil || hasKnownActiveLaunch
                            || orchestrator.nativeNetworkPermissionState?.state != .ready)
                    Button("恢复原配置") { confirmConfiguration(restore: true) }
                        .disabled(containerPath == nil || hasKnownActiveLaunch)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(isBusy)
            if hasKnownActiveLaunch {
                Text("有已知运行任务，请完全关闭后再应用、恢复配置或停用服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("请选择合法授权且已有来宾工具的 Windows ARM64 容器。请先完全关机；配置时会按需登记并核验停止状态，不会启动容器。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var authorizationButtonTitle: String {
        orchestrator.nativeNetworkPermissionState?.state == .requiresApproval ? "继续系统批准" : "申请原生网络授权"
    }

    private var canRequestAuthorization: Bool {
        guard let state = orchestrator.nativeNetworkPermissionState?.state else { return false }
        switch state {
        case .helperMissing, .signingRequired, .ready, .starting: return false
        case .notRegistered, .requiresApproval, .operationFailed: return true
        }
    }

    private var canRevokeAuthorization: Bool {
        guard !hasKnownActiveLaunch,
              let registration = orchestrator.nativeNetworkPermissionState?.registrationStatus else { return false }
        return registration == .enabled || registration == .requiresApproval
    }

    private var isStartingState: Bool {
        orchestrator.nativeNetworkPermissionState?.state == .starting
    }

    private var isTimedOutState: Bool {
        orchestrator.nativeNetworkPermissionState?.state == .operationFailed(Int(ETIMEDOUT))
    }

    private var statusIconName: String {
        switch orchestrator.nativeNetworkPermissionState?.state {
        case .ready: return "checkmark.circle"
        case .operationFailed, .helperMissing, .signingRequired: return "exclamationmark.triangle"
        case .starting: return "clock"
        default: return "network"
        }
    }

    private var statusTint: Color {
        switch orchestrator.nativeNetworkPermissionState?.state {
        case .ready: return .green
        case .operationFailed, .helperMissing, .signingRequired: return .orange
        default: return .secondary
        }
    }

    private func pollWhileStarting() async {
        guard isStartingState else { return }
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled || !isStartingState { return }
            _ = orchestrator.refreshNativeNetworkStatus()
            if !isStartingState { return }
        }
    }

    private func refresh() {
        _ = orchestrator.refreshNativeNetworkStatus()
        if containerPath == nil { containerPath = orchestrator.resolvedRuntimePaths().playableVMBundlePath }
    }

    private func selectContainer() {
        let panel = NSOpenPanel()
        panel.title = "选择已有 Windows ARM64 容器"
        panel.message = "选择已安装来宾工具的容器；仅会导入为受管实例，不会启动或改写磁盘内容。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedImportURL = url
        showImportConfirmation = true
    }

    private func importContainer() {
        guard let url = selectedImportURL else { return }
        selectedImportURL = nil
        isBusy = true
        feedback = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                let imported = try await orchestrator.importPlayableContainer(at: url, confirmedStopped: true)
                containerPath = imported.bundlePath
                feedbackIsError = false
                feedback = "已选择受管容器。请先完全关机；应用或恢复配置时会按需登记并核验停止状态，不会启动容器。"
                refresh()
            } catch {
                feedbackIsError = true
                feedback = error.localizedDescription
            }
        }
    }

    private func revokeAuthorization() {
        isBusy = true
        feedback = nil
        Task { @MainActor in
            defer { isBusy = false }
            let snapshot = await orchestrator.revokeNativeNetworkAuthorization()
            switch snapshot.state {
            case .helperMissing, .signingRequired, .operationFailed:
                feedbackIsError = true
            case .notRegistered, .requiresApproval, .starting, .ready:
                feedbackIsError = false
            }
            feedback = snapshot.statusSummary
        }
    }

    private func confirmConfiguration(restore: Bool) {
        restoreConfiguration = restore
        showConfigurationConfirmation = true
    }

    private func configureContainer() {
        guard let containerPath else { return }
        let entry = UnifiedGameEntry(
            name: "容器网络配置", executablePath: "", engineKind: .antiCheatVM,
            vmBundlePath: containerPath, installationState: .ready
        )
        isBusy = true
        feedback = nil
        let restore = restoreConfiguration
        Task { @MainActor in
            defer { isBusy = false }
            do {
                _ = try await orchestrator.configureNativeNetwork(for: entry, restore: restore)
                feedbackIsError = false
                feedback = restore ? "已恢复容器原有网络配置。" : "原生网络配置已写入；请在下次启动后验证实际联网。"
                refresh()
            } catch is CancellationError {
                feedbackIsError = true
                feedback = "操作已取消，请刷新并确认容器配置状态。"
            } catch {
                feedbackIsError = true
                feedback = error.localizedDescription
            }
        }
    }
}
