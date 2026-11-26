// SPDX-License-Identifier: GPL-3.0-or-later
// Minimalist performance presets, safe GiB memory selector, and collapsible advanced options.

import AppKit
import SwiftUI
import WhiskyKit

struct UnifiedPerformanceView: View {
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    @ObservedObject var preferences: UnifiedPreferencesModel

    @State private var hardware: HardwareProfileSnapshot = HardwareAutoTuner().detectHardwareProfile()
    @State private var vmnetStatus: NativeVMNetStatus = UnifiedRuntimeDiscovery.detectNativeVMNetStatus()
    @State private var latestRecommendation: AutoTuneRecommendation?
    @State private var isBenchmarking: Bool = false
    @State private var benchmarkProgress: Double = 0
    @State private var showAdvancedOptions: Bool = false
    @State private var appliedBannerText: String?

    private let tuner = HardwareAutoTuner()

    private var safeMemoryOptions: [Int] { UnifiedLaunchSettings.supportedContainerMemoryOptionsGiB(for: hardware) }
    private var recommendedMemoryGiB: Int {
        safeMemoryOptions.min(by: {
            abs($0 - HardwareAutoTuner.recommendedMemoryGiB(for: hardware))
                < abs($1 - HardwareAutoTuner.recommendedMemoryGiB(for: hardware))
        }) ?? 0
    }
    private var safeVCPUOptions: [Int] { HardwareAutoTuner.safeVCPUOptions(for: hardware) }

    var body: some View {
        AppPage(
            title: "性能设置",
            subtitle: "全局默认设置。单个游戏可在游戏库中覆盖资源预设。",
            maxWidth: 920
        ) {
            hardwareAndRecommendationSection
            resourceSection
            displayOptionsSection
            compatibilityOptionsSection
            advancedOptionsSection
            AppStatusLabel(
                text: "设置自动保存。容器相关设置需正常关闭 Windows，并完全退出容器引擎后重新打开；仅重启游戏或恢复挂起状态不会应用新设置。",
                systemImage: "info.circle"
            )
        }
        .onAppear {
            hardware = tuner.detectHardwareProfile()
            vmnetStatus = orchestrator.nativeVMNetStatus()
        }
    }
}

