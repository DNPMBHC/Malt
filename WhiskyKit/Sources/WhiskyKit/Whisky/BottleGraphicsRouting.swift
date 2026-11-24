// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
/// User-selectable graphics translation backend mode persisted per bottle.
public enum WineGraphicsBackendMode: String, CaseIterable, Codable, Equatable, Sendable {
    case auto
    case dxmt
    case d3dMetal
    case dxvk

    public var localizationKey: String {
        "config.graphicsBackend.mode.\(rawValue)"
    }

    public var explicitBackend: HostWineGraphicsBackend? {
        switch self {
        case .auto: return nil
        case .dxmt: return .dxmt
        case .d3dMetal: return .d3dMetal
        case .dxvk: return .dxvk
        }
    }
}

public extension BottleSettings {
    /// Resolves the deterministic three-engine route for this bottle against available host backends.
    func resolveGraphicsBackendRoute(
        available: HostAvailableWineBackends = WhiskyWineInstaller.availableGraphicsBackends()
    ) -> HostWineBackendRoute {
        if let forced = wineGraphicsBackendMode.explicitBackend {
            let installed = available.contains(forced)
            let reason = installed
                ? "Explicitly pinned to \(forced.rawValue) in bottle settings."
                : "Pinned backend \(forced.rawValue) is not installed on this host."
            return HostWineBackendRoute(
                apiRequirement: directXAPIRequirement,
                preference: graphicsRoutingPreference,
                selectedBackend: installed ? forced : nil,
                fallbackChain: [forced],
                usedFallback: false,
                reason: reason
            )
        }
        return HostWineBackendRouter.route(
            apiRequirement: directXAPIRequirement,
            preference: graphicsRoutingPreference,
            available: available
        )
    }

    /// Returns the effective graphics backend used for launch policy and environment construction.
    func effectiveGraphicsBackend(
        available: HostAvailableWineBackends = WhiskyWineInstaller.availableGraphicsBackends()
    ) -> HostWineGraphicsBackend {
        if let forced = wineGraphicsBackendMode.explicitBackend {
            return forced
        }
        return resolveGraphicsBackendRoute(available: available).selectedBackend ?? .d3dMetal
    }

    /// Returns the per-bottle isolated DXMT shader cache directory URL.
    static func dxmtShaderCacheDirectory(for bottleURL: URL) -> URL {
        bottleURL.appending(path: "dxmt_shader_cache")
    }

    /// Returns the per-bottle isolated DXVK state cache directory URL.
    static func dxvkStateCacheDirectory(for bottleURL: URL) -> URL {
        bottleURL.appending(path: "dxvk_state_cache")
    }

