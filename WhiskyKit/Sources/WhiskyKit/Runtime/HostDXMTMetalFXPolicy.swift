// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Controllable DXMT MetalFX Spatial swapchain upscaling quality/frame-rate presets.
/// Defaults to `.off` so low-resolution or lightweight scenes avoid extra VRAM and init overhead.
public enum HostDXMTMetalFXPreset: String, Codable, CaseIterable, Sendable {
    case off
    case ultraQuality
    case quality
    case balanced
    case performance

    /// Swapchain spatial upscale multiplier consumed by `d3d11.metalSpatialUpscaleFactor`.
    public var upscaleFactor: Double? {
        switch self {
        case .off: return nil
        case .ultraQuality: return 1.3
        case .quality: return 1.5
        case .balanced: return 1.7
        case .performance: return 2.0
        }
    }

    /// Canonical decimal string formatted for `DXMT_CONFIG`.
    public var configFactorString: String? {
        switch self {
        case .off: return nil
        case .ultraQuality: return "1.3"
        case .quality: return "1.5"
        case .balanced: return "1.7"
        case .performance: return "2.0"
        }
    }
}

/// Caller-supplied controls for DXMT MetalFX Spatial swapchain scaling.
public struct HostDXMTMetalFXOptions: Equatable, Codable, Sendable {
    public let preset: HostDXMTMetalFXPreset
    public let outputWidth: Int?
    public let outputHeight: Int?
    public let allowLowResolutionUpscaling: Bool
    public let minimumRecommendedOutputHeight: Int

    public init(
        preset: HostDXMTMetalFXPreset = .off,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        allowLowResolutionUpscaling: Bool = false,
        minimumRecommendedOutputHeight: Int = 1080
    ) {
        self.preset = preset
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.allowLowResolutionUpscaling = allowLowResolutionUpscaling
        self.minimumRecommendedOutputHeight = minimumRecommendedOutputHeight
    }

    public static let disabled = HostDXMTMetalFXOptions(preset: .off)
}

/// Resolved DXMT MetalFX Spatial policy with explicit fallback semantics and real consumers.
public struct HostDXMTMetalFXPolicy: Equatable, Codable, Sendable {
    public let requestedPreset: HostDXMTMetalFXPreset
    public let effectivePreset: HostDXMTMetalFXPreset
    public let isActive: Bool
    public let fallbackReason: String?
    public let environmentOverrides: [HostResourceConsumerBinding]

    public init(
        snapshot: RuntimeHostSnapshot,
        options: HostDXMTMetalFXOptions = .disabled,
        enabled: Bool = true
    ) {
        self.requestedPreset = options.preset
        guard enabled else {
            self.effectivePreset = .off
            self.isActive = false
            self.fallbackReason = options.preset == .off
                ? nil
                : "Adaptive graphics policy switch disabled; MetalFX spatial upscaling kept off."
            self.environmentOverrides = []
            return
        }

        if options.preset == .off {
            self.effectivePreset = .off
            self.isActive = false
            self.fallbackReason = nil
            self.environmentOverrides = []
            return
        }

        if let reason = Self.fallbackBlocker(snapshot: snapshot, options: options) {
            self.effectivePreset = .off
            self.isActive = false
            self.fallbackReason = reason
            self.environmentOverrides = [Self.swapchainBinding(enabled: false)]
            return
        }

        self.effectivePreset = options.preset
        self.isActive = true
        self.fallbackReason = nil
        var overrides = [Self.swapchainBinding(enabled: true)]
        if let factor = options.preset.configFactorString {
            overrides.append(
                HostResourceConsumerBinding(
                    name: "DXMT_CONFIG",
                    value: "d3d11.metalSpatialUpscaleFactor=\(factor)",
                    consumer: "DXMT runtime (d3d11.dll / dxgi.dll / winemetal.so)",
                    documentationReference: "DXMT v0.80 config (DXMT_CONFIG): d3d11.metalSpatialUpscaleFactor " +
                        "sets the MetalFX Spatial swapchain upscale multiplier."
                )
            )
        }
        self.environmentOverrides = overrides
    }

