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

        let metalFXOptions = HostDXMTMetalFXOptions(preset: dxmtMetalFXPreset)
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
        let availability = Self.discoverVulkanICDAvailability(in: libraryFolder)
        let route = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: hostSnapshot,
            available: availability,
            preferKosmicKrisp: dxvkPreferKosmicKrisp
        )
        for binding in route.environmentOverrides where wineEnv[binding.name] == nil {
            wineEnv[binding.name] = binding.value
        }
    }

    static func discoverVulkanICDAvailability(
        in libraryFolder: URL,
        fileManager: FileManager = .default
    ) -> HostVulkanICDAvailability {
        let icdCandidates = [
            libraryFolder.appending(path: "DXVK/vulkan/icd.d/kosmickrisp_icd.json"),
            libraryFolder.appending(path: "Vulkan/icd.d/kosmickrisp_icd.json"),
            libraryFolder.appending(path: "KosmicKrisp/kosmickrisp_icd.json")
        ]
        let loaderCandidates = [
            libraryFolder.appending(path: "DXVK/libvulkan.1.dylib"),
            libraryFolder.appending(path: "Vulkan/libvulkan.1.dylib"),
            libraryFolder.appending(path: "Wine/lib/libvulkan.1.dylib")
        ]
        let moltenCandidates = [
            libraryFolder.appending(path: "DXVK/libMoltenVK.dylib"),
            libraryFolder.appending(path: "MoltenVK/libMoltenVK.dylib"),
            libraryFolder.appending(path: "Wine/lib/libMoltenVK.dylib")
        ]
        let icdPath = icdCandidates
            .first(where: { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) })?
            .path(percentEncoded: false)
        let loaderPath = loaderCandidates
            .first(where: { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) })?
            .path(percentEncoded: false)
        let moltenPath = moltenCandidates
            .first(where: { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) })?
            .path(percentEncoded: false)
        return HostVulkanICDAvailability(
            hasKosmicKrispICD: icdPath != nil && loaderPath != nil,
            hasMoltenVK: moltenPath != nil,
            kosmicKrispICDManifestPath: icdPath,
            vulkanLoaderLibraryPath: loaderPath,
            moltenVKLibraryPath: moltenPath
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
