// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import MetalFX

public enum RuntimeBackendKind: String, Codable, CaseIterable, Sendable {
    case wine
    case windowsGuest

    public var title: String {
        switch self {
        case .wine: return "Wine translation"
        case .windowsGuest: return "Windows guest"
        }
    }

    public var localizationKey: String {
        switch self {
        case .wine: return "runtime.backend.wine"
        case .windowsGuest: return "runtime.backend.windowsGuest"
        }
    }
}

public enum AntiCheatSystem: String, Codable, Sendable {
    case none
    case riotVanguard
    case easyAntiCheat
    case unknown

    public var title: String {
        switch self {
        case .none: return "None detected"
        case .riotVanguard: return "Riot Vanguard"
        case .easyAntiCheat: return "Easy Anti-Cheat"
        case .unknown: return "Unknown"
        }
    }

    public var localizationKey: String {
        switch self {
        case .none: return "runtime.protection.none"
        case .riotVanguard: return "runtime.protection.riotVanguard"
        case .easyAntiCheat: return "runtime.protection.easyAntiCheat"
        case .unknown: return "runtime.protection.unknown"
        }
    }
}

public enum RuntimeCompatibility: String, Codable, Sendable {
    case supported
    case unknown
    case requiresWindowsKernel
    case vendorRestricted
    case unavailable

    public var title: String {
        switch self {
        case .supported: return "Supported by this backend"
        case .unknown: return "Needs verification"
        case .requiresWindowsKernel: return "Requires a Windows kernel"
        case .vendorRestricted: return "Requires vendor support"
        case .unavailable: return "Backend unavailable"
        }
    }

    public var localizationKey: String {
        switch self {
        case .supported: return "runtime.compatibility.supported"
        case .unknown: return "runtime.compatibility.unknown"
        case .requiresWindowsKernel: return "runtime.compatibility.requiresWindowsKernel"
        case .vendorRestricted: return "runtime.compatibility.vendorRestricted"
        case .unavailable: return "runtime.compatibility.unavailable"
        }
    }
}

public struct GameCompatibilityProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let executableNames: Set<String>
    public let antiCheat: AntiCheatSystem
    public let wineCompatibility: RuntimeCompatibility
    public let windowsGuestCompatibility: RuntimeCompatibility
    public let notes: String
    public let metadata: GameProfileMetadata?

    public init(
        id: String,
        displayName: String,
        executableNames: Set<String>,
        antiCheat: AntiCheatSystem,
        wineCompatibility: RuntimeCompatibility,
        windowsGuestCompatibility: RuntimeCompatibility,
        notes: String,
        metadata: GameProfileMetadata? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.antiCheat = antiCheat
        self.wineCompatibility = wineCompatibility
        self.windowsGuestCompatibility = windowsGuestCompatibility
        self.notes = notes
        self.metadata = metadata
    }

    public var notesLocalizationKey: String { "runtime.profile.\(id)" }

    public func localizedNotes(in bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: notesLocalizationKey, value: notes, table: nil)
    }

    public func matches(executableURL: URL) -> Bool {
        executableNames.contains(executableURL.lastPathComponent.lowercased())
    }
}

public enum HostThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public var title: String { rawValue.capitalized }

    public var localizationKey: String { "runtime.thermalState.\(rawValue)" }
}

public enum RuntimePerformancePolicy: String, Codable, Sendable {
    case maximumPerformance
    case balanced
    case conserveEnergy

    public var title: String {
        switch self {
        case .maximumPerformance: return "Maximum performance"
        case .balanced: return "Balanced"
        case .conserveEnergy: return "Conserve energy"
        }
    }

    public var localizationKey: String {
        switch self {
        case .maximumPerformance: return "runtime.performancePolicy.maximumPerformance"
        case .balanced: return "runtime.performancePolicy.balanced"
        case .conserveEnergy: return "runtime.performancePolicy.conserveEnergy"
        }
    }
}

