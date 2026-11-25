// SPDX-License-Identifier: GPL-3.0-or-later
// Performance presets, hardware profile snapshot, and one-click auto-tuning view.

import SwiftUI
import WhiskyKit

struct UnifiedPerformanceView: View {
    @ObservedObject var preferences: UnifiedPreferencesModel

    @State private var hardware: HardwareProfileSnapshot = HardwareAutoTuner().detectHardwareProfile()
    @State private var latestRecommendation: AutoTuneRecommendation?
    @State private var isBenchmarking: Bool = false
    @State private var benchmarkProgress: Double = 0
    @State private var showAdvancedOptions: Bool = false
    @State private var appliedBannerText: String?

    private let tuner = HardwareAutoTuner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                hardwareProfileCard
                autoTuneCard
                presetTierSection
                coreSwitchesCard
                advancedOptionsSection
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            hardware = tuner.detectHardwareProfile()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("性能与智能适配")
                .font(.title2.bold())
            Text("自动识别 Apple Silicon 算力与内存，一键校准帧率与输入响应")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var hardwareProfileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本机硬件画像", systemImage: "cpu.fill")
                .font(.headline)
            HStack(spacing: 16) {
                hardwareMetricTile(title: "芯片", value: hardware.chipName)
                hardwareMetricTile(
                    title: "CPU 核心",
                    value: "\(hardware.totalCores) 核（\(hardware.performanceCores)P + \(hardware.efficiencyCores)E）"
                )
                hardwareMetricTile(title: "统一内存", value: "\(hardware.physicalMemoryGiB) GB")
                hardwareMetricTile(title: "屏幕刷新率", value: "\(hardware.displayRefreshRateHz) Hz")
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func hardwareMetricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var autoTuneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("智能性能校准")
                        .font(.headline)
                    Text("约 11 秒完成多核与磁盘微基准，自动生成最优档位与输入参数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: runAutoTuneBenchmark) {
                    HStack(spacing: 6) {
                        if isBenchmarking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isBenchmarking ? "正在测速优化…" : "自动性能测试并优化")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBenchmarking)
            }

            if isBenchmarking {
                ProgressView(value: benchmarkProgress, total: 1.0)
                    .progressViewStyle(.linear)
            }

            if let rec = latestRecommendation {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "综合评分 \(Int(rec.benchmarkScore)) · 推荐「\(rec.recommendedTier.displayName)」"
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(
                            "\(rec.recommendedVCPU) vCPU / \(rec.recommendedRAMMiB / 1024) GB RAM / "
                                + "\(rec.recommendedResolution)（耗时 \(String(format: "%.1f", rec.durationSeconds))s）"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("套用推荐配置") {
                        preferences.apply(recommendation: rec)
                        appliedBannerText = "已套用「\(rec.recommendedTier.displayName)」推荐配置。"
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            if let banner = appliedBannerText {
                Label(banner, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var presetTierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("三档性能模式")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(PerformancePresetTier.allCases, id: \.self) { tier in
                    PerformanceTierOptionCard(
                        tier: tier,
                        isSelected: preferences.selectedTier == tier,
                        onSelect: { preferences.selectedTier = tier }
                    )
                }
            }
        }
    }

    private var coreSwitchesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核心体验开关")
                .font(.headline)
            Toggle("启用 macOS 游戏模式（全屏自动优先调度 GPU / CPU）", isOn: $preferences.enableGameMode)
            Divider()
            Toggle("启用高回报率电竞鼠标无损合批（降低高 Hz 中断抖动）", isOn: $preferences.enableMouseCoalescing)
            Divider()
            Toggle("游戏全屏防误触屏蔽（拦截 Cmd+W / Cmd+Q / Cmd+H / Cmd+M）", isOn: $preferences.blockAccidentalShortcuts)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var advancedOptionsSection: some View {
        DisclosureGroup("高级选项（底层算力与输入参数）", isExpanded: $showAdvancedOptions) {
            VStack(alignment: .leading, spacing: 12) {
                Stepper(
                    "虚拟 CPU 核心数：\(preferences.recommendedVCPU) vCPU",
                    value: $preferences.recommendedVCPU,
                    in: 2...max(4, hardware.totalCores)
                )
                Stepper(
                    "沙盒内存配额：\(preferences.recommendedRAMMiB) MiB",
                    value: $preferences.recommendedRAMMiB,
                    in: 4096...max(8192, hardware.physicalMemoryGiB * 1024),
                    step: 1024
                )
                Stepper(
                    "鼠标合批窗口：\(preferences.mouseCoalesceMicros) μs",
                    value: $preferences.mouseCoalesceMicros,
                    in: 0...4000,
                    step: 250
                )
                HStack {
                    Text("目标渲染分辨率")
                    Spacer()
                    Picker("分辨率", selection: $preferences.recommendedResolution) {
                        Text("1280x720").tag("1280x720")
                        Text("1920x1080").tag("1920x1080")
                        Text("2560x1440").tag("2560x1440")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func runAutoTuneBenchmark() {
        isBenchmarking = true
        benchmarkProgress = 0.08
        appliedBannerText = nil

        let progressTask = Task {
            for step in 1...18 {
                try? await Task.sleep(for: .milliseconds(550))
                if Task.isCancelled { return }
                await MainActor.run {
                    benchmarkProgress = min(0.92, Double(step) * 0.05)
                }
            }
        }

        Task {
            let recommendation = await tuner.runQuickBenchmarkAndRecommend()
            progressTask.cancel()
            await MainActor.run {
                benchmarkProgress = 1.0
                latestRecommendation = recommendation
                preferences.apply(recommendation: recommendation)
                appliedBannerText = "校准完成并已自动套用「\(recommendation.recommendedTier.displayName)」配置。"
                isBenchmarking = false
            }
        }
    }
}

private struct PerformanceTierOptionCard: View {
    let tier: PerformancePresetTier
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tier.displayName)
                        .font(.headline)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        switch tier {
        case .competitiveHighFPS:
            return "最低输入延迟与最高帧率，适合 FPS 与竞技网游"
        case .balancedRecommended:
            return "画质与稳帧兼顾，默认推荐日常畅玩"
        case .nativeQuality:
            return "高分辨率与清晰画质优先，适合大内存机型"
        }
    }
}
