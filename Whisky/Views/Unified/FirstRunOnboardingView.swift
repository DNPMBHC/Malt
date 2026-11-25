// SPDX-License-Identifier: GPL-3.0-or-later
// Zero-friction 3-step first-run onboarding wizard for Malt unified frontend.

import SwiftUI
import WhiskyKit

struct FirstRunOnboardingView: View {
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    @ObservedObject var preferences: UnifiedPreferencesModel
    @Binding var isPresented: Bool
    let onOpenWineSetup: () -> Void

    @State private var currentStep: Int = 1
    @State private var hardware: HardwareProfileSnapshot = HardwareAutoTuner().detectHardwareProfile()
    @State private var healthMap: [String: Bool] = [:]
    @State private var isCalibrating: Bool = false
    @State private var calibrationProgress: Double = 0
    @State private var recommendation: AutoTuneRecommendation?

    private let tuner = HardwareAutoTuner()

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            Group {
                switch currentStep {
                case 1:
                    stepOneHardwareView
                case 2:
                    stepTwoRuntimeView
                default:
                    stepThreeCalibrationView
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footerButtons
        }
        .frame(width: 600, height: 430)
        .onAppear {
            hardware = tuner.detectHardwareProfile()
            healthMap = orchestrator.healthStatus()
            if preferences.preferredStoragePath.isEmpty {
                preferences.preferredStoragePath = hardware.recommendedStoragePath
            }
        }
    }

    private var stepHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 Malt")
                    .font(.title3.bold())
                Text("3 步零门槛自动适配，即刻开启双模式游戏体验")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("步骤 \(currentStep) / 3")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var stepOneHardwareView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("第 1 步：自动硬件体检与高速存储推荐", systemImage: "cpu.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "处理器芯片", value: hardware.chipName)
                infoRow(
                    label: "核心架构",
                    value: "\(hardware.totalCores) 核"
                        + "（\(hardware.performanceCores)P + \(hardware.efficiencyCores)E）"
                )
                infoRow(label: "统一内存", value: "\(hardware.physicalMemoryGiB) GB")
                infoRow(label: "显示器刷新率", value: "\(hardware.displayRefreshRateHz) Hz")
                infoRow(label: "推荐高速存储目录", value: hardware.recommendedStoragePath)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Text("系统已自动优先检测外置高速 SSD；进入应用后可随时在「环境与存储」中修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stepTwoRuntimeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("第 2 步：一键确认双引擎运行底座", systemImage: "checkmark.shield.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                runtimeStatusRow(
                    title: "原生转译模式引擎（Malt Runtime）",
                    ready: healthMap["wine_ready"] ?? false
                )
                Divider()
                runtimeStatusRow(
                    title: "硬件加速容器模式（无桌面应用壳）",
                    ready: healthMap["anti_cheat_vm_ready"] ?? false
                )
                Divider()
                runtimeStatusRow(
                    title: "统一游戏库持久化存储",
                    ready: healthMap["library_store_writable"] ?? false
                )
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            if !(healthMap["wine_ready"] ?? false) {
                Button("安装 Malt 运行时…") {
                    onOpenWineSetup()
                }
                .buttonStyle(.bordered)
            }
            Text("点击下一步即可进行自动性能校准；未就绪的组件也可稍后在「环境与存储」中一键补齐。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stepThreeCalibrationView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("第 3 步：15 秒自动性能校准并套用最优配置", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)

            if isCalibrating {
                VStack(alignment: .leading, spacing: 10) {
                    Text("正在评估多核 CPU 调度与高速存储吞吐…")
                        .font(.subheadline)
                    ProgressView(value: calibrationProgress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text("校准完成后将自动套用推荐画质档位、游戏模式与防误触保护。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else if let rec = recommendation {
                VStack(alignment: .leading, spacing: 8) {
                    Label("校准完成，已自动套用最优配置！", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    infoRow(label: "推荐性能档位", value: rec.recommendedTier.displayName)
                    infoRow(
                        label: "推荐算力配额",
                        value: "\(rec.recommendedVCPU) vCPU / \(rec.recommendedRAMMiB / 1024) GB RAM"
                    )
                    infoRow(label: "推荐分辨率", value: rec.recommendedResolution)
                    infoRow(label: "校准得分", value: "\(Int(rec.benchmarkScore)) 分")
                }
                .padding(14)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("运行一次约 11 秒的轻量微基准，自动匹配最适合本机的帧率与输入优化参数。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("开始自动性能校准", action: startCalibration)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            if currentStep > 1 {
                Button("上一步") {
                    currentStep -= 1
                }
                .disabled(isCalibrating)
            } else {
                Button("稍后再说") {
                    preferences.hasCompletedOnboarding = true
                    isPresented = false
                }
            }
            Spacer()
            if currentStep < 3 {
                Button("下一步") {
                    currentStep += 1
                    if currentStep == 2 {
                        healthMap = orchestrator.healthStatus()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("进入游戏库") {
                    preferences.hasCompletedOnboarding = true
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCalibrating)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
    }

    private func runtimeStatusRow(title: String, ready: Bool) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(ready ? .green : .orange)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(ready ? "已就绪" : "稍后配置")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ready ? .green : .orange)
        }
    }

    private func startCalibration() {
        isCalibrating = true
        calibrationProgress = 0.08
        let progressTask = Task {
            for step in 1...18 {
                try? await Task.sleep(for: .milliseconds(550))
                if Task.isCancelled { return }
                await MainActor.run {
                    calibrationProgress = min(0.92, Double(step) * 0.05)
                }
            }
        }
        Task {
            let rec = await tuner.runQuickBenchmarkAndRecommend()
            progressTask.cancel()
            await MainActor.run {
                calibrationProgress = 1.0
                recommendation = rec
                preferences.apply(recommendation: rec)
                isCalibrating = false
            }
        }
    }
}