    /// Populates Wine environment variables using the resolved three-engine backend and adaptive resource policy.
    func environmentVariables(
        wineEnv: inout [String: String],
        bottleURL: URL?,
        hostSnapshot: RuntimeHostSnapshot? = nil,
        availableBackends: HostAvailableWineBackends? = nil,
        dxmtWinePath: URL? = nil,
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder
    ) {
        let available = availableBackends ?? WhiskyWineInstaller.availableGraphicsBackends(libraryFolder: libraryFolder)
        let selectedBackend = effectiveGraphicsBackend(available: available)
        let resolvedSnapshot = hostSnapshot ?? HostCapabilityProvider.current()

        switch selectedBackend {
        case .dxvk:
            applyDXVKEnvironment(
                to: &wineEnv,
                bottleURL: bottleURL,
                libraryFolder: libraryFolder,
                hostSnapshot: resolvedSnapshot
            )
        case .dxmt:
            applyDXMTEnvironment(
                to: &wineEnv,
                bottleURL: bottleURL,
                dxmtWinePath: dxmtWinePath ?? WhiskyWineInstaller.dxmtWineFolder(in: libraryFolder)
            )
        case .d3dMetal:
            applyD3DMetalEnvironment(to: &wineEnv, libraryFolder: libraryFolder)
        }

        applyCommonWineEnvironment(to: &wineEnv)

        let metalFXOptions = HostDXMTMetalFXOptions(
            preset: dxmtMetalFXPreset, outputHeight: dxmtMetalFXOutputHeight
        )
        if selectedBackend == .dxmt, dxmtMetalFXPreset == .off {
            wineEnv["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "0"
        }
        if adaptiveResourcePolicyEnabled {
            let policy = HostWineLaunchPolicy.configured(
                snapshot: resolvedSnapshot,
                graphicsBackend: selectedBackend,
                enabled: true,
                options: HostWineLaunchOptions(dxmtMetalFX: metalFXOptions)
            )
            wineEnv = policy.applyingNonDestructively(to: wineEnv)
        } else if selectedBackend == .dxmt, dxmtMetalFXPreset != .off {
            let metalFX = HostDXMTMetalFXPolicy(
                snapshot: resolvedSnapshot,
                options: metalFXOptions,
                enabled: true
            )
            for binding in metalFX.environmentOverrides where wineEnv[binding.name] == nil {
                wineEnv[binding.name] = binding.value
            }
        }
    }

    private func applyDXVKEnvironment(
        to wineEnv: inout [String: String],
        bottleURL: URL?,
        libraryFolder: URL,
        hostSnapshot: RuntimeHostSnapshot
    ) {
        let fileManager = FileManager.default
        wineEnv.updateValue("dxgi,d3d9,d3d10core,d3d11=n,b", forKey: "WINEDLLOVERRIDES")
        switch dxvkHud {
        case .full:
            wineEnv.updateValue("full", forKey: "DXVK_HUD")
        case .partial:
            wineEnv.updateValue("devinfo,fps,frametimes", forKey: "DXVK_HUD")
        case .fps:
            wineEnv.updateValue("fps", forKey: "DXVK_HUD")
        case .off:
            break
        }
        if dxvkAsync {
            wineEnv.updateValue("1", forKey: "DXVK_ASYNC")
        }
        if let bottleURL, wineEnv["DXVK_STATE_CACHE_PATH"] == nil {
            let cacheDir = Self.dxvkStateCacheDirectory(for: bottleURL)
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            wineEnv["DXVK_STATE_CACHE_PATH"] = cacheDir.path(percentEncoded: false)
        }
        let dxvkWineDir = libraryFolder.appending(path: "DXVK/wine")
        if fileManager.fileExists(atPath: dxvkWineDir.path(percentEncoded: false)) {
            Self.prependWineDLLPath(dxvkWineDir, to: &wineEnv)
        }
        applyDXVKVulkanICD(to: &wineEnv, libraryFolder: libraryFolder, hostSnapshot: hostSnapshot)
    }

    /// Resolves the DXVK Vulkan ICD route (KosmicKrisp vs MoltenVK fallback) for UI display and launch.
    func resolveDXVKVulkanICDRoute(
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder,
        hostSnapshot: RuntimeHostSnapshot = HostCapabilityProvider.current(),
        appBundleURL: URL? = RuntimeManifestVerifier.defaultAppBundleURL()
    ) -> HostVulkanICDRoute {
        let installation = Self.discoverVulkanICDInstallation(in: libraryFolder, appBundleURL: appBundleURL)
        let route = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: hostSnapshot, available: installation.availability,
            preferKosmicKrisp: dxvkPreferKosmicKrisp
        )
        let reason: String
        if route.selectedICD == nil {
            reason = "runtime.vulkan.reason.none"
        } else if !dxvkPreferKosmicKrisp, route.selectedICD == .kosmicKrisp {
            reason = "runtime.vulkan.reason.compatibilityMissing"
        } else if !hostSnapshot.isAppleSilicon || hostSnapshot.operatingSystemVersion.major < 26 {
            reason = "runtime.vulkan.reason.hostUnsupported"
        } else if !dxvkPreferKosmicKrisp {
            reason = "runtime.vulkan.reason.preference"
        } else if installation.validation != .verified {
            reason = installation.validation.localizationKey
        } else {
            reason = "runtime.vulkan.reason.selected"
        }
        return HostVulkanICDRoute(
            selectedICD: route.selectedICD, fallbackChain: route.fallbackChain,
            usedFallback: route.usedFallback, reason: reason, environmentOverrides: route.environmentOverrides
        )
    }

    /// Resolves the effective DXMT MetalFX Spatial policy (accounting for thermal/low-res protections).
    func resolveDXMTMetalFXPolicy(
        hostSnapshot: RuntimeHostSnapshot = HostCapabilityProvider.current(),
        outputHeight: Int? = nil,
        allowLowResolutionUpscaling: Bool = false
    ) -> HostDXMTMetalFXPolicy {
        let options = HostDXMTMetalFXOptions(
            preset: dxmtMetalFXPreset,
            outputHeight: outputHeight ?? dxmtMetalFXOutputHeight,
            allowLowResolutionUpscaling: allowLowResolutionUpscaling
        )
        return HostDXMTMetalFXPolicy(snapshot: hostSnapshot, options: options, enabled: true)
    }

