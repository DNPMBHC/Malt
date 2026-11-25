// SPDX-License-Identifier: GPL-3.0-or-later
// Unified game library data models shared across Wine and Anti-Cheat VM engines.

import Foundation

/// Execution backend selected for a game entry.
public enum UnifiedEngineKind: String, Codable, CaseIterable, Sendable {
    case nativeWine
    case antiCheatVM

    public var displayName: String {
        switch self {
        case .nativeWine:
            return "Wine 转译引擎"
        case .antiCheatVM:
            return "反作弊安全沙盒"
        }
    }
}

/// Performance preset tier recommended by HardwareAutoTuner or selected by the user.
public enum PerformancePresetTier: String, Codable, CaseIterable, Sendable {
    case competitiveHighFPS
    case balancedRecommended
    case nativeQuality

    public var displayName: String {
        switch self {
        case .competitiveHighFPS:
            return "竞技高帧"
        case .balancedRecommended:
            return "平衡推荐"
        case .nativeQuality:
            return "原生画质"
        }
    }
}

/// Unified card representation for both Wine bottle games and persistent Anti-Cheat VM games.
public struct UnifiedGameEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var executablePath: String
    public var engineKind: UnifiedEngineKind
    public var presetTier: PerformancePresetTier
    public var iconPath: String?
    public var lastPlayedAt: Date?
    public var bottleURL: URL?
    public var vmBundlePath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        executablePath: String,
        engineKind: UnifiedEngineKind,
        presetTier: PerformancePresetTier = .balancedRecommended,
        iconPath: String? = nil,
        lastPlayedAt: Date? = nil,
        bottleURL: URL? = nil,
        vmBundlePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.engineKind = engineKind
        self.presetTier = presetTier
        self.iconPath = iconPath
        self.lastPlayedAt = lastPlayedAt
        self.bottleURL = bottleURL
        self.vmBundlePath = vmBundlePath
    }
}
