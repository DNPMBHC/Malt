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

    /// Populates Wine environment variables using the resolved three-engine backend and adaptive resource policy.
    func environmentVariables(
        wineEnv: inout [String: String],
        bottleURL: URL?,
        hostSnapshot: RuntimeHostSnapshot? = nil,
        availableBackends: HostAvailableWineBackends? = nil,
        dxmtWinePath: URL? = nil
    ) {
        let available = availableBackends ?? WhiskyWineInstaller.availableGraphicsBackends()
        let selectedBackend = effectiveGraphicsBackend(available: available)

        switch selectedBackend {
        case .dxvk:
            applyDXVKEnvironment(to: &wineEnv)
        case .dxmt:
            applyDXMTEnvironment(
                to: &wineEnv,
                bottleURL: bottleURL,
                dxmtWinePath: dxmtWinePath ?? WhiskyWineInstaller.dxmtWineFolder()
            )
        case .d3dMetal:
            break
        }

        applyCommonWineEnvironment(to: &wineEnv)

        if adaptiveResourcePolicyEnabled {
            let policy = HostWineLaunchPolicy(
                snapshot: hostSnapshot ?? HostCapabilityProvider.current(),
                graphicsBackend: selectedBackend,
                enabled: true
            )
            wineEnv = policy.applyingNonDestructively(to: wineEnv)
        }
    }

    private func applyDXVKEnvironment(to wineEnv: inout [String: String]) {
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
            wineEnv["DXMT_SHADER_CACHE_PATH"] = cacheDir.path(percentEncoded: false)
        }
        if let dxmtWinePath {
            let path = dxmtWinePath.path(percentEncoded: false)
            if let existing = wineEnv["WINEDLLPATH"], !existing.isEmpty {
                let parts = existing.split(separator: ":").map(String.init)
                if !parts.contains(path) {
                    wineEnv["WINEDLLPATH"] = "\(path):\(existing)"
                }
            } else {
                wineEnv["WINEDLLPATH"] = path
            }
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
