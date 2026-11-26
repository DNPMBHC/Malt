// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Changes only virtual CPU/RAM metadata, after an affirmative stopped-state response.
/// Disk contents, machine identity, devices, and snapshots are never recreated.
struct ContainerResourceConfigurator {
    typealias StopVerifier = @Sendable () async throws -> Void

    static func validate(_ settings: UnifiedLaunchSettings, hardware: HardwareProfileSnapshot) throws {
        if let cpu = settings.virtualCPUCount, !HardwareAutoTuner.safeVCPUOptions(for: hardware).contains(cpu) {
            throw UnifiedOrchestrationError.backendUnavailable(
                "所选 CPU 配额不在本机安全范围内。请在容器运行设置中重新选择。")
        }
        if let memory = settings.memoryMiB,
           !UnifiedLaunchSettings.supportedContainerMemoryOptionsGiB(for: hardware).map({ $0 * 1024 })
               .contains(memory) {
            throw UnifiedOrchestrationError.backendUnavailable(
                "所选内存配额不受当前容器支持。请重新选择可用配额。")
        }
    }

    static func requiresUpdate(_ settings: UnifiedLaunchSettings, bundlePath: String) throws -> Bool {
        guard settings.virtualCPUCount != nil || settings.memoryMiB != nil else { return false }
        let url = URL(filePath: bundlePath).appending(path: "config.plist")
        guard let config = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as? [String: Any] else {
            throw UnifiedOrchestrationError.backendUnavailable("容器配置无效，未修改资源配额。")
        }
        let system = config["System"] as? [String: Any] ?? [:]
        return (settings.virtualCPUCount.map { $0 != (system["CPUCount"] as? Int) } ?? false)
            || (settings.memoryMiB.map { $0 != (system["MemorySize"] as? Int) } ?? false)
    }

    static func apply(
        _ settings: UnifiedLaunchSettings, bundlePath: String,
        controlBinaryPath: String, commandRunner: UnifiedRuntimeOrchestrator.CommandRunner,
        hardware: HardwareProfileSnapshot, verifyStopped: StopVerifier? = nil
    ) async throws {
        guard settings.virtualCPUCount != nil || settings.memoryMiB != nil else { return }
        try validate(settings, hardware: hardware)
        let bundle = URL(filePath: bundlePath)
        let configURL = bundle.appending(path: "config.plist")
        guard (try? configURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
            throw UnifiedOrchestrationError.backendUnavailable("容器配置不可安全修改。请重新导入可游玩容器。")
        }
        let original = try Data(contentsOf: configURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var config = try PropertyListSerialization.propertyList(
            from: original, options: [], format: &format) as? [String: Any],
              let information = config["Information"] as? [String: Any],
              let identifier = information["UUID"] as? String, UUID(uuidString: identifier) != nil else {
            throw UnifiedOrchestrationError.backendUnavailable("容器配置无效，未修改资源配额。")
        }
        var system = config["System"] as? [String: Any] ?? [:]
        let changesCPU = settings.virtualCPUCount.map { $0 != system["CPUCount"] as? Int } ?? false
        let changesMemory = settings.memoryMiB.map { $0 != system["MemorySize"] as? Int } ?? false
        guard changesCPU || changesMemory else { return }

        let lease = bundle.appending(path: ".resource-settings-update.lock")
        do { try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false) } catch {
            throw UnifiedOrchestrationError.backendUnavailable("另一项运行环境配置正在更新，请稍后重试。")
        }
        defer { try? FileManager.default.removeItem(at: lease) }
        try await confirmStopped(
            identifier: identifier, controlBinaryPath: controlBinaryPath,
            commandRunner: commandRunner, verifyStopped: verifyStopped
        )
        try Task.checkCancellation()
        guard try Data(contentsOf: configURL) == original else {
            throw UnifiedOrchestrationError.backendUnavailable("容器配置已被其他操作更改，未覆盖。请刷新后重试。")
        }
        if let cpu = settings.virtualCPUCount { system["CPUCount"] = cpu }
        if let memory = settings.memoryMiB { system["MemorySize"] = memory }
        config["System"] = system
        let updated = try PropertyListSerialization.data(fromPropertyList: config, format: format, options: 0)
        let backup = bundle.appending(path: ".resource-settings-backup.plist")
        if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
        try updated.write(to: configURL, options: .atomic)
        do {
            try verifyWrittenConfiguration(settings, at: configURL, identifier: identifier)
        } catch {
            try original.write(to: configURL, options: .atomic)
            throw error
        }
    }

    private static func confirmStopped(
        identifier: String, controlBinaryPath: String,
        commandRunner: UnifiedRuntimeOrchestrator.CommandRunner, verifyStopped: StopVerifier?
    ) async throws {
        if let verifyStopped {
            try await verifyStopped()
        } else {
            let status = try await commandRunner(
                controlBinaryPath, ["status", "--hide", identifier], ["__DEMOAPP_TIMEOUT_SECONDS": "5"]
            )
            try ContainerGuestDispatcher.requireAutomationAccess(status)
            guard status.exitCode == 0,
                  status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stopped" else {
                throw UnifiedOrchestrationError.backendUnavailable(
                    "资源设置已保留，但运行环境尚未确认完全关闭。请正常关闭 Windows 运行环境后重试；仅重启游戏或从挂起恢复不会应用新配额。")
            }
        }
    }

    private static func verifyWrittenConfiguration(
        _ settings: UnifiedLaunchSettings, at configURL: URL, identifier: String
    ) throws {
        guard let readBack = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: configURL), options: [], format: nil) as? [String: Any],
              let readSystem = readBack["System"] as? [String: Any],
              (readBack["Information"] as? [String: Any])?["UUID"] as? String == identifier,
              settings.virtualCPUCount.map({ readSystem["CPUCount"] as? Int == $0 }) ?? true,
              settings.memoryMiB.map({ readSystem["MemorySize"] as? Int == $0 }) ?? true else {
            throw UnifiedOrchestrationError.backendUnavailable("资源配置回读不一致，已恢复原配置。")
        }
    }
}
