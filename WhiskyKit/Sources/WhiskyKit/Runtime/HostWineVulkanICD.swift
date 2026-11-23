// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Vulkan ICD implementation backing the DXVK translation layer on macOS.
public enum HostVulkanICD: String, Codable, CaseIterable, Sendable {
    case kosmicKrisp
    case moltenVK
}

/// Host availability and compatibility facts for Vulkan ICD selection under Wine/DXVK.
public struct HostVulkanICDAvailability: Equatable, Codable, Sendable {
    public let hasKosmicKrispICD: Bool
    public let kosmicKrispSupportsProcessArchitecture: Bool
    public let kosmicKrispSupportsGeometryShader: Bool
    public let kosmicKrispSupportsFillModeNonSolid: Bool
    public let hasMoltenVK: Bool
    public let kosmicKrispICDManifestPath: String?
    public let vulkanLoaderLibraryPath: String?
    public let moltenVKLibraryPath: String?

    public init(
        hasKosmicKrispICD: Bool,
        kosmicKrispSupportsProcessArchitecture: Bool = true,
        kosmicKrispSupportsGeometryShader: Bool = true,
        kosmicKrispSupportsFillModeNonSolid: Bool = true,
        hasMoltenVK: Bool = true,
        kosmicKrispICDManifestPath: String? = nil,
        vulkanLoaderLibraryPath: String? = nil,
        moltenVKLibraryPath: String? = nil
    ) {
        self.hasKosmicKrispICD = hasKosmicKrispICD
        self.kosmicKrispSupportsProcessArchitecture = kosmicKrispSupportsProcessArchitecture
        self.kosmicKrispSupportsGeometryShader = kosmicKrispSupportsGeometryShader
        self.kosmicKrispSupportsFillModeNonSolid = kosmicKrispSupportsFillModeNonSolid
        self.hasMoltenVK = hasMoltenVK
        self.kosmicKrispICDManifestPath = kosmicKrispICDManifestPath
        self.vulkanLoaderLibraryPath = vulkanLoaderLibraryPath
        self.moltenVKLibraryPath = moltenVKLibraryPath
    }

    public static let moltenVKOnly = HostVulkanICDAvailability(
        hasKosmicKrispICD: false,
        hasMoltenVK: true
    )
}

/// Deterministic Vulkan ICD routing result for the DXVK backend.
public struct HostVulkanICDRoute: Equatable, Codable, Sendable {
    public let selectedICD: HostVulkanICD?
    public let fallbackChain: [HostVulkanICD]
    public let usedFallback: Bool
    public let reason: String
    public let environmentOverrides: [HostResourceConsumerBinding]

    public init(
        selectedICD: HostVulkanICD?,
        fallbackChain: [HostVulkanICD],
        usedFallback: Bool,
        reason: String,
        environmentOverrides: [HostResourceConsumerBinding] = []
    ) {
        self.selectedICD = selectedICD
        self.fallbackChain = fallbackChain
        self.usedFallback = usedFallback
        self.reason = reason
        self.environmentOverrides = environmentOverrides
    }

    public var environmentDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: environmentOverrides.map { ($0.name, $0.value) })
    }
}

