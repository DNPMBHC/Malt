// SPDX-License-Identifier: GPL-3.0-or-later
// Unified game library grid blending native translation and hardware-accelerated container titles.

import AppKit
import SwiftUI
import WhiskyKit

struct UnifiedGameLibraryView: View {
    @ObservedObject var libraryStore: UnifiedGameLibraryStore
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    @ObservedObject var preferences: UnifiedPreferencesModel
    let onOpenInstaller: () -> Void

    @State private var searchText: String = ""
    @State private var engineFilter: UnifiedEngineKind?
    @State private var launchErrorMessage: String?
    @State private var discoveryEntry: UnifiedGameEntry?
    @State private var isOpeningContainer: Bool = false

    private let gridColumns = [
        GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .top)
    ]

    private var filteredEntries: [UnifiedGameEntry] {
        libraryStore.entries
            .filter { entry in
                if let filter = engineFilter, entry.engineKind != filter {
                    return false
                }
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                return entry.name.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { lhs, rhs in
                let leftDate = lhs.lastPlayedAt ?? .distantPast
                let rightDate = rhs.lastPlayedAt ?? .distantPast
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        AppPage(title: "游戏库", subtitle: "原生转译游戏可直接启动；兼容反作弊游戏推荐直接打开 Windows 容器并在桌面中运行。") {
            directContainerLaunchBanner
            VirtualUSBTransferCard(orchestrator: orchestrator)
            if !libraryStore.entries.isEmpty { libraryToolbar }

            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                HStack {
                    Text("\(filteredEntries.count) 个游戏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasActiveFilters {
                        Button("清除筛选", action: clearFilters)
                            .buttonStyle(.link)
                    }
                }

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(filteredEntries) { entry in
                        let isEntryLaunching = orchestrator.activeEntryID == entry.id
                        UnifiedGameCard(
                            entry: entry,
                            isLaunching: isEntryLaunching,
                            launchStageText: isEntryLaunching ? launchStageLabel(for: entry) : nil,
                            onLaunch: { launchGame(entry) },
                            onScanExecutable: { discoveryEntry = entry },
                            onConfigureExecutable: { configureExecutable(for: entry) },
                            onSelectTier: { tier in updateTier(for: entry, tier: tier) },
                            onInheritGlobalSettings: { inheritGlobalSettings(for: entry) },
                            onRevealInFinder: { revealInFinder(entry) },
                            onRemove: { libraryStore.remove(id: entry.id) }
                        )
                    }
                }
            }
        }
        .sheet(item: $discoveryEntry) { entry in
            InstalledGameDiscoverySheet(
                entry: entry,
                orchestrator: orchestrator,
                onRegistered: { _ in },
                onManualFallback: { configureExecutable(for: entry) }
            )
        }
        .alert("启动失败", isPresented: Binding(
            get: { launchErrorMessage != nil },
            set: { if !$0 { launchErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { launchErrorMessage = nil }
        } message: {
            Text(launchErrorMessage ?? "")
        }
    }

    private var directContainerLaunchBanner: some View {
        AppSection {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Windows 11 硬件加速容器").font(.headline)
                    Text("直接打开 Windows 桌面并保持 Dock 图标与顶栏可见，在容器内自由启动任意启动器与反作弊游戏。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button(action: openWindowsContainer) {
                    Label(isOpeningContainer ? "正在打开…" : "打开 Windows 容器", systemImage: "desktopcomputer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOpeningContainer)
            }
        }
    }

    private var hasActiveFilters: Bool {
        engineFilter != nil || !searchText.isEmpty
    }

    private var libraryToolbar: some View {
        AppAdaptiveRow {
            TextField("搜索游戏", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索游戏")
                .frame(maxWidth: .infinity)
        } trailing: {
            HStack(spacing: 12) {
                Picker("运行方式", selection: $engineFilter) {
                    Text("全部游戏").tag(UnifiedEngineKind?.none)
                    Text("原生转译").tag(UnifiedEngineKind?.some(.nativeWine))
                    Text("硬件加速容器").tag(UnifiedEngineKind?.some(.antiCheatVM))
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("按运行方式筛选")

                Button(action: onOpenInstaller) {
                    Label("添加游戏", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyStateView: some View {
        AppSection {
            VStack(spacing: 16) {
                Image(systemName: libraryStore.entries.isEmpty ? "gamecontroller" : "magnifyingglass")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(libraryStore.entries.isEmpty ? "添加你的第一款游戏" : "没有匹配的游戏")
                        .font(.headline)
                    Text(libraryStore.entries.isEmpty
                         ? "选择 .exe 或 .msi 安装包，开始配置游戏。"
                         : "试试其他名称，或清除运行方式筛选。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if libraryStore.entries.isEmpty {
                    Button("选择安装包", action: onOpenInstaller)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("清除搜索与筛选", action: clearFilters)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .padding(.vertical, 24)
        }
    }

    private func clearFilters() {
        searchText = ""
        engineFilter = nil
    }

    private func launchStageLabel(for entry: UnifiedGameEntry) -> String {
        let status = orchestrator.lastStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty {
            return InstalledGameDiscoverySection.redactedMessage(status)
        }
        if entry.engineKind == .antiCheatVM {
            return "正在打开 Windows 容器并准备网络…"
        }
        return "正在准备原生转译环境…"
    }

    private func openWindowsContainer() {
        let settings = preferences.runtimeSettings
        isOpeningContainer = true
        Task {
            defer { Task { @MainActor in isOpeningContainer = false } }
            do {
                try await orchestrator.launchWindowsContainer(settings: settings)
            } catch {
                await MainActor.run {
                    launchErrorMessage = InstalledGameDiscoverySection.redactedMessage(error.localizedDescription)
                }
            }
        }
    }

    private func launchGame(_ entry: UnifiedGameEntry) {
        let settings = preferences.runtimeSettings
        Task {
            do {
                if entry.engineKind == .antiCheatVM {
                    try await orchestrator.launchWindowsContainer(entry: entry, settings: settings, title: entry.name)
                } else {
                    try await orchestrator.launch(entry: entry, settings: settings)
                }
            } catch {
                await MainActor.run {
                    launchErrorMessage = InstalledGameDiscoverySection.redactedMessage(error.localizedDescription)
                }
            }
        }
    }

    private func configureExecutable(for entry: UnifiedGameEntry) {
        guard let path = InstalledGameDiscoverySection.promptManualExecutablePath(
            for: entry,
            onError: { launchErrorMessage = $0 }
        ) else { return }
        var updated = entry
        updated.executablePath = path
        updated.installationState = .ready
        libraryStore.upsert(updated)
    }

    private func updateTier(for entry: UnifiedGameEntry, tier: PerformancePresetTier) {
        var updated = entry
        updated.presetTier = tier
        updated.inheritsGlobalPerformanceSettings = false
        libraryStore.upsert(updated)
    }

    private func inheritGlobalSettings(for entry: UnifiedGameEntry) {
        var updated = entry
        updated.inheritsGlobalPerformanceSettings = true
        libraryStore.upsert(updated)
    }

    private func revealInFinder(_ entry: UnifiedGameEntry) {
        let targetPath = entry.executablePath
        if FileManager.default.fileExists(atPath: targetPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: targetPath)])
        } else if let vmPath = entry.vmBundlePath, FileManager.default.fileExists(atPath: vmPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: vmPath)])
        } else if let bottleURL = entry.bottleURL {
            NSWorkspace.shared.activateFileViewerSelecting([bottleURL])
        }
    }
}

private struct UnifiedGameCard: View {
    let entry: UnifiedGameEntry
    let isLaunching: Bool
    let launchStageText: String?
    let onLaunch: () -> Void
    let onScanExecutable: () -> Void
    let onConfigureExecutable: () -> Void
    let onSelectTier: (PerformancePresetTier) -> Void
    let onInheritGlobalSettings: () -> Void
    let onRevealInFinder: () -> Void
    let onRemove: () -> Void

    private var isPendingRegistration: Bool {
        entry.engineKind == .nativeWine && entry.installationState == .installerRequested
    }
    private var engineTitle: String { entry.engineKind == .antiCheatVM ? "硬件加速容器" : "原生转译" }
    private var performanceTitle: String {
        if entry.engineKind == .nativeWine { return "性能在游戏内设置" }
        return entry.inheritsGlobalPerformanceSettings != false ? "继承全局设置" : entry.presetTier.displayName
    }

    var body: some View {
        AppSection {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    gameIconView
                    Text(entry.name).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Menu { gameActions } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("更多游戏操作").accessibilityLabel("更多游戏操作")
                }
                VStack(alignment: .leading, spacing: 6) {
                    AppStatusLabel(
                        text: engineTitle,
                        systemImage: entry.engineKind == .antiCheatVM ? "square.stack.3d.up" : "cpu"
                    )
                    Text(performanceTitle).font(.caption).foregroundStyle(.secondary)
                    if isPendingRegistration {
                        AppStatusLabel(
                            text: "安装器已启动 · 待设置入口", systemImage: "exclamationmark.circle", tint: .orange
                        )
                    } else if isLaunching, let stage = launchStageText {
                        AppStatusLabel(text: stage, systemImage: "play.circle", tint: .accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Text(entry.lastPlayedAt.map { "上次游玩：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未运行")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(action: isPendingRegistration ? onScanExecutable : onLaunch) {
                    HStack(spacing: 8) {
                        if isLaunching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isPendingRegistration ? "magnifyingglass" : "play.fill")
                        }
                        let readyTitle = entry.engineKind == .antiCheatVM ? "打开容器" : "开始游戏"
                        Text(isLaunching ? "启动中…" : (isPendingRegistration ? "扫描游戏入口" : readyTitle))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(isLaunching)
            }
            .frame(maxWidth: .infinity, minHeight: 218, alignment: .topLeading)
        }
        .contextMenu { gameActions }
    }

    @ViewBuilder
    private var gameActions: some View {
        if entry.engineKind == .antiCheatVM {
            Menu("容器性能模式") {
                Button(action: onInheritGlobalSettings) {
                    if entry.inheritsGlobalPerformanceSettings != false {
                        Label("继承全局设置", systemImage: "checkmark")
                    } else {
                        Text("继承全局设置")
                    }
                }
                Divider()
                ForEach(PerformancePresetTier.allCases, id: \.self) { tier in
                    Button {
                        onSelectTier(tier)
                    } label: {
                        if entry.inheritsGlobalPerformanceSettings == false && entry.presetTier == tier {
                            Label(tier.displayName, systemImage: "checkmark")
                        } else {
                            Text(tier.displayName)
                        }
                    }
                }
            }
        }
        if entry.engineKind == .antiCheatVM {
            Button("扫描游戏入口…", action: onScanExecutable)
        }
        Button("手动设置主程序…", action: onConfigureExecutable)
        Button("在访达中显示", action: onRevealInFinder)
        Divider()
        Button("从游戏库移除", role: .destructive, action: onRemove)
    }

    @ViewBuilder
    private var gameIconView: some View {
        if let iconPath = entry.iconPath,
           let nsImage = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "gamecontroller")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }
}
