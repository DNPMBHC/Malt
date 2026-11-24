// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Status of the immutable `golden-guest-manifest.json` produced by Window 6A.
public enum GoldenGuestManifestState: String, Codable, Sendable, Equatable {
    case ready
    case uninitialized
    case invalid

    public var localizationKey: String {
        "settings.goldenGuest.state.\(rawValue)"
    }
}

private struct NestedGraphicsDriver: Decodable {
    let driverVersion: String?
    let featureLevel: String?
    let whqlReady: Bool?

    enum CodingKeys: String, CodingKey {
        case driverVersion = "driver_version"
        case featureLevel = "feature_level"
        case whqlReady = "whql_ready"
    }
}

private struct NestedQEMUProfile: Decodable {
    let backend: String?
    let displayHardware: String?
    let cpuCount: Int?
    let memoryMiB: Int?

    enum CodingKeys: String, CodingKey {
        case backend
        case displayHardware = "display_hardware"
        case cpuCount = "cpu_count"
        case memoryMiB = "memory_mib"
    }

    var summary: String {
        [
            backend,
            displayHardware,
            cpuCount.map { "\($0)vCPU" },
            memoryMiB.map { "\($0)MiB" }
        ].compactMap { $0 }.joined(separator: " / ")
    }
}

private struct NestedOptimizer: Decodable {
    let profileID: String?

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
    }
}

private struct NestedSecurityInvariants: Decodable {
    let qgaServiceRunning: Bool?
    let prismSignaturesValid: Bool?
    let tpmReady: Bool?
    let secureBootEnabled: Bool?
    let bcdSafe: Bool?
    let testSigningDisabled: Bool?

    enum CodingKeys: String, CodingKey {
        case qgaServiceRunning = "qga_service_running"
        case prismSignaturesValid = "prism_signatures_valid"
        case tpmReady = "tpm_ready"
        case secureBootEnabled = "secure_boot_enabled"
        case bcdSafe = "bcd_safe"
        case testSigningDisabled = "test_signing_disabled"
    }

    var allPassed: Bool? {
        let present = [
            qgaServiceRunning, prismSignaturesValid, tpmReady,
            secureBootEnabled, bcdSafe, testSigningDisabled
        ].compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.allSatisfy { $0 }
    }
}

private struct NestedFingerprints: Decodable {
    let goldenBundleSHA256: String?
    let goldenConfigSHA256: String?
    let goldenTotalBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case goldenBundleSHA256 = "golden_bundle_sha256"
        case goldenConfigSHA256 = "golden_config_sha256"
        case goldenTotalBytes = "golden_total_bytes"
    }
}

