// SPDX-License-Identifier: GPL-3.0-or-later
// Unified navigation sections and shared performance preferences for Malt.

import SwiftUI
import WhiskyKit

enum UnifiedSidebarSection: String, CaseIterable, Identifiable {
    case library
    case install
    case performance
    case runtimes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library:
            return "游戏库"
        case .install:
            return "一键安装"
        case .performance:
            return "性能与智能适配"
        case .runtimes:
            return "环境与存储"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            return "gamecontroller.fill"
        case .install:
            return "square.and.arrow.down.on.square"
        case .performance:
            return "gauge.with.dots.needle.67percent"
        case .runtimes:
            return "externaldrive.badge.checkmark"
        }
    }
}

@MainActor
final class UnifiedPreferencesModel: ObservableObject {
    @AppStorage("unifiedSelectedTier") var selectedTierRaw: String = PerformancePresetTier.balancedRecommended.rawValue
    @AppStorage("unifiedEnableGameMode") var enableGameMode: Bool = true
    @AppStorage("unifiedEnableMouseCoalescing") var enableMouseCoalescing: Bool = true
    @AppStorage("unifiedMouseCoalesceMicros") var mouseCoalesceMicros: Int = 1500
    @AppStorage("unifiedBlockAccidentalShortcuts") var blockAccidentalShortcuts: Bool = true
    @AppStorage("unifiedRecommendedVCPU") var recommendedVCPU: Int = 8
    @AppStorage("unifiedRecommendedRAMMiB") var recommendedRAMMiB: Int = 10240
    @AppStorage("unifiedRecommendedResolution") var recommendedResolution: String = "1920x1080"
    @AppStorage("unifiedLastBenchmarkScore") var lastBenchmarkScore: Double = 0
    @AppStorage("unifiedStoragePath") var preferredStoragePath: String = ""
    @AppStorage("hasCompletedUnifiedOnboardingV1") var hasCompletedOnboarding: Bool = false

    var selectedTier: PerformancePresetTier {
        get { PerformancePresetTier(rawValue: selectedTierRaw) ?? .balancedRecommended }
        set {
            selectedTierRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    func apply(recommendation: AutoTuneRecommendation) {
        selectedTierRaw = recommendation.recommendedTier.rawValue
        enableGameMode = recommendation.enableGameMode
        mouseCoalesceMicros = recommendation.mouseCoalesceMicros
        enableMouseCoalescing = recommendation.mouseCoalesceMicros > 0
        blockAccidentalShortcuts = recommendation.blockAccidentalShortcuts
        recommendedVCPU = recommendation.recommendedVCPU
        recommendedRAMMiB = recommendation.recommendedRAMMiB
        recommendedResolution = recommendation.recommendedResolution
        lastBenchmarkScore = recommendation.benchmarkScore
        if preferredStoragePath.isEmpty {
            preferredStoragePath = recommendation.hardware.recommendedStoragePath
        }
        objectWillChange.send()
    }
}
