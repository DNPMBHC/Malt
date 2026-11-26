//
//  WhiskyApp.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif
import WhiskyKit

@main
@MainActor
enum ApplicationEntryPoint {
    static func main() {
        if ProcessInfo.processInfo.environment["RUNTIME_DYLD_SMOKE_ONLY"] == "1" {
            FileHandle.standardOutput.write(Data("runtime-dyld-smoke:foundation-only\n".utf8))
            let deadline = Date().addingTimeInterval(5)
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run(until: deadline)
            timer.invalidate()
            return
        }
        WhiskyApp.main()
    }
}

struct WhiskyApp: App {
    @State var showSetup: Bool = false
    @State private var isClearingShaderCaches = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openURL) var openURL
    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView(showSetup: $showSetup)
                .frame(minWidth: 720, minHeight: 480)
                .environmentObject(BottleVM.shared)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false

                    Task.detached {
                        await WhiskyApp.deleteOldLogs()
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        // Don't ask me how this works, it just does
        .handlesExternalEvents(matching: ["{same path of URL?}"])
        .commands {
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                SparkleView(updater: updaterController.updater)
            }
            #endif
            CommandGroup(before: .systemServices) {
                Divider()
                Button("open.setup") {
                    showSetup = true
                }
                Button("install.cli") {
                    Task {
                        await WhiskyCmd.install()
                    }
                }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("open.bottle") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = false
                    panel.begin { result in
                        if result == .OK {
                            if let url = panel.urls.first {
                                BottleVM.shared.bottlesList.paths.append(url)
                                BottleVM.shared.loadBottles()
                            }
                        }
                    }
                }
                .keyboardShortcut("I", modifiers: [.command])
            }
            CommandGroup(after: .importExport) {
                Button("open.logs") {
                    WhiskyApp.openLogsFolder()
                }
                .keyboardShortcut("L", modifiers: [.command])
                Button("kill.bottles") {
                    WhiskyApp.killBottles()
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])
                Button("wine.clearShaderCaches") {
                    guard !isClearingShaderCaches else { return }
                    isClearingShaderCaches = true
                    Task { @MainActor in
                        defer { isClearingShaderCaches = false }
                        await Self.wipeShaderCaches()
                    }
                }
                .disabled(isClearingShaderCaches)
            }
            CommandGroup(replacing: .help) {
                Button("help.website") {
                    if let url = URL(string: "https://getwhisky.app/") {
                        openURL(url)
                    }
                }
                Button("help.github") {
                    if let url = URL(string: "https://github.com/Whisky-App/Whisky") {
                        openURL(url)
                    }
                }
                Button("help.discord") {
                    if let url = URL(string: "https://discord.gg/CsqAfs9CnM") {
                        openURL(url)
                    }
                }
            }
        }
        Settings {
            SettingsView()
        }
    }

    static func killBottles() {
        for bottle in BottleVM.shared.bottles {
            do {
                try Wine.killBottle(bottle: bottle)
            } catch {
                print("Failed to kill bottle: \(error)")
            }
        }
    }

    static func openLogsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Wine.logsFolder.path)
    }

    static func deleteOldLogs() {
        let pastDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Wine.logsFolder,
            includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }

        let logs = urls.filter { url in
            url.pathExtension == "log"
        }

        let oldLogs = logs.filter { url in
            do {
                let resourceValues = try url.resourceValues(forKeys: [.creationDateKey])

                return resourceValues.creationDate ?? Date() < pastDate
            } catch {
                return false
            }
        }

        for log in oldLogs {
            do {
                try FileManager.default.removeItem(at: log)
            } catch {
                print("Failed to delete log: \(error)")
            }
        }
    }

    @MainActor
    static func wipeShaderCaches() async {
        let confirmation = NSAlert()
        confirmation.messageText = "清理已知着色器缓存？"
        confirmation.informativeText = "包括共享 D3DMetal、DXMT 以及已知兼容容器的 DXMT/DXVK 缓存，下次启动时重新生成。不会结束任何进程；"
            + "检测到游戏或容器运行、或无法确认运行状态时，将停止清理。"
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "清理缓存")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let orchestrator = UnifiedRuntimeOrchestrator()
        orchestrator.libraryStore.load()
        var bottleURLs = BottleVM.shared.bottles.map(\.url)
        bottleURLs += orchestrator.libraryStore.entries.compactMap(\.bottleURL)
        if let fallback = orchestrator.configuration.defaultBottleURL { bottleURLs.append(fallback) }
        let targets = ShaderCacheService().targets(bottleURLs: bottleURLs)
        let helperNames = [orchestrator.resolvedRuntimePaths().containerHelperBinaryPath]
            .compactMap { $0 }.map { URL(filePath: $0).lastPathComponent }
        let (result, summary) = await Task.detached(priority: .utility) {
            let service = ShaderCacheService()
            let result = service.clear(targets: targets) {
                ShaderCacheService.processActivity(additionalExecutableNames: helperNames)
            }
            return (result, service.measure(targets: targets))
        }.value

        let failures = result.failures + summary.failures
        let feedback = NSAlert()
        feedback.messageText = "着色器缓存清理结果"
        feedback.alertStyle = result.wasBlocked || !failures.isEmpty ? .warning : .informational
        var messages: [String] = []
        if result.wasBlocked {
            messages.append(result.removedCount == 0
                ? "检测到游戏或容器运行，或无法确认运行状态，未清理缓存。请关闭相关程序后重试。"
                : "运行状态发生变化，已停止继续清理。请关闭相关程序后重试。")
        } else if !failures.isEmpty {
            messages.append("部分缓存未能清理，请查看下方说明。")
        } else if result.removedCount == 0 {
            messages.append("没有需要清理的已知缓存。")
        }
        if result.removedCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file)
            messages.append("已清理 \(result.removedCount) 处缓存（\(size)），下次启动时重新生成。")
        }
        messages += failures.map { "\($0.label)：\($0.message)" }
        if summary.failures.isEmpty {
            let remaining = ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file)
            messages.append("同一统计范围的剩余缓存：\(remaining)。")
        }
        feedback.informativeText = messages.joined(separator: "\n")
        feedback.addButton(withTitle: "好")
        feedback.runModal()
    }

}
