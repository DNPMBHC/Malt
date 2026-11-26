// SPDX-License-Identifier: GPL-3.0-or-later

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
    @State private var resolvedPaths: ResolvedRuntimePaths?
    @State private var isCalibrating: Bool = false
    @State private var calibrationProgress: Double = 0
    @State private var recommendation: AutoTuneRecommendation?
    @State private var didApplyRecommendation = false

    private let tuner = HardwareAutoTuner()

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            ScrollView {
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footerButtons
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 720,
               minHeight: 420, idealHeight: 480, maxHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            hardware = tuner.detectHardwareProfile()
            refreshRuntimeState()
        }
    }

    private var stepHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("快速设置")
                    .font(.title2.weight(.semibold))
                Text("检查运行环境，按需保存资源建议。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("\(currentStep) / 3")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("第 \(currentStep) 步，共 3 步")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var stepOneHardwareView: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSection(title: "硬件概览") {
                infoRow(label: "处理器", value: hardware.chipName)
                infoRow(
                    label: "核心架构",
                    value: "\(hardware.totalCores) 核（\(hardware.performanceCores)P + \(hardware.efficiencyCores)E）"
                )
                infoRow(label: "统一内存", value: "\(hardware.physicalMemoryGiB) GB")
                infoRow(label: "显示刷新率", value: "\(hardware.displayRefreshRateHz) Hz")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("建议存储位置")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(hardware.recommendedStoragePath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("存储位置仅供参考，不会移动现有游戏或修改运行环境。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepTwoRuntimeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSection(title: "运行组件与受管容器") {
                runtimeStatusRow(title: "原生转译组件", ready: healthMap["wine_ready"] ?? false)
                Divider()
                runtimeStatusRow(title: "游戏库存储", ready: healthMap["library_store_writable"] ?? false)
                if !(healthMap["wine_ready"] ?? false) {
                    Button("安装原生运行组件…", action: onOpenWineSetup)
                        .buttonStyle(.bordered)
                }
                Divider()
                ContainerProvisioningPanel(
                    orchestrator: orchestrator,
                    preferences: preferences,
                    healthMap: healthMap,
                    resolvedPaths: resolvedPaths,
                    onContainerChanged: refreshRuntimeState
                )
            }
            Text("组件已打包不代表 Windows 系统已就绪；未就绪的组件可稍后在“环境与存储”中配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepThreeCalibrationView: some View {
        AppSection(title: "资源建议") {
            if isCalibrating {
                Text("正在检测 CPU 与存储表现…")
                    .font(.subheadline)
                ProgressView(value: calibrationProgress, total: 1.0)
                    .progressViewStyle(.linear)
                Text("检测完成后会展示建议，点击应用才会保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let rec = recommendation {
                let resources = preferences.recommendedResources(for: rec)
                AppStatusLabel(
                    text: didApplyRecommendation ? "推荐配额已保存" : "建议已生成",
                    systemImage: "checkmark.circle", tint: .green
                )
                infoRow(label: "性能档位", value: rec.recommendedTier.displayName)
                infoRow(
                    label: "资源配额",
                    value: "\(resources.virtualCPUCount) vCPU · \(resources.memoryMiB / 1024) GiB RAM"
                )
                infoRow(label: "检测得分", value: "\(Int(rec.benchmarkScore)) 分")
                Button(didApplyRecommendation ? "已应用推荐配额" : "应用推荐配额") {
                    preferences.apply(recommendation: rec)
                    didApplyRecommendation = true
                }
                .buttonStyle(.bordered)
                .disabled(didApplyRecommendation)
                Text("正常关闭 Windows 并完全退出容器引擎后重新打开，资源配额才会生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("运行约 11 秒的轻量检测，生成 CPU 与内存配额建议。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("检测并生成建议", action: startCalibration)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            if currentStep > 1 {
                Button("上一步") { currentStep -= 1 }
                    .disabled(isCalibrating)
            } else {
                Button("稍后设置") {
                    preferences.hasCompletedOnboarding = true
                    isPresented = false
                }
            }
            Spacer(minLength: 16)
            if currentStep < 3 {
                Button("下一步") {
                    currentStep += 1
                    if currentStep == 2 { refreshRuntimeState() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("进入游戏库") {
                    preferences.hasCompletedOnboarding = true
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCalibrating)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func runtimeStatusRow(title: String, ready: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            AppStatusLabel(
                text: ready ? "已就绪" : "待配置",
                systemImage: ready ? "checkmark.circle" : "circle.dashed",
                tint: ready ? .green : .secondary
            )
            .fixedSize()
        }
    }

    private func refreshRuntimeState() {
        healthMap = orchestrator.healthStatus()
        resolvedPaths = orchestrator.resolvedRuntimePaths()
    }

    private func startCalibration() {
        isCalibrating = true
        didApplyRecommendation = false
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
                isCalibrating = false
            }
        }
    }
}
