// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import WhiskyKit

struct UnifiedRuntimeStorageView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    @ObservedObject var preferences: UnifiedPreferencesModel
    @ObservedObject var launcher: RuntimeLaunchController
    let onOpenSetup: () -> Void
    let onTriggerOnboarding: () -> Void
    let onCreateBottle: () -> Void

    @State private var healthMap: [String: Bool] = [:]
    @State private var resolvedPaths: ResolvedRuntimePaths?
    @State private var hardware: HardwareProfileSnapshot = HardwareAutoTuner().detectHardwareProfile()
    @State private var shaderCacheSizeLabel: String = "计算中…"
    @State private var showLegacyBottles: Bool = false
    @State private var showNetworkOptions = false
    @State private var selectedLegacyBottleURL: URL?
    @State private var statusBanner: String?
    @State private var cacheStatusIsError = false
    @State private var cacheIssues: [ShaderCacheIssue] = []
    @State private var isCacheBusy = false
    @State private var showCacheCleanupConfirmation = false

    var body: some View {
        AppPage(title: "环境与存储", subtitle: "检查运行组件、容器与缓存。") {
            runtimeHealthCard
            storageAndCacheCard
            AppSection {
                DisclosureGroup("容器网络设置", isExpanded: $showNetworkOptions) {
                    NativeNetworkControls(
                        orchestrator: orchestrator,
                        hasKnownActiveLaunch: hasKnownActiveLaunch
                    )
                    .padding(.top, 16)
                }
                .font(.subheadline.weight(.medium))
            }
            onboardingAndSetupCard
            legacyBottlesDisclosure
        }
        .onAppear(perform: refreshDiagnostics)
    }

    private var runtimeHealthCard: some View {
        AppSection {
            AppAdaptiveRow {
                Text("运行组件")
                    .font(.headline)
            } trailing: {
                Button(action: refreshDiagnostics) {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            Divider()
            healthRow(
                title: "原生转译组件", isReady: healthMap["wine_ready"] ?? false,
                readyText: "可用", missingText: "未安装"
            )
            healthRow(
                title: "容器引擎", isReady: healthMap["anti_cheat_vm_ready"] ?? false,
                readyText: (healthMap["embedded_helper_ready"] ?? false) ? "已内嵌" : "外部组件可用",
                missingText: (healthMap["utm_custom_ready"] ?? false)
                    && !(healthMap["container_settings_contract_ready"] ?? false) ? "需更新运行组件" : "待配置"
            )
            healthRow(
                title: "游玩容器", isReady: healthMap["playable_vm_discovered"] ?? false,
                readyText: resolvedPaths?.playableVMBundlePath.map {
                    URL(filePath: $0).lastPathComponent
                } ?? "已发现", missingText: "未发现容器"
            )
            healthRow(
                title: "游戏库存储", isReady: healthMap["library_store_writable"] ?? false,
                readyText: "可写", missingText: "不可写"
            )
        }
    }

    private func healthRow(
        title: String, isReady: Bool, readyText: String, missingText: String
    ) -> some View {
        AppAdaptiveRow {
            Text(title)
                .font(.subheadline)
        } trailing: {
            AppStatusLabel(
                text: isReady ? readyText : missingText,
                systemImage: isReady ? "checkmark.circle" : "circle.dashed",
                tint: isReady ? .green : .secondary
            )
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storageAndCacheCard: some View {
        AppSection(title: "存储与缓存") {
            VStack(alignment: .leading, spacing: 6) {
                Text("建议存储位置")
                    .font(.subheadline)
                Text(resolvedStoragePath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("仅供参考，不会自动迁移现有游戏或容器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("着色器缓存")
                        .font(.subheadline)
                    Text("\(shaderCacheSizeLabel) · D3DMetal / DXMT / DXVK")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button(isCacheBusy ? "处理中…" : "清理缓存", role: .destructive) {
                    showCacheCleanupConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(isCacheBusy || hasKnownActiveLaunch)
                .confirmationDialog("清理已知着色器缓存？", isPresented: $showCacheCleanupConfirmation) {
                    Button("确认清理", role: .destructive, action: clearShaderCaches)
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("仅清理上方统计范围内的缓存，下次启动时重新生成。不会结束任何进程；检测到游戏、容器运行或无法确认运行状态时，将停止清理。")
                }
            }
            if hasKnownActiveLaunch {
                Text("请先关闭正在运行或启动中的游戏，再清理缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let banner = statusBanner {
                AppStatusLabel(
                    text: banner,
                    systemImage: cacheStatusIsError ? "exclamationmark.triangle" : "checkmark.circle",
                    tint: cacheStatusIsError ? .orange : .secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(cacheIssues.enumerated()), id: \.offset) { _, issue in
                Label("\(issue.label)：\(issue.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onboardingAndSetupCard: some View {
        AppSection(title: "设置入口") {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("快速设置")
                        .font(.subheadline)
                    Text("重新检查硬件与运行环境，生成资源建议。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                Button("重新运行引导", action: onTriggerOnboarding)
                    .buttonStyle(.bordered)
            }
            Divider()
            AppAdaptiveRow {
                Text("原生运行组件")
                    .font(.subheadline)
            } trailing: {
                Button("安装与更新…", action: onOpenSetup)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var legacyBottlesDisclosure: some View {
        AppSection {
            DisclosureGroup("高级：兼容容器管理", isExpanded: $showLegacyBottles) {
                VStack(alignment: .leading, spacing: 16) {
                    AppAdaptiveRow {
                        Text("\(bottleVM.bottles.count) 个传统容器")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } trailing: {
                        Button("新建容器", action: onCreateBottle)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if bottleVM.bottles.isEmpty {
                        Text("当前没有传统 Bottle 容器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bottleVM.bottles.sorted()) { bottle in
                            AppAdaptiveRow {
                                Label(bottle.settings.name, systemImage: "shippingbox")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            } trailing: {
                                Button(selectedLegacyBottleURL == bottle.url ? "收起详情" : "打开管理") {
                                    selectedLegacyBottleURL = selectedLegacyBottleURL == bottle.url ? nil : bottle.url
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            if selectedLegacyBottleURL == bottle.url {
                                BottleView(bottle: bottle, launchController: launcher)
                                    .frame(minHeight: 360)
                                    .background(
                                        Color(nsColor: .windowBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                        }
                    }
                }
                .padding(.top, 16)
            }
        }
    }
}

private extension UnifiedRuntimeStorageView {
    var resolvedStoragePath: String {
        preferences.preferredStoragePath.isEmpty ? hardware.recommendedStoragePath : preferences.preferredStoragePath
    }

    func refreshDiagnostics() {
        hardware = HardwareAutoTuner().detectHardwareProfile()
        healthMap = orchestrator.healthStatus()
        resolvedPaths = orchestrator.resolvedRuntimePaths()
        refreshShaderCacheSize()
    }

    var hasKnownActiveLaunch: Bool {
        orchestrator.activeEntryID != nil || bottleVM.bottles.contains { bottle in
            bottle.programs.contains { launcher.isLaunching($0) }
        }
    }

    var shaderCacheTargets: [ShaderCacheTarget] {
        var bottles = bottleVM.bottles.map(\.url)
        bottles += orchestrator.libraryStore.entries.compactMap(\.bottleURL)
        if let fallback = orchestrator.configuration.defaultBottleURL { bottles.append(fallback) }
        return ShaderCacheService().targets(bottleURLs: bottles)
    }

    func refreshShaderCacheSize() {
        guard !isCacheBusy else { return }
        isCacheBusy = true
        let targets = shaderCacheTargets
        Task { @MainActor in
            let summary = await Task.detached(priority: .utility) {
                ShaderCacheService().measure(targets: targets)
            }.value
            shaderCacheSizeLabel = Self.cacheSizeLabel(summary)
            cacheIssues = summary.failures
            isCacheBusy = false
        }
    }

    func clearShaderCaches() {
        guard !isCacheBusy else { return }
        guard !hasKnownActiveLaunch else {
            cacheStatusIsError = true
            statusBanner = "有游戏正在运行或启动，未清理任何缓存。"
            return
        }
        isCacheBusy = true
        statusBanner = nil
        cacheIssues = []
        let targets = shaderCacheTargets
        let helperNames = [resolvedPaths?.containerHelperBinaryPath]
            .compactMap { $0 }.map { URL(filePath: $0).lastPathComponent }
        Task { @MainActor in
            let (result, summary) = await Task.detached(priority: .utility) {
                let service = ShaderCacheService()
                let result = service.clear(targets: targets) {
                    ShaderCacheService.processActivity(additionalExecutableNames: helperNames)
                }
                return (result, service.measure(targets: targets))
            }.value
            shaderCacheSizeLabel = Self.cacheSizeLabel(summary)
            cacheIssues = result.failures + summary.failures
            cacheStatusIsError = result.wasBlocked || !cacheIssues.isEmpty
            if result.wasBlocked {
                statusBanner = result.removedCount == 0
                    ? "检测到游戏或容器运行，或无法确认运行状态。未清理缓存，请关闭相关程序后重试。"
                    : "清理已停止：运行状态发生变化。已完成部分缓存清理，请关闭相关程序后重试。"
            } else if !cacheIssues.isEmpty {
                statusBanner = "部分缓存未能清理，请查看下方说明。已清理的缓存不受影响。"
            } else if result.removedCount == 0 {
                statusBanner = "没有需要清理的已知缓存。"
            } else {
                let size = ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file)
                statusBanner = "已清理 \(result.removedCount) 处缓存（\(size)），下次启动时重新生成。"
            }
            isCacheBusy = false
        }
    }

    static func cacheSizeLabel(_ summary: ShaderCacheSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file)
        return summary.failures.isEmpty ? size : "\(size)（部分缓存无法统计）"
    }

}
