// SPDX-License-Identifier: GPL-3.0-or-later
// Unified JSON-backed registry for Wine and Anti-Cheat VM game entries.

import Combine
import Foundation

/// Persists and queries unified game cards and classifies installer packages by engine fit.
public final class UnifiedGameLibraryStore: ObservableObject, @unchecked Sendable {
    @Published public var entries: [UnifiedGameEntry] = []

    public let storageURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let antiCheatKeywords: [String] = [
        "valorant",
        "vanguard",
        "riotclient",
        "riot_client",
        "riot-client",
        "anticheatexpert",
        "ace-base",
        "ace-core",
        "deltaforce",
        "delta_force",
        "wegame",
        "tencent",
        "crossfire",
        "pubg",
        "battleye",
        "easyanticheat",
        "eac_setup",
        "faceit",
        "ricochet",
        "gameguard",
        "nprotect",
        "xigncode",
        "nexon",
        "genshin",
        "naraka",
        "wuthering",
        "honkai"
    ]

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601
        self.encoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder
    }

    public static func defaultStorageURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base
            .appending(path: "com.isaacmarovitz.Whisky")
            .appending(path: "UnifiedGameLibrary.json")
    }

    public func load() {
        guard fileManager.fileExists(atPath: storageURL.path(percentEncoded: false)) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            entries = try decoder.decode([UnifiedGameEntry].self, from: data)
        } catch {
            entries = []
        }
    }

    public func upsert(_ entry: UnifiedGameEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Recommends an execution engine from installer filename, path, and lightweight binary strings.
    /// Users can always override the suggestion in the UI or orchestrator call.
    public func classifyInstaller(url: URL) -> UnifiedEngineKind {
        let normalizedPath = url.path(percentEncoded: false).lowercased()
        let normalizedName = url.lastPathComponent.lowercased()
        for keyword in Self.antiCheatKeywords where
            normalizedName.contains(keyword) || normalizedPath.contains(keyword) {
            return .antiCheatVM
        }

        if let probeText = readLightweightASCIIProbe(url: url) {
            for keyword in Self.antiCheatKeywords where probeText.contains(keyword) {
                return .antiCheatVM
            }
        }
        return .nativeWine
    }

    private func persist() {
        let parentDir = storageURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let data = try encoder.encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Persistence failures are non-fatal in-memory; callers can inspect healthStatus().
        }
    }

    private func readLightweightASCIIProbe(url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else {
            return nil
        }
        let filtered = chunk.map { byte -> UInt8 in
            (byte >= 0x20 && byte <= 0x7E) ? byte : 0x20
        }
        return String(bytes: filtered, encoding: .utf8)?.lowercased()
    }
}
