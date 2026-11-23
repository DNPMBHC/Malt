// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bridges RemotePhysicsBackend into the unified RuntimeCoordinator capability/session surface
/// without blocking synchronous planning on network I/O.
public struct RemotePhysicsRuntimeBackend: RuntimeBackend {
    public let kind: RuntimeBackendKind = .remotePhysics
    public let executionDomain: RemotePhysicsExecutionDomain = .remotePhysicalWindows
    public let provider: any RemotePhysicsProvider
    private let cachedAvailability: RemotePhysicsAvailability
    private let evidence: RuntimeEvidenceProvider

    public init(
        provider: any RemotePhysicsProvider = UnconfiguredRemotePhysicsProvider(),
        availability: RemotePhysicsAvailability? = nil,
        evidence: @escaping RuntimeEvidenceProvider = { _, _ in
            RuntimeEvidence()
        }
    ) {
        self.provider = provider
        if let availability {
            self.cachedAvailability = availability
        } else if let config = provider.configuration {
            self.cachedAvailability = (try? config.validate()) != nil ? .unverified : .unconfigured
        } else {
            self.cachedAvailability = .unconfigured
        }
        self.evidence = evidence
    }

    public func capability(for profile: GameCompatibilityProfile?, host: RuntimeHostSnapshot) -> RuntimeCapability {
        capability(for: profile, host: host, availability: cachedAvailability)
    }

    public func refreshCapability(
        for profile: GameCompatibilityProfile?,
        host: RuntimeHostSnapshot
    ) async -> RuntimeCapability {
        let liveAvailability = await provider.checkAvailability()
        return capability(for: profile, host: host, availability: liveAvailability)
    }

    public func capability(
        for profile: GameCompatibilityProfile?,
        host: RuntimeHostSnapshot,
        availability: RemotePhysicsAvailability
    ) -> RuntimeCapability {
        let compatibility = profile?.remotePhysicsCompatibility ?? .unknown
        let readiness: RuntimeBackendReadiness
        var issues: [RuntimeIssue] = []

        switch availability {
        case .unconfigured:
            readiness = .unconfigured
            issues.append(.remotePhysicsUnconfigured)
        case .unverified:
            readiness = .unavailable
            issues.append(.remotePhysicsUnverified)
        case .clientMissing:
            readiness = .unavailable
            issues.append(.remotePhysicsClientMissing)
        case .hostUnreachable:
            readiness = .unavailable
            issues.append(.remotePhysicsHostUnreachable)
        case .ready:
            readiness = .ready
        }

        if let config = provider.configuration {
            do {
                try config.validate()
            } catch {
                if !issues.contains(.remotePhysicsUnconfigured) {
                    issues.append(.remotePhysicsUnconfigured)
                }
            }
        }

        return RuntimeCapability(
            backend: kind,
            compatibility: compatibility,
            readiness: readiness,
            evidence: evidence(kind, profile),
            issues: issues
        )
    }

    public func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        let liveAvailability = await provider.checkAvailability()
        let liveCapability = capability(for: request.profile, host: request.host, availability: liveAvailability)
        guard liveCapability.canLaunch else {
            let title = request.profile?.displayName
                ?? provider.configuration?.applicationName
                ?? request.executableURL.lastPathComponent
            throw RuntimeLaunchError.blocked(title, liveCapability.issues)
        }
        do {
            return try await provider.start(host: request.host)
        } catch let error as RemotePhysicsError {
            throw Self.mapError(error, title: request.profile?.displayName ?? request.executableURL.lastPathComponent)
        }
    }

    private static func mapError(_ error: RemotePhysicsError, title: String) -> RuntimeLaunchError {
        switch error {
        case .unconfigured, .forbiddenPlaintextCredential, .invalidConfiguration, .forbiddenShellClient:
            return .blocked(title, [.remotePhysicsUnconfigured])
        case .clientMissing:
            return .blocked(title, [.remotePhysicsClientMissing])
        case .hostUnreachable:
            return .blocked(title, [.remotePhysicsHostUnreachable])
        case .connectionTimedOut:
            return .blocked(title, [.remotePhysicsTimeout])
        }
    }
}
