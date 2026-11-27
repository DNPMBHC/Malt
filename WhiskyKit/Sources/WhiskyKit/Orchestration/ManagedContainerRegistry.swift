// SPDX-License-Identifier: GPL-3.0-or-later
// Multi-container registry, active selection switching, and guarded container deletion.

import Foundation

/// Read-only view model of a registered managed container displayed in the UI.
public struct ManagedContainerItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundlePath }
    public let bundlePath: String
    public let vmIdentifier: String
    public let displayName: String
    public let isActive: Bool

    public init(bundlePath: String, vmIdentifier: String, displayName: String, isActive: Bool) {
        self.bundlePath = bundlePath
        self.vmIdentifier = vmIdentifier
        self.displayName = displayName
        self.isActive = isActive
    }
}

struct ManagedContainerRecord: Codable, Equatable, Sendable {
    let bundlePath: String
    let vmIdentifier: String
    let addedAt: Date
}

private struct ManagedContainerRegistryFile: Codable {
    let schemaVersion: Int
    var containers: [ManagedContainerRecord]
}

/// Manages a persistent multi-container list alongside the single-active `selected-container.json`.
enum ManagedContainerRegistry {
    static func registryURL(for selectionURL: URL) -> URL {
        selectionURL.deletingLastPathComponent().appending(path: "containers-registry.json")
    }

    static func listItems(selectionURL: URL, fileManager: FileManager) -> [ManagedContainerItem] {
        let activePath = PlayableContainerSelection.load(from: selectionURL, fileManager: fileManager)
        let records = loadValidRecords(selectionURL: selectionURL, activePath: activePath, fileManager: fileManager)
        return records.map { record in
            let name = URL(filePath: record.bundlePath).deletingPathExtension().lastPathComponent
            return ManagedContainerItem(
                bundlePath: record.bundlePath,
                vmIdentifier: record.vmIdentifier,
                displayName: name,
                isActive: record.bundlePath == activePath
            )
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func upsert(
        bundlePath: String, vmIdentifier: String, selectionURL: URL, fileManager: FileManager
    ) throws {
        let normalized = normalizePath(bundlePath)
        let activePath = PlayableContainerSelection.load(from: selectionURL, fileManager: fileManager)
        var records = loadValidRecords(selectionURL: selectionURL, activePath: activePath, fileManager: fileManager)
        records.removeAll { $0.bundlePath == normalized }
        records.append(ManagedContainerRecord(bundlePath: normalized, vmIdentifier: vmIdentifier, addedAt: Date()))
        try saveRecords(records, selectionURL: selectionURL, fileManager: fileManager)
    }

    static func select(
        bundlePath: String, selectionURL: URL, fileManager: FileManager
    ) throws -> ImportedPlayableContainer {
        let normalized = normalizePath(bundlePath)
        let url = URL(filePath: normalized).standardizedFileURL
        guard !ContainerProvisioningPipeline.isProtectedBundle(url, fileManager: fileManager) else {
            throw UnifiedOrchestrationError.backendUnavailable("受保护的只读母盘或冷备容器不可直接切换为工作容器。")
        }
        guard let verifiedID = PlayableContainerSelection.verifiedIdentifier(at: url, fileManager: fileManager) else {
            throw UnifiedOrchestrationError.backendUnavailable("所选容器缺少有效受管元数据，请通过「导入已有容器」重新登记。")
        }
        let identifier = verifiedID.uuidString
        try PlayableContainerSelection(schemaVersion: 1, bundlePath: normalized, vmIdentifier: identifier)
            .save(to: selectionURL, fileManager: fileManager)
        try upsert(
            bundlePath: normalized, vmIdentifier: identifier,
            selectionURL: selectionURL, fileManager: fileManager
        )
        return ImportedPlayableContainer(bundlePath: normalized, vmIdentifier: identifier, alreadyManaged: true)
    }

    static func remove(
        bundlePath: String,
        deleteFilesOnDisk: Bool,
        selectionURL: URL,
        fileManager: FileManager,
        commandRunner: UnifiedRuntimeOrchestrator.CommandRunner
    ) async throws -> String? {
        let normalized = normalizePath(bundlePath)
        let url = URL(filePath: normalized).standardizedFileURL
        if deleteFilesOnDisk {
            guard url.pathExtension.lowercased() == "utm" else {
                throw UnifiedOrchestrationError.backendUnavailable("仅允许删除有效的 .utm 容器目录。")
            }
            guard !ContainerProvisioningPipeline.isProtectedBundle(url, fileManager: fileManager) else {
                throw UnifiedOrchestrationError.backendUnavailable("禁止删除受保护的只读母盘或原始冷备容器。")
            }
            if let vmUUID = try? ContainerGuestDispatcher.vmIdentifier(bundlePath: normalized) {
                let running = try await commandRunner(
                    "/usr/bin/pgrep", ["-f", vmUUID], ["__DEMOAPP_TIMEOUT_SECONDS": "5"]
                )
                if running.exitCode == 0 {
                    throw UnifiedOrchestrationError.backendUnavailable(
                        "容器仍在运行中，请先在 Windows 内正常关机后再删除。"
                    )
                }
            }
            if fileManager.fileExists(atPath: normalized) {
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    try fileManager.removeItem(at: url)
                }
            }
        }

        let activePath = PlayableContainerSelection.load(from: selectionURL, fileManager: fileManager)
        var records = loadValidRecords(selectionURL: selectionURL, activePath: activePath, fileManager: fileManager)
        records.removeAll { $0.bundlePath == normalized }
        try saveRecords(records, selectionURL: selectionURL, fileManager: fileManager)

        if activePath == normalized || activePath == nil {
            if let fallback = records.first {
                try PlayableContainerSelection(
                    schemaVersion: 1, bundlePath: fallback.bundlePath, vmIdentifier: fallback.vmIdentifier
                ).save(to: selectionURL, fileManager: fileManager)
                return fallback.bundlePath
            }
            try? fileManager.removeItem(at: selectionURL)
            return nil
        }
        return activePath
    }
}

private extension ManagedContainerRegistry {
    static func normalizePath(_ raw: String) -> String {
        var path = URL(filePath: raw).standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func loadValidRecords(
        selectionURL: URL, activePath: String?, fileManager: FileManager
    ) -> [ManagedContainerRecord] {
        var records: [ManagedContainerRecord] = []
        let url = registryURL(for: selectionURL)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ManagedContainerRegistryFile.self, from: data),
           decoded.schemaVersion == 1 {
            records = decoded.containers.filter { record in
                let bundleURL = URL(filePath: record.bundlePath).standardizedFileURL
                return PlayableContainerSelection.verifiedIdentifier(at: bundleURL, fileManager: fileManager) != nil
            }
        }
        if let activePath {
            let normalized = normalizePath(activePath)
            if !records.contains(where: { $0.bundlePath == normalized }),
               let verified = PlayableContainerSelection.verifiedIdentifier(
                   at: URL(filePath: normalized), fileManager: fileManager
               ) {
                records.insert(
                    ManagedContainerRecord(
                        bundlePath: normalized, vmIdentifier: verified.uuidString, addedAt: Date()
                    ),
                    at: 0
                )
            }
        }
        return records
    }

    static func saveRecords(
        _ records: [ManagedContainerRecord], selectionURL: URL, fileManager: FileManager
    ) throws {
        let url = registryURL(for: selectionURL)
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let payload = ManagedContainerRegistryFile(schemaVersion: 1, containers: records)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}
