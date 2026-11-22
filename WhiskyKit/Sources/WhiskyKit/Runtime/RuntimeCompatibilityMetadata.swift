// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Explicit four-state representation for platform security features (TPM2, Secure Boot, IOMMU, VBS, HVCI).
public enum RuntimeSecurityFeatureState: String, Codable, Equatable, Hashable, Sendable {
    case absent
    case presentDisabled = "present_disabled"
    case enabled
    case unknown
}

/// Static distribution and snapshot metadata optionally attached to a GameCompatibilityProfile.
public struct GameProfileMetadata: Codable, Equatable, Hashable, Sendable {
    public let distributionID: String?
    public let clientPlatform: String?
    public let sourceSnapshotID: String?

    enum CodingKeys: String, CodingKey {
        case distributionID = "distribution_id"
        case clientPlatform = "client_platform"
        case sourceSnapshotID = "source_snapshot_id"
    }

    public init(
        distributionID: String? = nil,
        clientPlatform: String? = nil,
        sourceSnapshotID: String? = nil
    ) {
        self.distributionID = distributionID
        self.clientPlatform = clientPlatform
        self.sourceSnapshotID = sourceSnapshotID
    }
}

/// Neutral compatibility and evidence metadata proposed by module-f (task 06).
/// All fields default to nil (unknown / not sampled) so legacy callers and records stay compatible.
public struct RuntimeEvidenceMetadata: Codable, Equatable, Hashable, Sendable {
    public let distributionID: String?
    public let clientPlatform: String?
    public let hostCPUArchitecture: String?
    public let guestCPUArchitecture: String?
    public let guestOSBuild: String?
    public let guestOSEdition: String?
    public let securityCapabilities: [String: RuntimeSecurityFeatureState]?
    public let securityEnabledState: [String: RuntimeSecurityFeatureState]?
    public let installedClientBuild: String?
    public let driverBinaryMachine: String?
    public let driverFileVersion: String?
    public let sourceSnapshotID: String?

    enum CodingKeys: String, CodingKey {
        case distributionID = "distribution_id"
        case clientPlatform = "client_platform"
        case hostCPUArchitecture = "host_cpu_architecture"
        case guestCPUArchitecture = "guest_cpu_architecture"
        case guestOSBuild = "guest_os_build"
        case guestOSEdition = "guest_os_edition"
        case securityCapabilities = "security_capabilities"
        case securityEnabledState = "security_enabled_state"
        case installedClientBuild = "installed_client_build"
        case driverBinaryMachine = "driver_binary_machine"
        case driverFileVersion = "driver_file_version"
        case sourceSnapshotID = "source_snapshot_id"
    }

    public init(
        distributionID: String? = nil,
        clientPlatform: String? = nil,
        hostCPUArchitecture: String? = nil,
        guestCPUArchitecture: String? = nil,
        guestOSBuild: String? = nil,
        guestOSEdition: String? = nil,
        securityCapabilities: [String: RuntimeSecurityFeatureState]? = nil,
        securityEnabledState: [String: RuntimeSecurityFeatureState]? = nil,
        installedClientBuild: String? = nil,
        driverBinaryMachine: String? = nil,
        driverFileVersion: String? = nil,
        sourceSnapshotID: String? = nil
    ) {
        self.distributionID = distributionID
        self.clientPlatform = clientPlatform
        self.hostCPUArchitecture = hostCPUArchitecture
        self.guestCPUArchitecture = guestCPUArchitecture
        self.guestOSBuild = guestOSBuild
        self.guestOSEdition = guestOSEdition
        self.securityCapabilities = securityCapabilities
        self.securityEnabledState = securityEnabledState
        self.installedClientBuild = installedClientBuild
        self.driverBinaryMachine = driverBinaryMachine
        self.driverFileVersion = driverFileVersion
        self.sourceSnapshotID = sourceSnapshotID
    }
}
