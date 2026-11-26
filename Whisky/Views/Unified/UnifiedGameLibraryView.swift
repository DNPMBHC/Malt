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
        AppPage(title: "游戏库", subtitle: "管理已添加的游戏与运行设置。") {
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
                        UnifiedGameCard(
                            entry: entry,
                            isLaunching: orchestrator.activeEntryID == entry.id,
                            onLaunch: { launchGame(entry) },
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
        .alert("启动失败", isPresented: Binding(
            get: { launchErrorMessage != nil },
            set: { if !$0 { launchErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { launchErrorMessage = nil }
        } message: {
            Text(launchErrorMessage ?? "")
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

    private func launchGame(_ entry: UnifiedGameEntry) {
        let settings = preferences.runtimeSettings
        Task {
            do {
                try await orchestrator.launch(entry: entry, settings: settings)
            } catch {
                await MainActor.run {
                    launchErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func configureExecutable(for entry: UnifiedGameEntry) {
        let path: String
        if entry.engineKind == .antiCheatVM {
            let alert = NSAlert()
            alert.messageText = "设置游戏主程序"
            alert.informativeText = "请在安装完成后填写容器内游戏 .exe 的 Windows 完整路径。"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            field.placeholderString = #"C:\Games\Game\game.exe"#
            if entry.installationState != .installerRequested { field.stringValue = entry.executablePath }
            alert.accessoryView = field
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAbsolute = path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
                || path.hasPrefix(#"\\"#)
            guard isAbsolute, path.lowercased().hasSuffix(".exe"),
                  !path.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
                launchErrorMessage = "请输入容器内以盘符或网络共享开头的 .exe 完整路径。"
                return
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "选择已安装游戏的主程序"
            panel.directoryURL = entry.bottleURL?.appending(path: "drive_c")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "exe" else {
                launchErrorMessage = "请选择已安装游戏的 .exe 主程序。"
                return
            }
            path = url.path
        }
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
    let onLaunch: () -> Void
    let onConfigureExecutable: () -> Void
    let onSelectTier: (PerformancePresetTier) -> Void
    let onInheritGlobalSettings: () -> Void
    let onRevealInFinder: () -> Void
    let onRemove: () -> Void

    private var engineTitle: String {
        entry.engineKind == .antiCheatVM ? "硬件加速容器" : "原生转译"
    }

    private var performanceTitle: String {
        if entry.engineKind == .nativeWine { return "性能在游戏内设置" }
        return entry.inheritsGlobalPerformanceSettings != false ? "继承全局设置" : entry.presetTier.displayName
    }

    var body: some View {
        AppSection {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    gameIconView
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        gameActions
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多游戏操作")
                    .accessibilityLabel("更多游戏操作")
                }

                VStack(alignment: .leading, spacing: 6) {
                    AppStatusLabel(
                        text: engineTitle,
                        systemImage: entry.engineKind == .antiCheatVM ? "square.stack.3d.up" : "cpu"
                    )
                    Text(performanceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.installationState == .installerRequested {
                        AppStatusLabel(text: "待选择游戏主程序", systemImage: "exclamationmark.circle", tint: .orange)
                    }
                }

                Spacer(minLength: 0)

                Text(entry.lastPlayedAt.map { "上次游玩：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button(action: entry.installationState == .installerRequested ? onConfigureExecutable : onLaunch) {
                    HStack(spacing: 8) {
                        if isLaunching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(
                                systemName: entry.installationState == .installerRequested
                                    ? "slider.horizontal.3" : "play.fill"
                            )
                        }
                        Text(
                            isLaunching ? "正在启动…"
                                : (entry.installationState == .installerRequested ? "设置游戏主程序" : "开始游戏")
                        )
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLaunching)
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
        Button("更改游戏主程序…", action: onConfigureExecutable)
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
