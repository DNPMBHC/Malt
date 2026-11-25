// SPDX-License-Identifier: GPL-3.0-or-later
// Unified game library grid blending native Wine and Anti-Cheat VM titles.

import AppKit
import SwiftUI
import WhiskyKit

struct UnifiedGameLibraryView: View {
    @ObservedObject var libraryStore: UnifiedGameLibraryStore
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    let onOpenInstaller: () -> Void

    @State private var searchText: String = ""
    @State private var engineFilter: UnifiedEngineKind?
    @State private var launchErrorMessage: String?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 16)
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
        VStack(spacing: 0) {
            headerBar
            Divider()
            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(filteredEntries) { entry in
                            UnifiedGameCard(
                                entry: entry,
                                isLaunching: orchestrator.activeEntryID == entry.id,
                                onLaunch: { launchGame(entry) },
                                onSelectTier: { tier in updateTier(for: entry, tier: tier) },
                                onRevealInFinder: { revealInFinder(entry) },
                                onRemove: { libraryStore.remove(id: entry.id) }
                            )
                        }
                    }
                    .padding(20)
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

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("游戏库")
                    .font(.title2.bold())
                Text("普通转译与反作弊安全沙盒游戏统一入口，点击即玩")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("引擎筛选", selection: $engineFilter) {
                Text("全部").tag(UnifiedEngineKind?.none)
                Text("原生转译").tag(UnifiedEngineKind?.some(.nativeWine))
                Text("反作弊安全模式").tag(UnifiedEngineKind?.some(.antiCheatVM))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            TextField("搜索游戏…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "gamecontroller")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text(libraryStore.entries.isEmpty ? "游戏库暂无已安装游戏" : "未找到匹配的游戏")
                .font(.title3.weight(.semibold))
            Text("拖入 .exe 或 .msi 安装包，系统将自动识别并配置最合适的运行引擎。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                onOpenInstaller()
            } label: {
                Label("前往一键安装", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func launchGame(_ entry: UnifiedGameEntry) {
        Task {
            do {
                try await orchestrator.launch(entry: entry)
            } catch {
                await MainActor.run {
                    launchErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateTier(for entry: UnifiedGameEntry, tier: PerformancePresetTier) {
        var updated = entry
        updated.presetTier = tier
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
    let onSelectTier: (PerformancePresetTier) -> Void
    let onRevealInFinder: () -> Void
    let onRemove: () -> Void

    private var engineBadgeTitle: String {
        entry.engineKind == .antiCheatVM ? "反作弊安全模式" : "原生转译"
    }

    private var engineBadgeColor: Color {
        entry.engineKind == .antiCheatVM ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                gameIconView
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(engineBadgeTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(engineBadgeColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(engineBadgeColor)
                        Text(entry.presetTier.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack {
                if let lastPlayed = entry.lastPlayedAt {
                    Text("上次游玩：\(lastPlayed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("尚未运行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button(action: onLaunch) {
                HStack {
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isLaunching ? "正在启动…" : "开始游戏")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLaunching)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contextMenu {
            Menu("切换性能档") {
                ForEach(PerformancePresetTier.allCases, id: \.self) { tier in
                    Button {
                        onSelectTier(tier)
                    } label: {
                        if entry.presetTier == tier {
                            Label(tier.displayName, systemImage: "checkmark")
                        } else {
                            Text(tier.displayName)
                        }
                    }
                }
            }
            Button("在访达中显示", action: onRevealInFinder)
            Divider()
            Button("从游戏库移除", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private var gameIconView: some View {
        if let iconPath = entry.iconPath,
           let nsImage = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(engineBadgeColor.opacity(0.15))
                Image(systemName: entry.engineKind == .antiCheatVM ? "shield.lefthalf.filled" : "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(engineBadgeColor)
            }
            .frame(width: 44, height: 44)
        }
    }
}