extension UnifiedPerformanceView {
    private var hardwareAndRecommendationSection: some View {
        AppSection {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hardware.chipName).font(.headline)
                    Text(
                        """
                        \(hardware.totalCores) 核 CPU · \(hardware.physicalMemoryGiB) GB 内存 · \
                        \(hardware.displayRefreshRateHz) Hz
                        """
                    )
                        .font(.caption).foregroundStyle(.secondary)
                    Text("约 11 秒检测 CPU 与磁盘表现，生成资源建议。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } trailing: {
                Button(action: runAutoTuneBenchmark) {
                    HStack(spacing: 6) {
                        if isBenchmarking { ProgressView().controlSize(.small) }
                        Text(isBenchmarking ? "正在检测…" : "检测资源建议")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isBenchmarking)
            }
            if isBenchmarking {
                ProgressView(value: benchmarkProgress, total: 1).progressViewStyle(.linear)
            }
            if let recommendation = latestRecommendation {
                Divider()
                let resources = preferences.recommendedResources(for: recommendation)
                AppAdaptiveRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("推荐「\(recommendation.recommendedTier.displayName)」").font(.subheadline.weight(.medium))
                        Text(
                            """
                            \(resources.virtualCPUCount) vCPU / \(resources.memoryMiB / 1024) GiB 内存 · \
                            评分 \(Int(recommendation.benchmarkScore))
                            """
                        )
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } trailing: {
                    Button("应用资源建议") {
                        preferences.apply(recommendation: recommendation)
                        appliedBannerText = "资源建议已保存，将在完全退出容器引擎后重新打开时应用。"
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let banner = appliedBannerText {
                AppStatusLabel(text: banner, systemImage: "checkmark.circle", tint: .green)
            }
        }
    }

    private var resourceSection: some View {
        AppSection(
            title: preferences.hasCustomPerformanceSettings ? "容器资源 · 自定义" : "容器资源",
            subtitle: "资源预设只调整 CPU 与内存配额，不改变游戏画质。"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { presetButtons }
                VStack(spacing: 8) { presetButtons }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("内存配额").font(.subheadline.weight(.medium))
                Text(preferences.hasMemoryOverride ? "已保存，正常关闭容器后应用。" : "当前沿用运行环境配置。")
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.hasMemoryOverride && !safeMemoryOptions.contains(preferences.selectedMemoryGiB) {
                    AppStatusLabel(
                        text: "原配额不受当前环境支持，请重新选择或恢复运行环境配置。",
                        systemImage: "exclamationmark.triangle", tint: .orange
                    )
                }
                HStack(spacing: 8) {
                    ForEach(safeMemoryOptions, id: \.self) { memoryGiB in
                        MemoryTierOptionButton(
                            memoryGiB: memoryGiB,
                            isRecommended: memoryGiB == recommendedMemoryGiB,
                            isSelected: preferences.hasMemoryOverride && preferences.selectedMemoryGiB == memoryGiB,
                            onSelect: { preferences.selectedMemoryGiB = memoryGiB }
                        )
                    }
                }
            }
        }
    }

    private var presetButtons: some View {
        ForEach(PerformancePresetTier.allCases, id: \.self) { tier in
            PerformanceTierOptionCard(
                tier: tier,
                isSelected: !preferences.hasCustomPerformanceSettings
                    && (preferences.hasMemoryOverride || preferences.hasCPUOverride)
                    && preferences.selectedTier == tier,
                onSelect: { preferences.applyPreset(tier, hardware: hardware) }
            )
        }
    }

    private var displayOptionsSection: some View {
        AppSection(title: "显示") {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("容器输出分辨率").font(.subheadline)
                    Text("自动模式保留运行环境当前设置。").font(.caption).foregroundStyle(.secondary)
                }
            } trailing: {
                Picker("容器输出分辨率", selection: $preferences.displayModeRaw) {
                    Text("自动").tag("automatic")
                    Text("固定").tag("fixed")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if preferences.displayModeRaw == "fixed" {
                AppAdaptiveRow {
                    Text("输出尺寸").font(.subheadline)
                } trailing: {
                    Picker("输出尺寸", selection: $preferences.recommendedResolution) {
                        ForEach(resolutionOptions, id: \.self) { resolution in
                            Text(resolution.replacingOccurrences(of: "x", with: " × ")).tag(resolution)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }
                Text("启动时验证显示驱动是否支持该尺寸；游戏内部渲染分辨率仍由游戏决定。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("原生转译游戏请在游戏内调整分辨率。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resolutionOptions: [String] {
        var options = ["1280x720", "1280x800", "1920x1080", "1920x1200", "2560x1440", "2560x1600", "3840x2160"]
        if UnifiedDisplayPolicy.fixedResolution(preferences.recommendedResolution) != nil,
           !options.contains(preferences.recommendedResolution) { options.append(preferences.recommendedResolution) }
        return options
    }

    private var compatibilityOptionsSection: some View {
        AppSection(title: "兼容与输入") {
            AppToggleRow(
                title: "高回报率鼠标传输优化",
                detail: "改善容器内高频鼠标输入的传输稳定性，策略由内核管理。",
                isOn: $preferences.enableMouseCoalescing
            )
            Divider()
            AppToggleRow(
                title: "全屏防误触保护",
                detail: "在容器全屏时保护关闭、退出、隐藏和最小化快捷键。",
                isOn: $preferences.blockAccidentalShortcuts
            )
            Divider()
            AppToggleRow(
                title: "屏蔽左 Command 触发开始菜单",
                isOn: $preferences.enableKeyMapping
            )
            Divider()
            AppToggleRow(
                title: "持久化着色器缓存",
                detail: "减少重复编译；关闭不会删除已有的 DXMT / DXVK 缓存。",
                isOn: $preferences.enablePersistentCache
            )
        }
    }

    private var advancedOptionsSection: some View {
        AppSection {
            DisclosureGroup("高级选项", isExpanded: $showAdvancedOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    AppAdaptiveRow {
                        Text("容器 vCPU").font(.subheadline)
                    } trailing: {
                        Picker("容器 vCPU", selection: Binding(
                            get: { preferences.hasCPUOverride ? preferences.recommendedVCPU : 0 },
                            set: { preferences.setVirtualCPUCount($0) }
                        )) {
                            Text("沿用运行环境配置").tag(0)
                            ForEach(safeVCPUOptions, id: \.self) { cores in Text("\(cores) 核").tag(cores) }
                            if preferences.hasCPUOverride && !safeVCPUOptions.contains(preferences.recommendedVCPU) {
                                Text("旧配置需重新选择").tag(preferences.recommendedVCPU).disabled(true)
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    Button("恢复运行环境的资源配置") { preferences.clearResourceOverrides() }
                        .disabled(!preferences.hasMemoryOverride && !preferences.hasCPUOverride)
                    Text("资源更改仅在正常关闭容器后更新；从挂起恢复或仅重启游戏不会修改配额。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    vmnetDirectRow
                    Divider()
                    performanceTelemetrySection
                }
                .padding(.top, 16)
            }
            .font(.subheadline.weight(.medium))
        }
    }

    private var performanceTelemetrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppToggleRow(
                title: "开启游戏 FPS 与性能遥测日志采集（用于迭代分析）",
                detail: "启动游戏后自动只读记录 FPS、Work/Slack/Slop 卡顿归因、宿主机分进程 CPU/内存、网络与缓存增量，已自动脱敏路径，不注入或修改游戏进程。",
                isOn: $preferences.enablePerformanceTelemetryLogging
            )
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("遥测日志目录").font(.subheadline)
                    let latest = orchestrator.latestTelemetryLogURL ?? GameTelemetryCollector.latestTelemetryLogURL()
                    Text(latest.map { "最近记录：\($0.lastPathComponent)" } ?? "开启后启动游戏将自动生成 JSON 报告（每 30 秒落盘）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } trailing: {
                Button("打开日志目录") {
                    let directory = GameTelemetryCollector.telemetryLogsDirectoryURL()
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var vmnetDirectRow: some View {
        AppAdaptiveRow {
            VStack(alignment: .leading, spacing: 4) {
                Text("原生网络直通").font(.subheadline)
                AppStatusLabel(
                    text: vmnetStatus.statusSummary,
                    systemImage: vmnetStatus.socketActive ? "checkmark.circle" : "info.circle",
                    tint: vmnetStatus.socketActive ? .green : .secondary
                )
            }
        } trailing: {
            Button(vmnetStatus.socketActive ? "刷新状态" : "打开系统授权") {
                if vmnetStatus.socketActive {
                    vmnetStatus = orchestrator.nativeVMNetStatus()
                } else {
                    UnifiedPreferencesModel.openVMNetSystemAuthorization()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    func runAutoTuneBenchmark() {
        isBenchmarking = true
        benchmarkProgress = 0.08
        appliedBannerText = nil
        let progressTask = Task {
            for step in 1...18 {
                try? await Task.sleep(for: .milliseconds(550))
                if Task.isCancelled { return }
                await MainActor.run { benchmarkProgress = min(0.92, Double(step) * 0.05) }
            }
        }
        Task {
            let recommendation = await tuner.runQuickBenchmarkAndRecommend()
            progressTask.cancel()
            await MainActor.run {
                benchmarkProgress = 1.0
                latestRecommendation = recommendation
                appliedBannerText = "已生成建议，当前设置未更改。"
                isBenchmarking = false
            }
        }
    }
}

private struct MemoryTierOptionButton: View {
    let memoryGiB: Int
    let isRecommended: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Text("\(memoryGiB) GiB").font(.subheadline.weight(.medium))
                if isRecommended { Text("推荐").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 34).padding(.vertical, 10)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(memoryGiB) GiB\(isRecommended ? "，推荐" : "")")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct PerformanceTierOptionCard: View {
    let tier: PerformancePresetTier
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tier.displayName).font(.subheadline.weight(.medium))
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(minWidth: 172, maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var subtitle: String {
        switch tier {
        case .maxPerformance: return "更高的 CPU 与内存配额"
        case .balanced: return "为 macOS 保留资源余量"
        case .lowSpecCompatible: return "减少容器资源占用"
        }
    }
}