public extension HostWineBackendRouter {
    /// Selects KosmicKrisp (Vulkan 1.4 -> Metal 4) for DXVK when host OS, Apple Silicon hardware,
    /// ICD manifest, process architecture slice, and DXVK-required features are satisfied;
    /// otherwise falls back deterministically to MoltenVK.
    static func routeVulkanICD(
        hostSnapshot: RuntimeHostSnapshot,
        available: HostVulkanICDAvailability,
        preferKosmicKrisp: Bool = true
    ) -> HostVulkanICDRoute {
        let chain: [HostVulkanICD] = preferKosmicKrisp
            ? [.kosmicKrisp, .moltenVK]
            : [.moltenVK, .kosmicKrisp]
        let blocker = kosmicKrispBlocker(hostSnapshot: hostSnapshot, available: available)

        if preferKosmicKrisp, blocker == nil {
            return HostVulkanICDRoute(
                selectedICD: .kosmicKrisp,
                fallbackChain: chain,
                usedFallback: false,
                reason: "Selected KosmicKrisp ICD (Vulkan 1.4 -> Metal 4) on macOS " +
                    "\(hostSnapshot.operatingSystemVersion.major) Apple Silicon.",
                environmentOverrides: kosmicKrispBindings(available: available)
            )
        }

        if available.hasMoltenVK {
            let reason = preferKosmicKrisp
                ? "KosmicKrisp unavailable (\(blocker ?? "unsupported")); fell back to MoltenVK."
                : "Selected MoltenVK ICD by explicit caller preference."
            return HostVulkanICDRoute(
                selectedICD: .moltenVK,
                fallbackChain: chain,
                usedFallback: preferKosmicKrisp,
                reason: reason,
                environmentOverrides: moltenVKBindings(available: available)
            )
        }

        if !preferKosmicKrisp, blocker == nil {
            return HostVulkanICDRoute(
                selectedICD: .kosmicKrisp,
                fallbackChain: chain,
                usedFallback: true,
                reason: "Preferred MoltenVK unavailable; fell back to KosmicKrisp ICD.",
                environmentOverrides: kosmicKrispBindings(available: available)
            )
        }

        return HostVulkanICDRoute(
            selectedICD: nil,
            fallbackChain: chain,
            usedFallback: false,
            reason: "No compatible Vulkan ICD available for DXVK (\(blocker ?? "MoltenVK missing")).",
            environmentOverrides: []
        )
    }

    private static func kosmicKrispBlocker(
        hostSnapshot: RuntimeHostSnapshot,
        available: HostVulkanICDAvailability
    ) -> String? {
        if !hostSnapshot.isAppleSilicon {
            return "KosmicKrisp requires Apple Silicon hardware"
        }
        if hostSnapshot.operatingSystemVersion.major < 26 {
            return "KosmicKrisp requires macOS 26+ (Metal 4)"
        }
        if !available.hasKosmicKrispICD {
            return "KosmicKrisp ICD binary or manifest is not installed"
        }
        if !available.kosmicKrispSupportsProcessArchitecture {
            return "KosmicKrisp binary lacks the Wine process architecture slice"
        }
        if !available.kosmicKrispSupportsGeometryShader {
            return "KosmicKrisp build does not expose geometryShader required by DXVK"
        }
        if !available.kosmicKrispSupportsFillModeNonSolid {
            return "KosmicKrisp build does not expose fillModeNonSolid required by DXVK"
        }
        return nil
    }

    private static func kosmicKrispBindings(
        available: HostVulkanICDAvailability
    ) -> [HostResourceConsumerBinding] {
        var bindings: [HostResourceConsumerBinding] = []
        if let loaderPath = available.vulkanLoaderLibraryPath, !loaderPath.isEmpty {
            bindings.append(
                HostResourceConsumerBinding(
                    name: "WINE_SONAME_LIBVULKAN",
                    value: loaderPath,
                    consumer: "Wine winevulkan.so Vulkan loader bridge",
                    documentationReference: "Wine macOS Vulkan loader override pointing to libvulkan.1.dylib."
                )
            )
        }
        if let manifestPath = available.kosmicKrispICDManifestPath, !manifestPath.isEmpty {
            let loaderConsumer = "Khronos Vulkan Loader (libvulkan.1.dylib)"
            bindings.append(
                HostResourceConsumerBinding(
                    name: "VK_DRIVER_FILES",
                    value: manifestPath,
                    consumer: loaderConsumer,
                    documentationReference: "Vulkan Loader docs: VK_DRIVER_FILES locks the active ICD JSON manifest."
                )
            )
            bindings.append(
                HostResourceConsumerBinding(
                    name: "VK_ICD_FILENAMES",
                    value: manifestPath,
                    consumer: loaderConsumer,
                    documentationReference: "Vulkan Loader legacy alias ensuring older loaders select KosmicKrisp."
                )
            )
        }
        return bindings
    }

    private static func moltenVKBindings(
        available: HostVulkanICDAvailability
    ) -> [HostResourceConsumerBinding] {
        guard let libraryPath = available.moltenVKLibraryPath, !libraryPath.isEmpty else {
            return []
        }
        return [
            HostResourceConsumerBinding(
                name: "WINE_SONAME_LIBVULKAN",
                value: libraryPath,
                consumer: "Wine winevulkan.so Vulkan loader bridge",
                documentationReference: "Wine macOS Vulkan override pointing directly to libMoltenVK.dylib."
            )
        ]
    }
}