    private func applyDXVKVulkanICD(
        to wineEnv: inout [String: String],
        libraryFolder: URL,
        hostSnapshot: RuntimeHostSnapshot
    ) {
        guard wineEnv["WINE_SONAME_LIBVULKAN"] == nil,
              wineEnv["VK_DRIVER_FILES"] == nil,
              wineEnv["VK_ICD_FILENAMES"] == nil else {
            return
        }
        let route = resolveDXVKVulkanICDRoute(libraryFolder: libraryFolder, hostSnapshot: hostSnapshot)
        for binding in route.environmentOverrides where wineEnv[binding.name] == nil {
            wineEnv[binding.name] = binding.value
        }
    }

    static func discoverVulkanICDAvailability(
        in libraryFolder: URL,
        appBundleURL: URL? = RuntimeManifestVerifier.defaultAppBundleURL(),
        fileManager: FileManager = .default
    ) -> HostVulkanICDAvailability {
        discoverVulkanICDInstallation(in: libraryFolder, appBundleURL: appBundleURL,
                                     fileManager: fileManager).availability
    }

    private static func discoverVulkanICDInstallation(
        in libraryFolder: URL,
        appBundleURL: URL?,
        fileManager: FileManager = .default
    ) -> (availability: HostVulkanICDAvailability, validation: RuntimeVulkanValidationState) {
        var icdCandidates = [
            libraryFolder.appending(path: "DXVK/vulkan/icd.d/kosmickrisp_icd.json"),
            libraryFolder.appending(path: "Vulkan/icd.d/kosmickrisp_icd.json")
        ]
        var loaderCandidates = [
            libraryFolder.appending(path: "DXVK/libvulkan.1.dylib"),
            libraryFolder.appending(path: "Vulkan/libvulkan.1.dylib")
        ]
        var moltenCandidates = [
            libraryFolder.appending(path: "DXVK/libMoltenVK.dylib"),
            libraryFolder.appending(path: "MoltenVK/libMoltenVK.dylib"),
            libraryFolder.appending(path: "Wine/lib/libMoltenVK.dylib")
        ]
        var manifest = try? RuntimeManifest.load()
        if let appBundleURL {
            icdCandidates.insert(
                appBundleURL.appending(path: "Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json"), at: 0
            )
            loaderCandidates.insert(appBundleURL.appending(path: "Contents/Frameworks/libvulkan.1.dylib"), at: 0)
            moltenCandidates.insert(appBundleURL.appending(path: "Contents/Frameworks/libMoltenVK.dylib"), at: 0)
            manifest = try? RuntimeManifest.load(
                fromFileURL: appBundleURL.appending(path: "Contents/Resources/runtime-manifest.json")
            )
        }
        let icdURL = icdCandidates.first { fileManager.fileExists(atPath: $0.path) }
        let loaderURL = loaderCandidates.first { fileManager.fileExists(atPath: $0.path) }
        let moltenURL = moltenCandidates.first { fileManager.fileExists(atPath: $0.path) }
        let component = manifest?.components.first { $0.id == HostVulkanICD.kosmicKrisp.rawValue }
        let validation = RuntimeVulkanValidator.inspect(manifestURL: icdURL, loaderURL: loaderURL, component: component)
        return (
            HostVulkanICDAvailability(
                hasKosmicKrispICD: validation == .verified,
                kosmicKrispSupportsProcessArchitecture: validation != .architectureMismatch,
                kosmicKrispSupportsGeometryShader: validation == .verified,
                kosmicKrispSupportsFillModeNonSolid: validation == .verified,
                hasMoltenVK: moltenURL != nil,
                kosmicKrispICDManifestPath: icdURL?.path(percentEncoded: false),
                vulkanLoaderLibraryPath: loaderURL?.path(percentEncoded: false),
                moltenVKLibraryPath: moltenURL?.path(percentEncoded: false)
            ), validation
        )
    }

