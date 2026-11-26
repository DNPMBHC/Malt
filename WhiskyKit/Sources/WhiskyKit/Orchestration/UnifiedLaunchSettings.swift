// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The guest display policy is independent of the host window's point size and DPI.
public enum UnifiedDisplayPolicy: Equatable, Sendable {
    case automatic
    case fixed(width: Int, height: Int)

    public static func fixedResolution(_ value: String) -> UnifiedDisplayPolicy? {
        let parts = value.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              GuestDisplayResolutionPolicy.allowedWidthRange.contains(width),
              GuestDisplayResolutionPolicy.allowedHeightRange.contains(height) else { return nil }
        return .fixed(width: width, height: height)
    }
}

/// An immutable snapshot: callers cannot change a running launch by changing preferences.
public struct UnifiedLaunchSettings: Equatable, Sendable {
    public let presetTier: PerformancePresetTier
    public let enableMouseCoalescing: Bool
    public let blockAccidentalShortcuts: Bool
    public let enableKeyMapping: Bool
    public let enablePersistentCache: Bool
    public let displayPolicy: UnifiedDisplayPolicy
    public let virtualCPUCount: Int?
    public let memoryMiB: Int?

    public init(
        presetTier: PerformancePresetTier = .balanced,
        enableMouseCoalescing: Bool = true,
        blockAccidentalShortcuts: Bool = true,
        enableKeyMapping: Bool = true,
        enablePersistentCache: Bool = true,
        displayPolicy: UnifiedDisplayPolicy = .automatic,
        virtualCPUCount: Int? = nil,
        memoryMiB: Int? = nil
    ) {
        self.presetTier = presetTier
        self.enableMouseCoalescing = enableMouseCoalescing
        self.blockAccidentalShortcuts = blockAccidentalShortcuts
        self.enableKeyMapping = enableKeyMapping
        self.enablePersistentCache = enablePersistentCache
        self.displayPolicy = displayPolicy
        self.virtualCPUCount = virtualCPUCount
        self.memoryMiB = memoryMiB
    }

    /// Legacy values remain readable; an absent resource key means keep the VM configuration.
    public static func load(defaults: UserDefaults = .standard) -> UnifiedLaunchSettings {
        let tier = defaults.string(forKey: "unifiedSelectedTier")
            .flatMap(PerformancePresetTier.from(rawOrLegacy:)) ?? .balanced
        let display: UnifiedDisplayPolicy
        if defaults.string(forKey: "unifiedDisplayMode") == "fixed" {
            display = UnifiedDisplayPolicy.fixedResolution(
                defaults.string(forKey: "unifiedRecommendedResolution") ?? "1920x1080"
            ) ?? .automatic
        } else {
            display = .automatic
        }
        return UnifiedLaunchSettings(
            presetTier: tier,
            enableMouseCoalescing: defaults.object(forKey: "unifiedEnableMouseCoalescing") as? Bool ?? true,
            blockAccidentalShortcuts: defaults.object(forKey: "unifiedBlockAccidentalShortcuts") as? Bool ?? true,
            enableKeyMapping: defaults.object(forKey: "unifiedEnableKeyMapping") as? Bool ?? true,
            enablePersistentCache: defaults.object(forKey: "unifiedEnablePersistentCache") as? Bool ?? true,
            displayPolicy: display,
            virtualCPUCount: boundedPersistedInteger("unifiedRecommendedVCPU", maximum: 1024, defaults: defaults),
            memoryMiB: boundedPersistedInteger("unifiedRecommendedRAMMiB", maximum: 1_048_576, defaults: defaults)
        )
    }

    private static func boundedPersistedInteger(
        _ key: String, maximum: Int, defaults: UserDefaults
    ) -> Int? {
        guard let value = defaults.object(forKey: key) as? Int else { return nil }
        return min(max(value, 1), maximum)
    }

    /// These allocations match the existing container manager's validated RAM choices.
    public static func supportedContainerMemoryOptionsGiB(for hardware: HardwareProfileSnapshot) -> [Int] {
        HardwareAutoTuner.safeMemoryOptionsGiB(for: hardware).filter { [6, 8, 10, 12].contains($0) }
    }

    public static func containerPreset(
        _ tier: PerformancePresetTier, hardware: HardwareProfileSnapshot
    ) -> (virtualCPUCount: Int, memoryMiB: Int) {
        let cpu = HardwareAutoTuner.safeVCPUOptions(for: hardware)
        let memory = supportedContainerMemoryOptionsGiB(for: hardware)
        let recommendedCPU = HardwareAutoTuner.recommendedVCPUCount(for: hardware)
        let recommendedRAM = HardwareAutoTuner.recommendedMemoryGiB(for: hardware)
        switch tier {
        case .lowSpecCompatible:
            return (cpu.first ?? 2, (memory.first ?? 6) * 1024)
        case .balanced:
            return (
                cpu.min(by: { abs($0 - recommendedCPU) < abs($1 - recommendedCPU) }) ?? 2,
                (memory.min(by: { abs($0 - recommendedRAM) < abs($1 - recommendedRAM) }) ?? 6) * 1024
            )
        case .maxPerformance:
            return (cpu.last ?? 2, (memory.last ?? 6) * 1024)
        }
    }

    public func resolved(for entry: UnifiedGameEntry, hardware: HardwareProfileSnapshot) -> UnifiedLaunchSettings {
        guard entry.engineKind == .antiCheatVM, entry.inheritsGlobalPerformanceSettings == false else { return self }
        let resources = Self.containerPreset(entry.presetTier, hardware: hardware)
        return UnifiedLaunchSettings(
            presetTier: entry.presetTier, enableMouseCoalescing: enableMouseCoalescing,
            blockAccidentalShortcuts: blockAccidentalShortcuts, enableKeyMapping: enableKeyMapping,
            enablePersistentCache: enablePersistentCache, displayPolicy: displayPolicy,
            virtualCPUCount: resources.virtualCPUCount, memoryMiB: resources.memoryMiB
        )
    }

    /// The helper consumes these names. The mouse setting batches events, never changes USB polling.
    public var containerEnvironment: [String: String] {
        [
            "UTM_MOUSE_COALESCE_US": enableMouseCoalescing ? "1500" : "0",
            "UTM_GAME_SHELL_KEY_GUARD": blockAccidentalShortcuts ? "1" : "0",
            "UTM_BLOCK_WIN_KEY": enableKeyMapping ? "1" : "0",
            "UTM_DXMT_SHADER_CACHE_ENABLED": enablePersistentCache ? "1" : "0"
        ]
    }

    func applyingWineCachePolicy(to environment: [String: String]) -> [String: String] {
        var result = environment
        result["DXMT_SHADER_CACHE"] = enablePersistentCache ? "1" : "0"
        result["DXVK_STATE_CACHE"] = enablePersistentCache ? "1" : "0"
        if !enablePersistentCache {
            result.removeValue(forKey: "DXMT_SHADER_CACHE_PATH")
            result.removeValue(forKey: "DXVK_STATE_CACHE_PATH")
        }
        return result
    }
}
