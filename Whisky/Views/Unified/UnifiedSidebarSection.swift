// SPDX-License-Identifier: GPL-3.0-or-later
// Unified navigation sections and shared performance preferences for Malt.

import AppKit
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
            return "安装游戏"
        case .performance:
            return "性能设置"
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

// Shared presentation primitives for adaptive desktop pages.
private struct AppContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 800
}

extension EnvironmentValues {
    var appContentWidth: CGFloat {
        get { self[AppContentWidthKey.self] }
        set { self[AppContentWidthKey.self] = newValue }
    }
}

struct AppPage<Content: View>: View {
    let title: String
    let subtitle: String
    let maxWidth: CGFloat
    private let content: Content

    init(title: String, subtitle: String = "", maxWidth: CGFloat = 1040,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 600 ? 20 : 32
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 26, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .environment(\.appContentWidth, min(maxWidth, max(0, geometry.size.width - inset * 2)))
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppSection<Content: View>: View {
    let title: String?
    let subtitle: String?
    private let content: Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    }
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        }
    }
}

struct AppAdaptiveRow<Leading: View, Trailing: View>: View {
    @Environment(\.appContentWidth) private var contentWidth
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if contentWidth < 600 {
            VStack(alignment: .leading, spacing: 12) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 20) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                trailing.fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct AppStatusLabel: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct AppToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

@MainActor
final class UnifiedPreferencesModel: ObservableObject {
    private let defaults: UserDefaults
    @Published var selectedTierRaw: String { didSet { defaults.set(selectedTierRaw, forKey: "unifiedSelectedTier") } }
    @Published var enableGameMode: Bool { didSet { defaults.set(enableGameMode, forKey: "unifiedEnableGameMode") } }
    @Published var enableMouseCoalescing: Bool {
        didSet { defaults.set(enableMouseCoalescing, forKey: "unifiedEnableMouseCoalescing") }
    }
    @Published var blockAccidentalShortcuts: Bool {
        didSet { defaults.set(blockAccidentalShortcuts, forKey: "unifiedBlockAccidentalShortcuts") }
    }
    @Published var enableKeyMapping: Bool {
        didSet { defaults.set(enableKeyMapping, forKey: "unifiedEnableKeyMapping") }
    }
    @Published var enablePersistentCache: Bool {
        didSet { defaults.set(enablePersistentCache, forKey: "unifiedEnablePersistentCache") }
    }
    @Published var recommendedVCPU: Int { didSet { defaults.set(recommendedVCPU, forKey: "unifiedRecommendedVCPU") } }
    @Published var recommendedRAMMiB: Int {
        didSet { defaults.set(recommendedRAMMiB, forKey: "unifiedRecommendedRAMMiB") }
    }
    @Published var recommendedResolution: String {
        didSet { defaults.set(recommendedResolution, forKey: "unifiedRecommendedResolution") }
    }
    @Published var displayModeRaw: String {
        didSet {
            if displayModeRaw == "fixed", UnifiedDisplayPolicy.fixedResolution(recommendedResolution) == nil {
                recommendedResolution = "1920x1080"
            }
            defaults.set(displayModeRaw, forKey: "unifiedDisplayMode")
        }
    }
    @Published var lastBenchmarkScore: Double {
        didSet { defaults.set(lastBenchmarkScore, forKey: "unifiedLastBenchmarkScore") }
    }
    @Published var preferredStoragePath: String {
        didSet { defaults.set(preferredStoragePath, forKey: "unifiedStoragePath") }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedUnifiedOnboardingV1") }
    }
    @Published var hasCustomPerformanceSettings: Bool {
        didSet { defaults.set(hasCustomPerformanceSettings, forKey: "unifiedCustomPerformanceSettings") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTierRaw = defaults.string(forKey: "unifiedSelectedTier") ?? PerformancePresetTier.balanced.rawValue
        enableGameMode = defaults.object(forKey: "unifiedEnableGameMode") as? Bool ?? true
        enableMouseCoalescing = defaults.object(forKey: "unifiedEnableMouseCoalescing") as? Bool ?? true
        blockAccidentalShortcuts = defaults.object(forKey: "unifiedBlockAccidentalShortcuts") as? Bool ?? true
        enableKeyMapping = defaults.object(forKey: "unifiedEnableKeyMapping") as? Bool ?? true
        enablePersistentCache = defaults.object(forKey: "unifiedEnablePersistentCache") as? Bool ?? true
        recommendedVCPU = defaults.object(forKey: "unifiedRecommendedVCPU") as? Int ?? 8
        recommendedRAMMiB = defaults.object(forKey: "unifiedRecommendedRAMMiB") as? Int ?? 10240
        recommendedResolution = defaults.string(forKey: "unifiedRecommendedResolution") ?? "1920x1080"
        displayModeRaw = defaults.string(forKey: "unifiedDisplayMode") == "fixed"
            && UnifiedDisplayPolicy.fixedResolution(
                defaults.string(forKey: "unifiedRecommendedResolution") ?? "1920x1080"
            ) != nil
            ? "fixed" : "automatic"
        lastBenchmarkScore = defaults.double(forKey: "unifiedLastBenchmarkScore")
        preferredStoragePath = defaults.string(forKey: "unifiedStoragePath") ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedUnifiedOnboardingV1")
        hasCustomPerformanceSettings = defaults.bool(forKey: "unifiedCustomPerformanceSettings")
    }

    var runtimeSettings: UnifiedLaunchSettings { UnifiedLaunchSettings.load(defaults: defaults) }
    var hasMemoryOverride: Bool { defaults.object(forKey: "unifiedRecommendedRAMMiB") != nil }
    var hasCPUOverride: Bool { defaults.object(forKey: "unifiedRecommendedVCPU") != nil }

    var selectedTier: PerformancePresetTier {
        get { PerformancePresetTier.from(rawOrLegacy: selectedTierRaw) ?? .balanced }
        set { applyPreset(newValue, hardware: HardwareAutoTuner().detectHardwareProfile()) }
    }

    var selectedMemoryGiB: Int {
        get { recommendedRAMMiB / 1024 }
        set {
            guard [6, 8, 10, 12].contains(newValue) else { return }
            recommendedRAMMiB = newValue * 1024
            hasCustomPerformanceSettings = true
        }
    }

    func setVirtualCPUCount(_ count: Int) {
        guard count > 0 else {
            defaults.removeObject(forKey: "unifiedRecommendedVCPU")
            hasCustomPerformanceSettings = true
            return
        }
        recommendedVCPU = min(count, 64)
        hasCustomPerformanceSettings = true
    }

    func clearResourceOverrides() {
        defaults.removeObject(forKey: "unifiedRecommendedVCPU")
        defaults.removeObject(forKey: "unifiedRecommendedRAMMiB")
        hasCustomPerformanceSettings = false
        objectWillChange.send()
    }

    func applyPreset(_ tier: PerformancePresetTier, hardware: HardwareProfileSnapshot) {
        let preset = UnifiedLaunchSettings.containerPreset(tier, hardware: hardware)
        selectedTierRaw = tier.rawValue
        recommendedVCPU = preset.virtualCPUCount
        recommendedRAMMiB = preset.memoryMiB
        hasCustomPerformanceSettings = false
    }

    func clampToSafeBounds(for hardware: HardwareProfileSnapshot) {
        let options = UnifiedLaunchSettings.supportedContainerMemoryOptionsGiB(for: hardware)
        if hasMemoryOverride,
           let closest = options.min(by: { abs($0 - selectedMemoryGiB) < abs($1 - selectedMemoryGiB) }),
           !options.contains(selectedMemoryGiB) { recommendedRAMMiB = closest * 1024 }
        if hasCPUOverride {
            recommendedVCPU = HardwareAutoTuner.clampedVCPU(
                min(64, max(1, recommendedVCPU)), for: hardware
            )
        }
    }

    func recommendedResources(for recommendation: AutoTuneRecommendation) -> (virtualCPUCount: Int, memoryMiB: Int) {
        let cpu = HardwareAutoTuner.clampedVCPU(
            min(64, max(1, recommendation.recommendedVCPU)), for: recommendation.hardware
        )
        let options = UnifiedLaunchSettings.supportedContainerMemoryOptionsGiB(for: recommendation.hardware)
        let requested = min(64, max(1, recommendation.recommendedRAMGiB))
        let memory = options.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? 6
        return (cpu, memory * 1024)
    }

    /// Recommendations update resource choices; compatibility switches and display choices stay explicit.
    func apply(recommendation: AutoTuneRecommendation) {
        let resources = recommendedResources(for: recommendation)
        selectedTierRaw = recommendation.recommendedTier.rawValue
        recommendedVCPU = resources.virtualCPUCount
        recommendedRAMMiB = resources.memoryMiB
        lastBenchmarkScore = recommendation.benchmarkScore
        hasCustomPerformanceSettings = false
    }

    /// Opens macOS System Settings (Login Items / Background Extensions) for optional vmnet daemon authorization.
    /// When left disabled, Malt automatically falls back to the zero-privilege full TCP+UDP channel.
    static func openVMNetSystemAuthorization() {
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security")
        ].compactMap { $0 }
        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }
}
