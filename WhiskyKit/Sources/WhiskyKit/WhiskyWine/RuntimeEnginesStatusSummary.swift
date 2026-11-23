// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SemanticVersion

/// Status snapshot of an individual DirectX translation engine under WhiskyWine Libraries.
public struct RuntimeGraphicsEngineEntry: Codable, Sendable, Equatable, Identifiable {
    public let backend: HostWineGraphicsBackend
    public let isInstalled: Bool
    public let supportedAPIs: String
    public let primaryArtifactName: String

    public var id: String { backend.rawValue }

    public init(
        backend: HostWineGraphicsBackend,
        isInstalled: Bool,
        supportedAPIs: String,
        primaryArtifactName: String
    ) {
        self.backend = backend
        self.isInstalled = isInstalled
        self.supportedAPIs = supportedAPIs
        self.primaryArtifactName = primaryArtifactName
    }
}

/// Consolidated runtime status summary for Rosetta 2, WhiskyWine, and the three graphics engines.
public struct RuntimeEnginesStatusSummary: Codable, Sendable, Equatable {
    public let rosettaInstalled: Bool
    public let whiskyWineInstalled: Bool
    public let whiskyWineVersionString: String?
    public let availableBackends: HostAvailableWineBackends
    public let engines: [RuntimeGraphicsEngineEntry]
    public let defaultDX11PerformanceRoute: HostWineBackendRoute
    public let defaultDX11CompatibilityRoute: HostWineBackendRoute
    public let defaultDX12Route: HostWineBackendRoute

    public init(
        rosettaInstalled: Bool,
        whiskyWineInstalled: Bool,
        whiskyWineVersionString: String?,
        availableBackends: HostAvailableWineBackends
    ) {
        self.rosettaInstalled = rosettaInstalled
        self.whiskyWineInstalled = whiskyWineInstalled
        self.whiskyWineVersionString = whiskyWineVersionString
        self.availableBackends = availableBackends
        self.engines = [
            RuntimeGraphicsEngineEntry(
                backend: .dxmt,
                isInstalled: availableBackends.hasDXMT,
                supportedAPIs: "D3D10 / D3D11 -> Metal",
                primaryArtifactName: "DXMT/wine/x86_64-unix/winemetal.so"
            ),
            RuntimeGraphicsEngineEntry(
                backend: .d3dMetal,
                isInstalled: availableBackends.hasD3DMetal,
                supportedAPIs: "D3D11 / D3D12 -> Metal (GPTK)",
                primaryArtifactName: "Wine/lib/external/libd3dshared.dylib"
            ),
            RuntimeGraphicsEngineEntry(
                backend: .dxvk,
                isInstalled: availableBackends.hasDXVK,
                supportedAPIs: "D3D9 / D3D10 / D3D11 -> Vulkan -> MoltenVK",
                primaryArtifactName: "DXVK/x64/d3d11.dll"
            )
        ]
        self.defaultDX11PerformanceRoute = HostWineBackendRouter.route(
            apiRequirement: .directX11,
            preference: .performanceFirst,
            available: availableBackends
        )
        self.defaultDX11CompatibilityRoute = HostWineBackendRouter.route(
            apiRequirement: .directX11,
            preference: .compatibilityFallback,
            available: availableBackends
        )
        self.defaultDX12Route = HostWineBackendRouter.route(
            apiRequirement: .directX12,
            preference: .performanceFirst,
            available: availableBackends
        )
    }
}

extension WhiskyWineInstaller {
    /// Produces a consolidated snapshot of Rosetta 2, WhiskyWine, and the three DirectX engines.
    public static func runtimeEnginesSummary(
        fileManager: FileManager = .default,
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder,
        rosettaInstalled: Bool = Rosetta2.isRosettaInstalled
    ) -> RuntimeEnginesStatusSummary {
        let available = availableGraphicsBackends(fileManager: fileManager, libraryFolder: libraryFolder)
        let version: SemanticVersion?
        if libraryFolder == WhiskyWineInstaller.libraryFolder {
            version = whiskyWineVersion()
        } else {
            let plistURL = libraryFolder.appending(path: "WhiskyWineVersion.plist")
            if let data = try? Data(contentsOf: plistURL),
               let decoded = try? PropertyListDecoder().decode(WhiskyWineVersion.self, from: data) {
                version = decoded.version
            } else {
                version = nil
            }
        }
        return RuntimeEnginesStatusSummary(
            rosettaInstalled: rosettaInstalled,
            whiskyWineInstalled: version != nil,
            whiskyWineVersionString: version.map { String(describing: $0) },
            availableBackends: available
        )
    }
}
