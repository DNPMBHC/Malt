// SPDX-License-Identifier: GPL-3.0-or-later
// One-click drag-and-drop installer view with automatic engine recommendation.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

struct UnifiedInstallerView: View {
    @ObservedObject var libraryStore: UnifiedGameLibraryStore
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    let onInstallCompleted: () -> Void

    @State private var selectedInstallerURL: URL?
    @State private var gameTitle: String = ""
    @State private var selectedEngine: UnifiedEngineKind = .nativeWine
    @State private var recommendedEngine: UnifiedEngineKind?
    @State private var isDropTargeted: Bool = false
    @State private var isInstalling: Bool = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("一键安装")
                        .font(.title2.bold())
                    Text("拖入 .exe 或 .msi 安装包，自动识别普通转译或反作弊安全模式，装完自动入库")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                dropZoneCard

                if let installerURL = selectedInstallerURL {
                    configurationCard(for: installerURL)
                }

                if let status = statusMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(status)
                            .font(.subheadline)
                        Spacer()
                        Button("前往游戏库", action: onInstallCompleted)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if let error = errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dropZoneCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 40))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            Text(selectedInstallerURL == nil ? "拖放 Windows 安装程序（.exe / .msi）到此处" : "已选择安装包，可拖放新文件替换")
                .font(.headline)
            Text("反作弊游戏将通过无桌面应用壳窗口弹窗安装，全程不见 Windows 桌面")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("选择安装包…", action: pickInstallerFile)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
    }

    private func configurationCard(for installerURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(installerURL.lastPathComponent, systemImage: "doc.fill")
                    .font(.headline)
                Spacer()
                if let recommended = recommendedEngine {
                    Text("自动推荐：\(recommended == .antiCheatVM ? "反作弊安全模式" : "原生转译")")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("游戏名称")
                    .font(.subheadline.weight(.medium))
                TextField("输入游戏库显示名称", text: $gameTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("运行引擎模式（可手动切换）")
                    .font(.subheadline.weight(.medium))
                Picker("运行引擎", selection: $selectedEngine) {
                    Text("原生转译（Wine）").tag(UnifiedEngineKind.nativeWine)
                    Text("反作弊安全模式（无桌面应用壳）").tag(UnifiedEngineKind.antiCheatVM)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                installActionButton
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var installActionButton: some View {
        Button(action: startInstallation) {
            HStack(spacing: 8) {
                if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.rectangle.fill")
                }
                Text(isInstalling ? "正在安装并入库…" : "开始安装")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isInstalling)
    }

    private func pickInstallerFile() {
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
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

    private func applySelectedInstaller(_ url: URL) {
        selectedInstallerURL = url
        gameTitle = url.deletingPathExtension().lastPathComponent
        let classified = libraryStore.classifyInstaller(url: url)
        recommendedEngine = classified
        selectedEngine = classified
        statusMessage = nil
        errorMessage = nil
    }

    private func startInstallation() {
        guard let installerURL = selectedInstallerURL else { return }
        isInstalling = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let entry = try await orchestrator.install(
                    installerURL: installerURL,
                    engineKind: selectedEngine,
                    title: gameTitle
                )
                await MainActor.run {
                    isInstalling = false
                    statusMessage = "已成功安装「\(entry.name)」并加入游戏库。"
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