/// Decoded metadata from `golden-guest-manifest.json` supporting Window 6A's nested schema and flat aliases.
public struct GoldenGuestBaselineManifest: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let guestID: String
    public let status: String?
    public let driverVersion: String?
    public let featureLevel: String?
    public let whqlReady: Bool?
    public let qemuProfile: String?
    public let optimizerProfileID: String?
    public let securityInvariantsPassed: Bool?
    public let imageSHA256: String?
    public let goldenTotalBytes: Int64?
    public let capturedAt: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case camelSchemaVersion = "schemaVersion"
        case guestID = "guest_id"
        case camelGuestID = "guestId"
        case goldenID = "golden_id"
        case camelGoldenID = "goldenId"
        case status
        case driverVersion = "driver_version"
        case camelDriverVersion = "driverVersion"
        case featureLevel = "feature_level"
        case whqlReady = "whql_ready"
        case graphicsDriver = "graphics_driver"
        case qemuProfile = "qemu_profile"
        case camelQemuProfile = "qemuProfile"
        case optimizer
        case optimizerProfileID = "optimizer_profile_id"
        case securityInvariants = "security_invariants"
        case securityInvariantsPassed = "security_invariants_passed"
        case camelSecurityInvariantsPassed = "securityInvariantsPassed"
        case fingerprints
        case imageSHA256 = "image_sha256"
        case camelImageSHA256 = "imageSha256"
        case goldenTotalBytes = "golden_total_bytes"
        case sha256
        case capturedAt = "captured_at"
        case capturedAtUTC = "captured_at_utc"
        case camelCapturedAt = "capturedAt"
    }

    public init(
        schemaVersion: String,
        guestID: String,
        status: String? = nil,
        driverVersion: String? = nil,
        featureLevel: String? = nil,
        whqlReady: Bool? = nil,
        qemuProfile: String? = nil,
        optimizerProfileID: String? = nil,
        securityInvariantsPassed: Bool? = nil,
        imageSHA256: String? = nil,
        goldenTotalBytes: Int64? = nil,
        capturedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.guestID = guestID
        self.status = status
        self.driverVersion = driverVersion
        self.featureLevel = featureLevel
        self.whqlReady = whqlReady
        self.qemuProfile = qemuProfile
        self.optimizerProfileID = optimizerProfileID
        self.securityInvariantsPassed = securityInvariantsPassed
        self.imageSHA256 = imageSHA256
        self.goldenTotalBytes = goldenTotalBytes
        self.capturedAt = capturedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = Self.decodeSchemaVersion(from: container)
        guestID = try container.decodeIfPresent(String.self, forKey: .guestID)
            ?? container.decodeIfPresent(String.self, forKey: .camelGuestID)
            ?? container.decodeIfPresent(String.self, forKey: .goldenID)
            ?? container.decodeIfPresent(String.self, forKey: .camelGoldenID)
            ?? "golden-win11-arm64-v1"
        status = try container.decodeIfPresent(String.self, forKey: .status)

        let nestedDriver = try container.decodeIfPresent(NestedGraphicsDriver.self, forKey: .graphicsDriver)
        driverVersion = try nestedDriver?.driverVersion
            ?? container.decodeIfPresent(String.self, forKey: .driverVersion)
            ?? container.decodeIfPresent(String.self, forKey: .camelDriverVersion)
        featureLevel = try nestedDriver?.featureLevel
            ?? container.decodeIfPresent(String.self, forKey: .featureLevel)
        whqlReady = try nestedDriver?.whqlReady
            ?? container.decodeIfPresent(Bool.self, forKey: .whqlReady)

        if let nestedQEMU = try? container.decodeIfPresent(NestedQEMUProfile.self, forKey: .qemuProfile) {
            qemuProfile = nestedQEMU.summary
        } else {
            qemuProfile = try container.decodeIfPresent(String.self, forKey: .qemuProfile)
                ?? container.decodeIfPresent(String.self, forKey: .camelQemuProfile)
        }

        let nestedOptimizer = try container.decodeIfPresent(NestedOptimizer.self, forKey: .optimizer)
        optimizerProfileID = try nestedOptimizer?.profileID
            ?? container.decodeIfPresent(String.self, forKey: .optimizerProfileID)

        let nestedSecurity = try container.decodeIfPresent(
            NestedSecurityInvariants.self, forKey: .securityInvariants
        )
        securityInvariantsPassed = try nestedSecurity?.allPassed
            ?? container.decodeIfPresent(Bool.self, forKey: .securityInvariantsPassed)
            ?? container.decodeIfPresent(Bool.self, forKey: .camelSecurityInvariantsPassed)

        let nestedFingerprints = try container.decodeIfPresent(NestedFingerprints.self, forKey: .fingerprints)
        imageSHA256 = try nestedFingerprints?.goldenBundleSHA256
            ?? nestedFingerprints?.goldenConfigSHA256
            ?? container.decodeIfPresent(String.self, forKey: .imageSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .camelImageSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .sha256)
        goldenTotalBytes = try nestedFingerprints?.goldenTotalBytes
            ?? container.decodeIfPresent(Int64.self, forKey: .goldenTotalBytes)

        capturedAt = try container.decodeIfPresent(String.self, forKey: .capturedAtUTC)
            ?? container.decodeIfPresent(String.self, forKey: .capturedAt)
            ?? container.decodeIfPresent(String.self, forKey: .camelCapturedAt)
    }

    private static func decodeSchemaVersion(from container: KeyedDecodingContainer<CodingKeys>) -> String {
        if let str = try? container.decodeIfPresent(String.self, forKey: .schemaVersion) {
            return str
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion) {
            return String(intVal)
        }
        if let str = try? container.decodeIfPresent(String.self, forKey: .camelSchemaVersion) {
            return str
        }
        return "1.0.0"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(guestID, forKey: .guestID)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(driverVersion, forKey: .driverVersion)
        try container.encodeIfPresent(featureLevel, forKey: .featureLevel)
        try container.encodeIfPresent(whqlReady, forKey: .whqlReady)
        try container.encodeIfPresent(qemuProfile, forKey: .qemuProfile)
        try container.encodeIfPresent(optimizerProfileID, forKey: .optimizerProfileID)
        try container.encodeIfPresent(securityInvariantsPassed, forKey: .securityInvariantsPassed)
        try container.encodeIfPresent(imageSHA256, forKey: .imageSHA256)
        try container.encodeIfPresent(goldenTotalBytes, forKey: .goldenTotalBytes)
        try container.encodeIfPresent(capturedAt, forKey: .capturedAt)
    }
}