public struct RuntimeHostSnapshot: Codable, Equatable, Sendable {
    public struct OSVersion: Codable, Equatable, Sendable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var title: String { "\(major).\(minor).\(patch)" }
    }

    public let operatingSystemVersion: OSVersion
    public let architecture: String
    public let isAppleSilicon: Bool
    public let gameModePlatformAvailable: Bool
    public let isMacOS27OrLater: Bool
    public let thermalState: HostThermalState
    public let isLowPowerModeEnabled: Bool
    public let metalDeviceName: String?
    public let metalFXSpatialScalingAvailable: Bool
    public let metalFXTemporalScalingAvailable: Bool
    public let gpuDeveloperToolsAvailable: Bool

    public init(
        operatingSystemVersion: OSVersion,
        architecture: String,
        isAppleSilicon: Bool,
        gameModePlatformAvailable: Bool,
        isMacOS27OrLater: Bool = false,
        thermalState: HostThermalState,
        isLowPowerModeEnabled: Bool,
        metalDeviceName: String?,
        metalFXSpatialScalingAvailable: Bool,
        metalFXTemporalScalingAvailable: Bool,
        gpuDeveloperToolsAvailable: Bool
    ) {
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.isAppleSilicon = isAppleSilicon
        self.gameModePlatformAvailable = gameModePlatformAvailable
        self.isMacOS27OrLater = isMacOS27OrLater
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.metalDeviceName = metalDeviceName
        self.metalFXSpatialScalingAvailable = metalFXSpatialScalingAvailable
        self.metalFXTemporalScalingAvailable = metalFXTemporalScalingAvailable
        self.gpuDeveloperToolsAvailable = gpuDeveloperToolsAvailable
    }

    public var performancePolicy: RuntimePerformancePolicy {
        if isLowPowerModeEnabled || thermalState == .critical { return .conserveEnergy }
        if thermalState == .serious { return .balanced }
        return .maximumPerformance
    }

    public static func current(
        processInfo: ProcessInfo = .processInfo,
        metalDevices: [any MTLDevice] = MTLCopyAllDevices()
    ) -> RuntimeHostSnapshot {
        let version = processInfo.operatingSystemVersion
        let device = metalDevices.first(where: { !$0.isLowPower }) ?? metalDevices.first
        let architecture = currentArchitecture()
        return RuntimeHostSnapshot(
            operatingSystemVersion: OSVersion(
                major: version.majorVersion,
                minor: version.minorVersion,
                patch: version.patchVersion
            ),
            architecture: architecture,
            isAppleSilicon: architecture == "arm64",
            gameModePlatformAvailable: architecture == "arm64" && version.majorVersion >= 14,
            isMacOS27OrLater: version.majorVersion >= 27,
            thermalState: HostThermalState(processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            metalDeviceName: device?.name,
            metalFXSpatialScalingAvailable: device.map {
                MTLFXSpatialScalerDescriptor.supportsDevice($0)
            } ?? false,
            metalFXTemporalScalingAvailable: device.map {
                MTLFXTemporalScalerDescriptor.supportsDevice($0)
            } ?? false,
            gpuDeveloperToolsAvailable: FileManager.default.fileExists(
                atPath: "/usr/bin/xcrun"
            )
        )
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// Automatic matching checks the selected basename and any symbolic link target basename.
public enum RuntimeTargetSelection: Codable, Equatable, Hashable, Sendable {
    case automatic
    case ordinary
    case profile(String)

    public var commandLineValue: String {
        switch self {
        case .automatic: "auto"
        case .ordinary: "ordinary"
        case .profile(let id): id
        }
    }
}

public enum RuntimeBackendReadiness: String, Equatable, Sendable {
    case ready, unconfigured, unavailable
    public var localizationKey: String { "runtime.readiness.\(rawValue)" }
}

public enum RuntimeKernelDiagnostics: String, Codable, Equatable, Sendable {
    case unknown, notApplicable, selfProbeVerified, failed
    public var localizationKey: String { "runtime.kernel.\(rawValue)" }
}

public enum RuntimeVendorSupport: String, Codable, Equatable, Sendable {
    case unknown, confirmed, restricted, unsupported
    public var localizationKey: String { "runtime.vendor.\(rawValue)" }
}

public enum RuntimeGameVerification: String, Codable, Equatable, Sendable {
    case untested, verified, failed
    public var localizationKey: String { "runtime.game.\(rawValue)" }
}

public typealias RuntimeEvidenceProvider = @Sendable (RuntimeBackendKind, GameCompatibilityProfile?) -> RuntimeEvidence

public struct RuntimeEvidence: Codable, Equatable, Sendable {
    public let kernelDiagnostics: RuntimeKernelDiagnostics
    public let vendorSupport: RuntimeVendorSupport
    public let gameVerification: RuntimeGameVerification
    public let metadata: RuntimeEvidenceMetadata?

    public init(kernelDiagnostics: RuntimeKernelDiagnostics = .unknown,
                vendorSupport: RuntimeVendorSupport = .unknown,
                gameVerification: RuntimeGameVerification = .untested,
                metadata: RuntimeEvidenceMetadata? = nil) {
        self.kernelDiagnostics = kernelDiagnostics
        self.vendorSupport = vendorSupport
        self.gameVerification = gameVerification
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kernelDiagnostics = try container.decodeIfPresent(RuntimeKernelDiagnostics.self, forKey: .kernelDiagnostics)
            ?? .unknown
        vendorSupport = try container.decodeIfPresent(RuntimeVendorSupport.self, forKey: .vendorSupport) ?? .unknown
        gameVerification = try container.decodeIfPresent(RuntimeGameVerification.self, forKey: .gameVerification)
            ?? .untested
        metadata = try container.decodeIfPresent(RuntimeEvidenceMetadata.self, forKey: .metadata)
    }
}

public struct RuntimeCapability: Equatable, Sendable {
    public let backend: RuntimeBackendKind
    public let compatibility: RuntimeCompatibility
    public let readiness: RuntimeBackendReadiness
    public let evidence: RuntimeEvidence
    public let issues: [RuntimeIssue]
    public var canLaunch: Bool { readiness == .ready && issues.isEmpty }
    public var reasons: [String] { issues.map { $0.localized() } }
    public var kernelDiagnostics: RuntimeKernelDiagnostics { evidence.kernelDiagnostics }
    public var vendorSupport: RuntimeVendorSupport { evidence.vendorSupport }
    public var gameVerification: RuntimeGameVerification { evidence.gameVerification }

    public init(backend: RuntimeBackendKind, compatibility: RuntimeCompatibility,
                readiness: RuntimeBackendReadiness, evidence: RuntimeEvidence,
                issues: [RuntimeIssue] = []) {
        self.backend = backend
        self.compatibility = compatibility
        self.readiness = readiness
        self.evidence = evidence
        self.issues = issues
    }
}

public struct RuntimePlan: Equatable, Sendable {
    public let profile: GameCompatibilityProfile?
    public let host: RuntimeHostSnapshot
    public var preferredBackend: RuntimeBackendKind { capability.backend }
    public let capability: RuntimeCapability
    public let storagePreflight: RuntimeStoragePreflight?

    public init(profile: GameCompatibilityProfile?, host: RuntimeHostSnapshot, capability: RuntimeCapability,
                storagePreflight: RuntimeStoragePreflight? = nil) {
        self.profile = profile
        self.host = host
        self.capability = capability
        self.storagePreflight = storagePreflight
    }

    public func wineResourcePolicy(dxvk: Bool, enabled: Bool) -> HostWineLaunchPolicy {
        HostWineLaunchPolicy(snapshot: host, graphicsBackend: dxvk ? .dxvk : .d3dMetal, enabled: enabled)
    }

    public func guestResourcePolicy(enabled: Bool) -> HostGuestLaunchPolicy {
        HostGuestLaunchPolicy(snapshot: host, enabled: enabled)
    }
}