    private func applyD3DMetalEnvironment(to wineEnv: inout [String: String], libraryFolder: URL) {
        let fileManager = FileManager.default
        let gptkWineDir = libraryFolder.appending(path: "GPTK/wine")
        if fileManager.fileExists(atPath: gptkWineDir.path(percentEncoded: false)) {
            Self.prependWineDLLPath(gptkWineDir, to: &wineEnv)
        }
        let sharedCandidates = [
            libraryFolder.appending(path: "GPTK/external/libd3dshared.dylib"),
            libraryFolder.appending(path: "Wine/lib/external/libd3dshared.dylib")
        ]
        if let shared = sharedCandidates.first(where: {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false))
        }) {
            if wineEnv["WINE_GPTK_LIBD3DSHARED_PATH"] == nil {
                wineEnv["WINE_GPTK_LIBD3DSHARED_PATH"] = shared.path(percentEncoded: false)
            }
            if wineEnv["DYLD_FRAMEWORK_PATH"] == nil {
                wineEnv["DYLD_FRAMEWORK_PATH"] = shared.deletingLastPathComponent().path
            }
        }
    }

    private func applyDXMTEnvironment(
        to wineEnv: inout [String: String],
        bottleURL: URL?,
        dxmtWinePath: URL?
    ) {
        if wineEnv["WINEDLLOVERRIDES"] == nil {
            wineEnv["WINEDLLOVERRIDES"] = "dxgi,d3d10core,d3d11,winemetal=n,b"
        }
        if wineEnv["DXMT_SHADER_CACHE"] == nil {
            wineEnv["DXMT_SHADER_CACHE"] = "1"
        }
        if let bottleURL, wineEnv["DXMT_SHADER_CACHE_PATH"] == nil {
            let cacheDir = Self.dxmtShaderCacheDirectory(for: bottleURL)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            wineEnv["DXMT_SHADER_CACHE_PATH"] = cacheDir.path(percentEncoded: false)
        }
        if let dxmtWinePath {
            Self.prependWineDLLPath(dxmtWinePath, to: &wineEnv)
        }
    }

    private static func prependWineDLLPath(_ directory: URL, to wineEnv: inout [String: String]) {
        let path = directory.path(percentEncoded: false)
        if let existing = wineEnv["WINEDLLPATH"], !existing.isEmpty {
            let parts = existing.split(separator: ":").map(String.init)
            if !parts.contains(path) {
                wineEnv["WINEDLLPATH"] = "\(path):\(existing)"
            }
        } else {
            wineEnv["WINEDLLPATH"] = path
        }
    }

    private func applyCommonWineEnvironment(to wineEnv: inout [String: String]) {
        switch enhancedSync {
        case .none:
            break
        case .esync:
            wineEnv.updateValue("1", forKey: "WINEESYNC")
        case .msync:
            wineEnv.updateValue("1", forKey: "WINEMSYNC")
            // D3DM detects ESYNC and changes behaviour accordingly
            // so we have to lie to it so that it doesn't break
            // under MSYNC. Values hardcoded in libd3dshared.dylib
            wineEnv.updateValue("1", forKey: "WINEESYNC")
        }

        if metalHud {
            wineEnv.updateValue("1", forKey: "MTL_HUD_ENABLED")
        }

        if metalTrace {
            wineEnv.updateValue("1", forKey: "METAL_CAPTURE_ENABLED")
        }

        if avxEnabled {
            wineEnv.updateValue("1", forKey: "ROSETTA_ADVERTISE_AVX")
        }

        if dxrEnabled {
            wineEnv.updateValue("1", forKey: "D3DM_SUPPORT_DXR")
        }
    }
}

public extension Wine {
    /// Synchronizes DXMT x86_64 Windows DLLs into the bottle's `system32` and ensures the isolated cache directory.
    static func enableDXMT(
        bottle: Bottle,
        dxmtFolder: URL = WhiskyWineInstaller.dxmtFolder,
        fileManager: FileManager = .default
    ) throws {
        let cacheDir = BottleSettings.dxmtShaderCacheDirectory(for: bottle.url)
        if !fileManager.fileExists(atPath: cacheDir.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        guard let sourceDir = WhiskyWineInstaller.dxmtPEFolder(in: dxmtFolder, fileManager: fileManager) else {
            return
        }
        let system32 = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "system32")
        if !fileManager.fileExists(atPath: system32.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        }
        let requiredDLLs = ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"]
        for name in requiredDLLs {
            let sourceURL = sourceDir.appending(path: name)
            guard fileManager.fileExists(atPath: sourceURL.path(percentEncoded: false)) else { continue }
            let destinationURL = system32.appending(path: name)
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}
