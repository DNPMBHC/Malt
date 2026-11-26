// SPDX-License-Identifier: GPL-3.0-or-later
// Shared post-install game entry discovery, disambiguation, and verified registration UI.

import AppKit
import SwiftUI
import WhiskyKit

/// Reusable discovery and disambiguation panel shared between the installer and game library.
@MainActor
struct InstalledGameDiscoverySection: View {
    let entry: UnifiedGameEntry
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    let onRegistered: (UnifiedGameEntry) -> Void
    let onManualFallback: () -> Void

    @State private var searchQuery: String
    @State private var candidates: [InstalledGameCandidate] = []
    @State private var selectedCandidateID: String?
    @State private var hasSearched = false
    @State private var isScanning = false
    @State private var isRegistering = false
    @State private var errorMessage: String?

    init(
        entry: UnifiedGameEntry,
        orchestrator: UnifiedRuntimeOrchestrator,
        onRegistered: @escaping (UnifiedGameEntry) -> Void,
        onManualFallback: @escaping () -> Void
    ) {
        self.entry = entry
        self.orchestrator = orchestrator
        self.onRegistered = onRegistered
        self.onManualFallback = onManualFallback
        _searchQuery = State(initialValue: entry.name)
    }

    private var selectedCandidate: InstalledGameCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            keywordAndScanBar

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描容器开始菜单中的游戏入口…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                errorGuidanceView(message: errorMessage)
            } else if hasSearched && candidates.isEmpty {
                emptyCandidatesView
            } else if !candidates.isEmpty {
                candidatesListView
            }
        }
    }

    private var keywordAndScanBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索关键词")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                TextField("输入游戏名或英文关键词，如 VALORANT", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("游戏入口搜索关键词")
                    .disabled(isScanning || isRegistering)
                    .onSubmit(scanCandidates)
                Button(action: scanCandidates) {
                    Label(hasSearched ? "重新扫描" : "扫描游戏入口", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning || isRegistering)
            }
            Text("请先在安装窗口完成安装并保持 Windows 已登录，再点击扫描；系统不会自动替你选中候选。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var candidatesListView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("找到 \(candidates.count) 个候选入口，请点选实际要启动的程序后确认登记：")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 8) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }

            HStack(spacing: 10) {
                Button(action: confirmRegistration) {
                    HStack(spacing: 6) {
                        if isRegistering {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(isRegistering ? "正在核验并登记…" : "确认登记")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidate == nil || isRegistering || isScanning)

                Button("手动选择路径", action: onManualFallback)
                    .buttonStyle(.bordered)
                    .disabled(isRegistering || isScanning)
            }
        }
    }

    private func candidateRow(_ candidate: InstalledGameCandidate) -> some View {
        let isSelected = selectedCandidateID == candidate.id
        return Button {
            selectedCandidateID = candidate.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("程序：\(Self.redactedPath(candidate.executablePath))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if !candidate.arguments.isEmpty {
                        Text("参数：\(candidate.arguments)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !candidate.workingDirectory.isEmpty {
                        Text("目录：\(Self.redactedPath(candidate.workingDirectory))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyCandidatesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("未在开始菜单找到匹配的已安装入口", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text("可能原因：安装尚未完成、关键词与快捷方式名称不一致，或游戏未创建开始菜单快捷方式。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("重新扫描", action: scanCandidates)
                    .buttonStyle(.bordered)
                Button("手动填写/选择路径", action: onManualFallback)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorGuidanceView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("扫描需要所选 Windows 容器已启动、完成桌面登录且来宾工具可用；若暂无快捷方式，可使用手动路径退路。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("重试扫描", action: scanCandidates)
                    .buttonStyle(.bordered)
                Button("手动填写/选择路径", action: onManualFallback)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scanCandidates() {
        isScanning = true
        errorMessage = nil
        candidates = []
        selectedCandidateID = nil
        let keyword = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let found = try await orchestrator.discoverInstalledGameCandidates(
                    for: entry,
                    query: keyword.isEmpty ? nil : keyword
                )
                await MainActor.run {
                    candidates = found
                    hasSearched = true
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    hasSearched = true
                    isScanning = false
                    errorMessage = Self.redactedMessage(error.localizedDescription)
                }
            }
        }
    }

    private func confirmRegistration() {
        guard let candidate = selectedCandidate else { return }
        isRegistering = true
        errorMessage = nil
        Task {
            do {
                let registered = try await orchestrator.registerInstalledGame(entry, candidate: candidate)
                await MainActor.run {
                    isRegistering = false
                    onRegistered(registered)
                }
            } catch {
                await MainActor.run {
                    isRegistering = false
                    errorMessage = Self.redactedMessage(error.localizedDescription)
                }
            }
        }
    }
}

extension InstalledGameDiscoverySection {
    static func redactedPath(_ raw: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return raw }
        return raw.replacingOccurrences(of: home, with: "~")
    }

    static func redactedMessage(_ message: String) -> String {
        redactedPath(message)
    }

    @MainActor
    static func promptManualExecutablePath(
        for entry: UnifiedGameEntry,
        onError: (String) -> Void
    ) -> String? {
        if entry.engineKind == .antiCheatVM {
            let alert = NSAlert()
            alert.messageText = "手动设置游戏主程序"
            alert.informativeText = "仅在自动扫描未找到快捷方式时使用，请填写容器内 .exe 的 Windows 完整路径。"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            field.placeholderString = #"C:\Games\Game\game.exe"#
            if entry.installationState != .installerRequested { field.stringValue = entry.executablePath }
            alert.accessoryView = field
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAbsolute = path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
                || path.hasPrefix(#"\\"#)
            guard isAbsolute, path.lowercased().hasSuffix(".exe"),
                  !path.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
                onError("请输入容器内以盘符或网络共享开头的 .exe 完整路径。")
                return nil
            }
            return path
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "选择已安装游戏的主程序"
        panel.directoryURL = entry.bottleURL?.appending(path: "drive_c")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.pathExtension.lowercased() == "exe" else {
            onError("请选择已安装游戏的 .exe 主程序。")
            return nil
        }
        return url.path
    }
}

/// Modal wrapper used from the Game Library when registering a pending game entry.
@MainActor
struct InstalledGameDiscoverySheet: View {
    let entry: UnifiedGameEntry
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    let onRegistered: (UnifiedGameEntry) -> Void
    let onManualFallback: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("扫描并登记游戏入口")
                        .font(.title3.weight(.semibold))
                    Text("条目：\(entry.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            Divider()
            ScrollView {
                InstalledGameDiscoverySection(
                    entry: entry,
                    orchestrator: orchestrator,
                    onRegistered: { registered in
                        onRegistered(registered)
                        dismiss()
                    },
                    onManualFallback: {
                        dismiss()
                        onManualFallback()
                    }
                )
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 360, idealHeight: 440)
    }
}
