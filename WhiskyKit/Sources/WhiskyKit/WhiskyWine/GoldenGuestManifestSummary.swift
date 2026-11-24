// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
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

/// Decoded metadata from `golden-guest-manifest.json` with resilient key aliases.
public struct GoldenGuestBaselineManifest: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let guestID: String
    public let driverVersion: String?
    public let qemuProfile: String?
    public let securityInvariantsPassed: Bool?
    public let imageSHA256: String?
    public let capturedAt: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case camelSchemaVersion = "schemaVersion"
        case guestID = "guest_id"
        case camelGuestID = "guestId"
        case goldenID = "golden_id"
        case camelGoldenID = "goldenId"
        case driverVersion = "driver_version"
        case camelDriverVersion = "driverVersion"
        case qemuProfile = "qemu_profile"
        case camelQemuProfile = "qemuProfile"
        case securityInvariantsPassed = "security_invariants_passed"
        case camelSecurityInvariantsPassed = "securityInvariantsPassed"
        case imageSHA256 = "image_sha256"
        case camelImageSHA256 = "imageSha256"
        case sha256
        case capturedAt = "captured_at"
        case camelCapturedAt = "capturedAt"
    }

    public init(
        schemaVersion: String,
        guestID: String,
        driverVersion: String? = nil,
        qemuProfile: String? = nil,
        securityInvariantsPassed: Bool? = nil,
        imageSHA256: String? = nil,
        capturedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.guestID = guestID
        self.driverVersion = driverVersion
        self.qemuProfile = qemuProfile
        self.securityInvariantsPassed = securityInvariantsPassed
        self.imageSHA256 = imageSHA256
        self.capturedAt = capturedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(String.self, forKey: .camelSchemaVersion)
            ?? "1.0.0"
        guestID = try container.decodeIfPresent(String.self, forKey: .guestID)
            ?? container.decodeIfPresent(String.self, forKey: .camelGuestID)
            ?? container.decodeIfPresent(String.self, forKey: .goldenID)
            ?? container.decodeIfPresent(String.self, forKey: .camelGoldenID)
            ?? "golden-win11-arm64-v1"
        driverVersion = try container.decodeIfPresent(String.self, forKey: .driverVersion)
            ?? container.decodeIfPresent(String.self, forKey: .camelDriverVersion)
        qemuProfile = try container.decodeIfPresent(String.self, forKey: .qemuProfile)
            ?? container.decodeIfPresent(String.self, forKey: .camelQemuProfile)
        securityInvariantsPassed = try container.decodeIfPresent(Bool.self, forKey: .securityInvariantsPassed)
            ?? container.decodeIfPresent(Bool.self, forKey: .camelSecurityInvariantsPassed)
        imageSHA256 = try container.decodeIfPresent(String.self, forKey: .imageSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .camelImageSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .sha256)
        capturedAt = try container.decodeIfPresent(String.self, forKey: .capturedAt)
            ?? container.decodeIfPresent(String.self, forKey: .camelCapturedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(guestID, forKey: .guestID)
        try container.encodeIfPresent(driverVersion, forKey: .driverVersion)
        try container.encodeIfPresent(qemuProfile, forKey: .qemuProfile)
        try container.encodeIfPresent(securityInvariantsPassed, forKey: .securityInvariantsPassed)
        try container.encodeIfPresent(imageSHA256, forKey: .imageSHA256)
        try container.encodeIfPresent(capturedAt, forKey: .capturedAt)
    }
}

/// Honest read-only gate status reflecting Window 5C interface-proposal preconditions.
public struct GuestSurfaceIntegrationGateStatus: Codable, Sendable, Equatable {
    public let contractRevision: Int
    public let snapshotRevision: Int
    public let supportsRealGuestScanout: Bool
    public let supportsVirtualHIDSink: Bool
    public let supportsSignedWindowsVZBoot: Bool
    public let gameShellEntryEnabled: Bool

    public static let current = GuestSurfaceIntegrationGateStatus(
        contractRevision: 2,
        snapshotRevision: 4,
        supportsRealGuestScanout: false,
        supportsVirtualHIDSink: false,
        supportsSignedWindowsVZBoot: false,
        gameShellEntryEnabled: false
    )
}

