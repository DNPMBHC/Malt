// SPDX-License-Identifier: GPL-3.0-or-later
// Unified runtime health, external SSD storage, shader cache, and legacy Bottle disclosure view.

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
    @State private var hardware: HardwareProfileSnapshot = HardwareAutoTuner().detectHardwareProfile()
    @State private var shaderCacheSizeLabel: String = "计算中…"
    @State private var showLegacyBottles: Bool = false
    @State private var selectedLegacyBottleURL: URL?
    @State private var statusBanner: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                runtimeHealthCard
                storageAndCacheCard
                onboardingAndSetupCard
                legacyBottlesDisclosure
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshDiagnostics()
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("环境与存储")
                    .font(.title2.bold())
                Text("统一监控 Wine 转译引擎、反作弊安全底座、外置高速存储与着色器缓存")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                refreshDiagnostics()
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var runtimeHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("运行底座健康状态")
                .font(.headline)
            healthRow(
                title: "Wine 转译引擎（WhiskyWine）",
                isReady: healthMap["wine_ready"] ?? false,
                readyText: "已就绪",
                missingText: "未安装"
            )
            Divider()
            healthRow(
                title: "反作弊安全沙盒底座（UTM-Custom / UTM）",
                isReady: healthMap["anti_cheat_vm_ready"] ?? false,
                readyText: "可用",
                missingText: "待部署"
            )
            Divider()
            healthRow(
                title: "统一游戏库存储目录",
                isReady: healthMap["library_store_writable"] ?? false,
                readyText: "可读写",
                missingText: "不可写"
            )
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func healthRow(
        title: String,
        isReady: Bool,
        readyText: String,
        missingText: String
    ) -> some View {
        HStack {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(isReady ? readyText : missingText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isReady ? .green : .orange)
        }
    }

    private var storageAndCacheCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外置高速存储与着色器缓存")
                .font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("推荐高速存储路径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(resolvedStoragePath)
                        .font(.subheadline.monospaced())
                        .lineLimit(2)
                }
                Spacer()
                Button("更改目录…", action: pickStorageDirectory)
                    .buttonStyle(.bordered)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("着色器缓存占用（D3DMetal / DXMT）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(shaderCacheSizeLabel)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Button("清理着色器缓存", role: .destructive) {
                    WhiskyApp.killBottles()
                    WhiskyApp.wipeShaderCaches()
                    statusBanner = "已清理着色器缓存并重置活跃 Wine 进程。"
                    refreshDiagnostics()
                }
                .buttonStyle(.bordered)
            }
            if let banner = statusBanner {
                Label(banner, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var onboardingAndSetupCard: some View {
        HStack(spacing: 12) {
            Button(action: onTriggerOnboarding) {
                Label("重新运行首次 3 步引导", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)

            Button(action: onOpenSetup) {
                Label("打开 Wine 运行时安装向导", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private var legacyBottlesDisclosure: some View {
        DisclosureGroup("高级：传统 Wine 容器（Bottle）管理（向后兼容）", isExpanded: $showLegacyBottles) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("已发现 \(bottleVM.bottles.count) 个传统容器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
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
                        HStack {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.secondary)
                            Text(bottle.settings.name)
                                .font(.subheadline)
                            Spacer()
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
            .padding(.top, 10)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var resolvedStoragePath: String {
        preferences.preferredStoragePath.isEmpty ? hardware.recommendedStoragePath : preferences.preferredStoragePath
    }

    private func pickStorageDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            preferences.preferredStoragePath = url.path(percentEncoded: false)
        }
    }

    private func refreshDiagnostics() {
        hardware = HardwareAutoTuner().detectHardwareProfile()
        healthMap = orchestrator.healthStatus()
        shaderCacheSizeLabel = Self.computeShaderCacheSizeLabel()
    }

    private static func computeShaderCacheSizeLabel() -> String {
        let fileManager = FileManager.default
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dxmtCache = cachesDir?.appending(path: "dxmt-shader-cache")
        var totalBytes: Int64 = 0
        if let dxmtCache, fileManager.fileExists(atPath: dxmtCache.path(percentEncoded: false)) {
            totalBytes += directoryByteSize(at: dxmtCache, fileManager: fileManager)
        }
        if totalBytes <= 0 {
            return "约 0 MB（干净状态）"
        }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private static func directoryByteSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize {
                total += Int64(fileSize)
            }
        }
        return total
    }
}
