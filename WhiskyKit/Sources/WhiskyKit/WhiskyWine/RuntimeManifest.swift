// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Lifecycle state for an entry declared in `runtime-manifest.json`.
public enum RuntimeManifestComponentStatus: String, Codable, Sendable, Equatable {
    case locked
    case reserved
}

/// One locked file artifact and its expected SHA-256 hex digest.
public struct RuntimeLockedArtifact: Codable, Sendable, Equatable {
    public let name: String
    public let relativePath: String
    public let alternateRelativePaths: [String]
    public let sha256: String

    public init(
        name: String,
        relativePath: String,
        alternateRelativePaths: [String] = [],
        sha256: String
    ) {
        self.name = name
        self.relativePath = relativePath
        self.alternateRelativePaths = alternateRelativePaths
        self.sha256 = sha256
    }

    public var candidateRelativePaths: [String] {
        [relativePath] + alternateRelativePaths
    }
}

/// A runtime engine or core component tracked by `runtime-manifest.json`.
public struct RuntimeComponentLock: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let version: String
    public let status: RuntimeManifestComponentStatus
    public let supportedAPIs: String
    public let artifacts: [RuntimeLockedArtifact]

    public init(
        id: String,
        displayName: String,
        version: String,
        status: RuntimeManifestComponentStatus,
        supportedAPIs: String,
        artifacts: [RuntimeLockedArtifact]
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.status = status
        self.supportedAPIs = supportedAPIs
        self.artifacts = artifacts
    }
}

/// Bundled manifest locking verified laboratory runtime component versions and SHA-256 digests.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public static let resourceName = "runtime-manifest"
    public static let resourceExtension = "json"

    public let schemaVersion: String
    public let owner: String
    public let capturedAt: String
    public let baselineSource: String
    public let components: [RuntimeComponentLock]

    public init(
        schemaVersion: String,
        owner: String,
        capturedAt: String,
        baselineSource: String,
        components: [RuntimeComponentLock]
    ) {
        self.schemaVersion = schemaVersion
        self.owner = owner
        self.capturedAt = capturedAt
        self.baselineSource = baselineSource
        self.components = components
    }

    public static func load(from bundle: Bundle = .main) throws -> RuntimeManifest {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(fromFileURL: url)
    }

    public static func load(fromFileURL url: URL) throws -> RuntimeManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
}

/// Verification outcome for a single locked runtime component.
public enum RuntimeComponentVerificationState: String, Codable, Sendable, Equatable {
    case verified
    case mismatch
    case missing
    case reserved

    public var localizationKey: String {
        "settings.manifest.state.\(rawValue)"
    }
}

/// Detailed verification record for one artifact file.
public struct RuntimeArtifactVerification: Codable, Sendable, Equatable {
    public let name: String
    public let expectedSHA256: String
    public let actualSHA256: String?
    public let resolvedRelativePath: String?
    public let matched: Bool

    public init(
        name: String,
        expectedSHA256: String,
        actualSHA256: String?,
        resolvedRelativePath: String?,
        matched: Bool
    ) {
        self.name = name
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.resolvedRelativePath = resolvedRelativePath
        self.matched = matched
    }
}

/// Detailed verification record for one runtime component.
public struct RuntimeComponentVerification: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let lockedVersion: String
    public let state: RuntimeComponentVerificationState
    public let artifacts: [RuntimeArtifactVerification]

    public init(
        id: String,
        displayName: String,
        lockedVersion: String,
        state: RuntimeComponentVerificationState,
        artifacts: [RuntimeArtifactVerification]
    ) {
        self.id = id
        self.displayName = displayName
        self.lockedVersion = lockedVersion
        self.state = state
        self.artifacts = artifacts
    }
}

/// Aggregated verification result across all components in `runtime-manifest.json`.
public struct RuntimeManifestVerificationReport: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let libraryPath: String
    public let components: [RuntimeComponentVerification]

    public var allLockedComponentsVerified: Bool {
        let locked = components.filter { $0.state != .reserved }
        return !locked.isEmpty && locked.allSatisfy { $0.state == .verified }
    }

    public var hasMismatch: Bool {
        components.contains { $0.state == .mismatch }
    }

    public init(
        schemaVersion: String,
        libraryPath: String,
        components: [RuntimeComponentVerification]
    ) {
        self.schemaVersion = schemaVersion
        self.libraryPath = libraryPath
        self.components = components
    }
}

/// Computes real SHA-256 digests over installed runtime binaries against `RuntimeManifest`.
public enum RuntimeManifestVerifier {
    public static func sha256Hex(forFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(
        manifest: RuntimeManifest,
        in libraryFolder: URL = WhiskyWineInstaller.libraryFolder,
        fileManager: FileManager = .default
    ) -> RuntimeManifestVerificationReport {
        let results = manifest.components.map { component in
            verifyComponent(component, in: libraryFolder, fileManager: fileManager)
        }
        return RuntimeManifestVerificationReport(
            schemaVersion: manifest.schemaVersion,
            libraryPath: libraryFolder.path(percentEncoded: false),
            components: results
        )
    }

    private static func verifyComponent(
        _ component: RuntimeComponentLock,
        in libraryFolder: URL,
        fileManager: FileManager
    ) -> RuntimeComponentVerification {
        if component.status == .reserved || component.artifacts.isEmpty {
            return RuntimeComponentVerification(
                id: component.id,
                displayName: component.displayName,
                lockedVersion: component.version,
                state: .reserved,
                artifacts: []
            )
        }

        let artifactResults = component.artifacts.map {
            verifyArtifact($0, in: libraryFolder, fileManager: fileManager)
        }
        let anyMismatch = artifactResults.contains { $0.resolvedRelativePath != nil && !$0.matched }
        let anyMissing = artifactResults.contains { $0.resolvedRelativePath == nil }
        let state: RuntimeComponentVerificationState = anyMismatch ? .mismatch : (anyMissing ? .missing : .verified)

        return RuntimeComponentVerification(
            id: component.id,
            displayName: component.displayName,
            lockedVersion: component.version,
            state: state,
            artifacts: artifactResults
        )
    }

    private static func verifyArtifact(
        _ artifact: RuntimeLockedArtifact,
        in libraryFolder: URL,
        fileManager: FileManager
    ) -> RuntimeArtifactVerification {
        guard let (relPath, fileURL) = resolveArtifact(artifact, in: libraryFolder, fileManager: fileManager) else {
            return RuntimeArtifactVerification(
                name: artifact.name,
                expectedSHA256: artifact.sha256,
                actualSHA256: nil,
                resolvedRelativePath: nil,
                matched: false
            )
        }
        let actual = try? sha256Hex(forFileAt: fileURL)
        return RuntimeArtifactVerification(
            name: artifact.name,
            expectedSHA256: artifact.sha256,
            actualSHA256: actual,
            resolvedRelativePath: relPath,
            matched: actual?.lowercased() == artifact.sha256.lowercased()
        )
    }

    private static func resolveArtifact(
        _ artifact: RuntimeLockedArtifact,
        in libraryFolder: URL,
        fileManager: FileManager
    ) -> (String, URL)? {
        for rel in artifact.candidateRelativePaths {
            let url = libraryFolder.appending(path: rel)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                return (rel, url)
            }
        }
        return nil
    }
}