/// Unified host runtime lock + golden guest baseline + 5C integration gate self-check summary.
public struct UnifiedRuntimeBaselineReport: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let runtimeManifestSHA256: String?
    public let runtimeVerification: RuntimeManifestVerificationReport?
    public let goldenGuestState: GoldenGuestManifestState
    public let goldenGuestManifestSHA256: String?
    public let goldenGuestManifest: GoldenGuestBaselineManifest?
    public let guestSurfaceGate: GuestSurfaceIntegrationGateStatus
    public let hostIntegrity: RuntimeIntegrityReport

    public static func collect(
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder,
        runtimeManifestURL: URL? = nil,
        goldenManifestURL: URL? = nil,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UnifiedRuntimeBaselineReport {
        let resolvedRuntimeURL = runtimeManifestURL ?? defaultRuntimeManifestURL(bundle: bundle)
        let runtimeData = resolvedRuntimeURL.flatMap { try? Data(contentsOf: $0) }
        let runtimeSHA = runtimeData.map(sha256Hex(of:))
        let runtimeManifest = runtimeData.flatMap { try? JSONDecoder().decode(RuntimeManifest.self, from: $0) }
        let verification = runtimeManifest.map {
            RuntimeManifestVerifier.verify(manifest: $0, in: libraryFolder, fileManager: fileManager)
        }

        let goldenResult = GoldenGuestManifestInspector.inspect(
            explicitURL: goldenManifestURL,
            bundle: bundle,
            fileManager: fileManager,
            environment: environment
        )

        return UnifiedRuntimeBaselineReport(
            schemaVersion: "1.0.0",
            runtimeManifestSHA256: runtimeSHA,
            runtimeVerification: verification,
            goldenGuestState: goldenResult.state,
            goldenGuestManifestSHA256: goldenResult.sha256,
            goldenGuestManifest: goldenResult.manifest,
            guestSurfaceGate: .current,
            hostIntegrity: RuntimeIntegrityAttestor.currentReport()
        )
    }

    private static func defaultRuntimeManifestURL(bundle: Bundle) -> URL? {
        if let url = bundle.url(
            forResource: RuntimeManifest.resourceName,
            withExtension: RuntimeManifest.resourceExtension
        ) {
            return url
        }
        return RuntimeManifestVerifier.defaultAppBundleURL()?
            .appending(path: "Contents/Resources/runtime-manifest.json")
    }

    fileprivate static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Discovers and safely inspects `golden-guest-manifest.json` without failing when uninitialized.
public enum GoldenGuestManifestInspector {
    public struct Result: Sendable, Equatable {
        public let state: GoldenGuestManifestState
        public let sha256: String?
        public let manifest: GoldenGuestBaselineManifest?
    }

    public static func inspect(
        explicitURL: URL? = nil,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result {
        if let explicitURL {
            return load(at: explicitURL, fileManager: fileManager)
        }
        for candidate in candidateURLs(bundle: bundle, fileManager: fileManager, environment: environment)
        where fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            return load(at: candidate, fileManager: fileManager)
        }
        return Result(state: .uninitialized, sha256: nil, manifest: nil)
    }

    private static func load(at url: URL, fileManager: FileManager) -> Result {
        let path = url.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path),
              let data = try? Data(contentsOf: url) else {
            return Result(state: .uninitialized, sha256: nil, manifest: nil)
        }
        let digest = UnifiedRuntimeBaselineReport.sha256Hex(of: data)
        guard let decoded = try? JSONDecoder().decode(GoldenGuestBaselineManifest.self, from: data) else {
            return Result(state: .invalid, sha256: digest, manifest: nil)
        }
        return Result(state: .ready, sha256: digest, manifest: decoded)
    }

    private static func candidateURLs(
        bundle: Bundle,
        fileManager: FileManager,
        environment: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []
        if let envPath = environment["WHISKY_GOLDEN_GUEST_MANIFEST"], !envPath.isEmpty {
            candidates.append(URL(fileURLWithPath: envPath))
        }
        if let bundled = bundle.url(forResource: "golden-guest-manifest", withExtension: "json") {
            candidates.append(bundled)
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(
                appSupport.appending(path: "com.isaacmarovitz.Whisky/golden-guest-manifest.json")
            )
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appending(path: "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"))
        candidates.append(cwd.appending(path: "Whisky/Modules/guest-golden/golden-guest-manifest.json"))
        return candidates
    }
}
