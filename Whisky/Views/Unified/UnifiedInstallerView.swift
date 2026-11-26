// SPDX-License-Identifier: GPL-3.0-or-later
// One-click drag-and-drop installer view with automatic engine recommendation.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

struct UnifiedInstallerView: View {
    @ObservedObject var libraryStore: UnifiedGameLibraryStore
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    @ObservedObject var preferences: UnifiedPreferencesModel
    let onInstallCompleted: () -> Void

    @State private var selectedInstallerURL: URL?
    @State private var gameTitle: String = ""
    @State private var selectedEngine: UnifiedEngineKind = .nativeWine
    @State private var recommendedEngine: UnifiedEngineKind?
    @State private var isDropTargeted: Bool = false
    @State private var isInstalling: Bool = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var requestedEntry: UnifiedGameEntry?
    @State private var registeredEntry: UnifiedGameEntry?

    var body: some View {
        AppPage(title: "安装游戏", subtitle: "选择 Windows 安装包，确认运行方式后开始安装。") {
            dropZoneCard

            if let installerURL = selectedInstallerURL {
                configurationCard(for: installerURL)
            }

            if let registered = registeredEntry {
                registeredConfirmationCard(for: registered)
            } else if let requested = requestedEntry {
                installerPendingCard(for: requested)
            }

            if let error = errorMessage {
                AppSection {
                    Label {
                        Text(error)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var dropZoneCard: some View {
        AppSection {
            AppAdaptiveRow {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title2)
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedInstallerURL == nil ? "拖入安装包" : "已选择安装包")
                            .font(.headline)
                        Text(selectedInstallerURL == nil
                             ? "支持 .exe 和 .msi，也可以点击选择文件。"
                             : "拖入其他文件或重新选择，即可替换安装包。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                Button("选择安装包…", action: pickInstallerFile)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .padding(.vertical, 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
    }

    private func configurationCard(for installerURL: URL) -> some View {
        AppSection(title: "安装选项") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(installerURL.lastPathComponent, systemImage: "doc")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let recommended = recommendedEngine {
                        AppStatusLabel(
                            text: "建议使用\(recommended == .antiCheatVM ? "硬件加速容器" : "原生转译")",
                            systemImage: "sparkles"
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("游戏名称")
                        .font(.subheadline.weight(.medium))
                    TextField("输入游戏库显示名称", text: $gameTitle)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("游戏名称")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("运行方式")
                        .font(.subheadline.weight(.medium))
                    Picker("运行方式", selection: $selectedEngine) {
                        Text("原生转译").tag(UnifiedEngineKind.nativeWine)
                        Text("硬件加速容器").tag(UnifiedEngineKind.antiCheatVM)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("运行方式")
                    Text("可根据游戏需求手动调整。安装完成后，在游戏库选择游戏主程序。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppAdaptiveRow {
                    Text(isInstalling ? "正在提交安装请求，请稍候。" : "安装程序将在所选运行环境中打开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    installActionButton
                }
            }
        }
    }
}

private extension UnifiedInstallerView {
    var installActionButton: some View {
        Button(action: startInstallation) {
            HStack(spacing: 8) {
                if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                Text(isInstalling ? "正在提交安装…" : "开始安装")
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isInstalling)
    }

    func pickInstallerFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data,
            UTType(filenameExtension: "msi") ?? .data
        ]
        if panel.runModal() == .OK, let url = panel.url {
            applySelectedInstaller(url)
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "exe" || ext == "msi" else {
                return
            }
            Task { @MainActor in
                applySelectedInstaller(url)
            }
        }
        return true
    }

    func applySelectedInstaller(_ url: URL) {
        selectedInstallerURL = url
        gameTitle = url.deletingPathExtension().lastPathComponent
        let classified = libraryStore.classifyInstaller(url: url)
        recommendedEngine = classified
        selectedEngine = classified
        statusMessage = nil
        errorMessage = nil
        requestedEntry = nil
        registeredEntry = nil
    }

    func startInstallation() {
        guard let installerURL = selectedInstallerURL else { return }
        isInstalling = true
        statusMessage = nil
        errorMessage = nil
        requestedEntry = nil
        registeredEntry = nil
        let settings = preferences.runtimeSettings
        let engine = selectedEngine
        let title = gameTitle
        Task {
            do {
                let entry = try await orchestrator.install(
                    installerURL: installerURL,
                    engineKind: engine,
                    title: title,
                    settings: settings
                )
                await MainActor.run {
                    isInstalling = false
                    requestedEntry = entry
                    statusMessage = "安装器已启动（等待你在弹窗中完成安装）。"
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    errorMessage = InstalledGameDiscoverySection.redactedMessage(error.localizedDescription)
                }
            }
        }
    }

    func installerPendingCard(for entry: UnifiedGameEntry) -> some View {
        AppSection(title: "安装器已启动 · 待登记游戏入口") {
            VStack(alignment: .leading, spacing: 14) {
                AppAdaptiveRow {
                    AppStatusLabel(
                        text: statusMessage ?? "安装器已启动（等待你在弹窗中完成安装）。",
                        systemImage: "hourglass",
                        tint: .orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Button("稍后在游戏库处理", action: onInstallCompleted)
                        .buttonStyle(.bordered)
                }

                Divider()

                InstalledGameDiscoverySection(
                    entry: entry,
                    orchestrator: orchestrator,
                    onRegistered: { registered in
                        registeredEntry = registered
                        requestedEntry = registered
                        errorMessage = nil
                    },
                    onManualFallback: {
                        configureManualExecutable(for: entry)
                    }
                )
            }
        }
    }

    func registeredConfirmationCard(for entry: UnifiedGameEntry) -> some View {
        AppSection(title: "已核验并登记入库") {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 6) {
                    AppStatusLabel(
                        text: "「\(entry.name)」已完成游戏入口核验并登记入库。",
                        systemImage: "checkmark.circle",
                        tint: .green
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Text("主程序：\(InstalledGameDiscoverySection.redactedPath(entry.executablePath))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } trailing: {
                Button("前往游戏库", action: onInstallCompleted)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    func configureManualExecutable(for entry: UnifiedGameEntry) {
        guard let path = InstalledGameDiscoverySection.promptManualExecutablePath(
            for: entry,
            onError: { errorMessage = $0 }
        ) else { return }
        var updated = entry
        updated.executablePath = path
        updated.installationState = .ready
        libraryStore.upsert(updated)
        registeredEntry = updated
        requestedEntry = updated
        errorMessage = nil
    }
}