    public var environmentDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: environmentOverrides.map { ($0.name, $0.value) })
    }

    private static func fallbackBlocker(
        snapshot: RuntimeHostSnapshot,
        options: HostDXMTMetalFXOptions
    ) -> String? {
        if !snapshot.isAppleSilicon || !snapshot.metalFXSpatialScalingAvailable {
            return "Host GPU does not advertise MetalFX Spatial scaling support."
        }
        if snapshot.performancePolicy != .maximumPerformance {
            return "Host thermal or power pressure (\(snapshot.performancePolicy.rawValue)) " +
                "disabled DXMT MetalFX Spatial upscaling."
        }
        if let height = options.outputHeight,
           !options.allowLowResolutionUpscaling,
           height < options.minimumRecommendedOutputHeight {
            return "Output height \(height)px is below \(options.minimumRecommendedOutputHeight)px " +
                "threshold; MetalFX Spatial kept off to avoid unnecessary VRAM and latency overhead."
        }
        return nil
    }

    private static func swapchainBinding(enabled: Bool) -> HostResourceConsumerBinding {
        HostResourceConsumerBinding(
            name: "DXMT_METALFX_SPATIAL_SWAPCHAIN",
            value: enabled ? "1" : "0",
            consumer: "DXMT runtime (d3d11.dll / dxgi.dll / winemetal.so)",
            documentationReference: "DXMT v0.80 swapchain env (DXMT_METALFX_SPATIAL_SWAPCHAIN): " +
                "toggles MetalFX Spatial swapchain upscaling."
        )
    }
}

/// Optional graphics-tier controls applied when building a `HostWineLaunchPolicy`.
public struct HostWineLaunchOptions: Equatable, Codable, Sendable {
    public let dxmtMetalFX: HostDXMTMetalFXOptions
    public let vulkanICDRoute: HostVulkanICDRoute?

    public init(
        dxmtMetalFX: HostDXMTMetalFXOptions = .disabled,
        vulkanICDRoute: HostVulkanICDRoute? = nil
    ) {
        self.dxmtMetalFX = dxmtMetalFX
        self.vulkanICDRoute = vulkanICDRoute
    }

    public static let standard = HostWineLaunchOptions()
}

public extension HostWineLaunchPolicy {
    /// Builds a launch policy combining thermal/power throttling with explicit DXMT MetalFX
    /// preset controls and/or DXVK Vulkan ICD selection without breaking legacy initializers.
    static func configured(
        snapshot: RuntimeHostSnapshot,
        graphicsBackend: HostWineGraphicsBackend,
        enabled: Bool = true,
        options: HostWineLaunchOptions = .standard
    ) -> HostWineLaunchPolicy {
        let base = HostWineLaunchPolicy(
            snapshot: snapshot,
            graphicsBackend: graphicsBackend,
            enabled: enabled
        )
        guard enabled else { return base }

        var overrides = base.environmentOverrides
        var note = base.unmanagedDomainNote

        switch graphicsBackend {
        case .dxmt:
            let mfx = HostDXMTMetalFXPolicy(
                snapshot: snapshot,
                options: options.dxmtMetalFX,
                enabled: enabled
            )
            overrides = mergeOverrides(base: overrides, additions: mfx.environmentOverrides)
            if let fallback = mfx.fallbackReason {
                note = note.map { "\($0) \(fallback)" } ?? fallback
            }
        case .dxvk:
            if let icdRoute = options.vulkanICDRoute {
                overrides = mergeOverrides(base: overrides, additions: icdRoute.environmentOverrides)
                if icdRoute.usedFallback || icdRoute.selectedICD == nil {
                    note = note.map { "\($0) \(icdRoute.reason)" } ?? icdRoute.reason
                }
            }
        case .d3dMetal:
            break
        }

        return HostWineLaunchPolicy(
            isEnabled: base.isEnabled,
            performancePolicy: base.performancePolicy,
            graphicsBackend: base.graphicsBackend,
            processQualityOfService: base.processQualityOfService,
            environmentOverrides: overrides,
            unmanagedDomainNote: note
        )
    }

    private static func mergeOverrides(
        base: [HostResourceConsumerBinding],
        additions: [HostResourceConsumerBinding]
    ) -> [HostResourceConsumerBinding] {
        var result = base
        for binding in additions {
            if let index = result.firstIndex(where: { $0.name == binding.name }) {
                if binding.name == "DXMT_CONFIG" {
                    let existing = result[index]
                    let mergedValue = existing.value.contains(binding.value)
                        ? existing.value
                        : "\(existing.value);\(binding.value)"
                    result[index] = HostResourceConsumerBinding(
                        name: existing.name,
                        value: mergedValue,
                        consumer: existing.consumer,
                        documentationReference: "\(existing.documentationReference) \(binding.documentationReference)"
                    )
                } else {
                    result[index] = binding
                }
            } else {
                result.append(binding)
            }
        }
        return result
    }
}
