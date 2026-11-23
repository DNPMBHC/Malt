// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RuntimeCoordinator: Sendable {
    public let wine: WineRuntimeBackend
    public let windowsGuest: WindowsGuestRuntimeBackend
    public let remotePhysics: RemotePhysicsRuntimeBackend
    private let storageChecker: RuntimeStoragePreflightChecker

    public init(
        guestProvider: any WindowsGuestProvider = UnconfiguredWindowsGuestProvider(),
        remotePhysicsProvider: any RemotePhysicsProvider = UnconfiguredRemotePhysicsProvider(),
        remotePhysicsAvailability: RemotePhysicsAvailability? = nil,
        wineAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(atPath: Wine.wineBinary.path(percentEncoded: false))
        },
        evidence: @escaping RuntimeEvidenceProvider = { backend, _ in
            RuntimeEvidence(kernelDiagnostics: backend == .wine ? .notApplicable : .unknown)
        },
        storageChecker: RuntimeStoragePreflightChecker = .init()
    ) {
        self.storageChecker = storageChecker
        self.wine = WineRuntimeBackend(isAvailable: wineAvailable, evidence: evidence)
        self.windowsGuest = WindowsGuestRuntimeBackend(provider: guestProvider, evidence: evidence)
        self.remotePhysics = RemotePhysicsRuntimeBackend(
            provider: remotePhysicsProvider,
            availability: remotePhysicsAvailability,
            evidence: evidence
        )
    }

    public func plan(for executableURL: URL, selection: RuntimeTargetSelection = .automatic,
                     backend: RuntimeBackendKind? = nil, host: RuntimeHostSnapshot = .current()) -> RuntimePlan {
        let detected = GameCompatibilityDatabase.profile(for: executableURL)
        var profile = detected
        var selectionIssue: RuntimeIssue?
        switch selection {
        case .automatic:
            if detected == nil && GameCompatibilityDatabase.requiresExplicitSelection(for: executableURL) {
                selectionIssue = .selectTarget
            }
        case .ordinary:
            if detected != nil { selectionIssue = .conflictingTarget }
        case .profile(let id):
            if let detected, detected.id != id {
                selectionIssue = .conflictingTarget
            } else if let selected = GameCompatibilityDatabase.profiles.first(where: { $0.id == id }) {
                profile = selected
            } else {
                selectionIssue = .unknownTarget
            }
        }

        let wineCapability = wine.capability(for: profile, host: host)
        // Never silently auto-route to remotePhysics when backend == nil; require explicit selection.
        let selectedBackend = backend ?? (profile != nil && !wineCapability.canLaunch ? .windowsGuest : .wine)
        let capability: RuntimeCapability
        switch selectedBackend {
        case .wine:
            capability = wineCapability
        case .windowsGuest:
            capability = windowsGuest.capability(for: profile, host: host)
        case .remotePhysics:
            capability = remotePhysics.capability(for: profile, host: host)
        }
        let resolved = RuntimeCapability(backend: selectedBackend, compatibility: capability.compatibility,
                                         readiness: capability.readiness, evidence: capability.evidence,
                                         issues: (selectionIssue.map { [$0] } ?? []) + capability.issues)
        return RuntimePlan(profile: profile, host: host, capability: resolved)
    }

    /// Recommends remotePhysicalWindows only when both local Wine and local Windows Guest are blocked.
    public func recommendsRemotePhysicsFallback(
        for executableURL: URL,
        selection: RuntimeTargetSelection = .automatic,
        host: RuntimeHostSnapshot = .current()
    ) -> Bool {
        let localWine = plan(for: executableURL, selection: selection, backend: .wine, host: host)
        let localGuest = plan(for: executableURL, selection: selection, backend: .windowsGuest, host: host)
        return !localWine.capability.canLaunch && !localGuest.capability.canLaunch
    }

    /// Async plan resolution that performs live reachability/client verification for remotePhysics.
    public func resolvePlan(
        for executableURL: URL,
        selection: RuntimeTargetSelection = .automatic,
        backend: RuntimeBackendKind? = nil,
        host: RuntimeHostSnapshot = .current()
    ) async -> RuntimePlan {
        let basePlan = plan(for: executableURL, selection: selection, backend: backend, host: host)
        guard basePlan.preferredBackend == .remotePhysics else { return basePlan }
        let liveCapability = await remotePhysics.refreshCapability(for: basePlan.profile, host: host)
        let selectionIssues = basePlan.capability.issues.filter {
            $0 == .selectTarget || $0 == .conflictingTarget || $0 == .unknownTarget
        }
        let merged = RuntimeCapability(
            backend: .remotePhysics,
            compatibility: liveCapability.compatibility,
            readiness: liveCapability.readiness,
            evidence: liveCapability.evidence,
            issues: selectionIssues + liveCapability.issues
        )
        return RuntimePlan(profile: basePlan.profile, host: host, capability: merged)
    }

    public func storagePreflight(
        for executableURL: URL, bottle: Bottle?, selection: RuntimeTargetSelection = .automatic,
        backend: RuntimeBackendKind? = nil, targetDirectory: URL? = nil,
        guestConfiguration: RuntimeGuestConfiguration? = nil
    ) -> RuntimeStoragePreflight {
        let plan = plan(for: executableURL, selection: selection, backend: backend)
        return checkStorage(executableURL, bottle: bottle, backend: plan.preferredBackend,
                            targetDirectory: targetDirectory, guestConfiguration: guestConfiguration)
    }

    private func checkStorage(
        _ executableURL: URL, bottle: Bottle?, backend: RuntimeBackendKind,
        targetDirectory: URL? = nil, guestConfiguration: RuntimeGuestConfiguration? = nil
    ) -> RuntimeStoragePreflight {
        let target = targetDirectory ?? bottle?.settings.runtimeStorageDirectory
        let configuration = resolveGuestConfiguration(guestConfiguration, bottle: bottle)
        let mapping = configuration?.storageMapping(for: target) ?? .notConfigured
        return storageChecker.check(targetDirectory: target, installerURL: executableURL,
                                    requiresGuestMapping: backend == .windowsGuest, guestMapping: mapping)
    }

    private func resolveGuestConfiguration(
        _ configuration: RuntimeGuestConfiguration?, bottle: Bottle?
    ) -> RuntimeGuestConfiguration? {
        configuration ?? bottle?.settings.runtimeStorageGuestConfiguration ?? windowsGuest.storageGuestConfiguration
    }

    public func validate(
        _ request: RuntimeLaunchRequest,
        allowUnverifiedRemotePhysics: Bool = false
    ) throws -> RuntimePlan {
        let executableURL = request.executableURL
        let title = executableURL.lastPathComponent
        let plan = plan(for: executableURL, selection: request.selection, backend: request.backend, host: request.host)
        if plan.preferredBackend != .remotePhysics {
            guard executableURL.isFileURL else { throw RuntimeLaunchError.issue(.localFileRequired) }
            let kind = executableURL.pathExtension.lowercased()
            guard ["exe", "msi", "bat", "cmd", "com"].contains(kind) else {
                throw RuntimeLaunchError.issue(.invalidFileType)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false),
                                                 isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw RuntimeLaunchError.issue(.fileMissing)
            }
        }
        guard request.arguments.allSatisfy({ !$0.contains("\0") }),
              request.environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
              }) else { throw RuntimeLaunchError.issue(.invalidArgumentsOrEnvironment) }

        let remotePendingProbe = allowUnverifiedRemotePhysics
            && plan.preferredBackend == .remotePhysics
            && plan.capability.issues == [.remotePhysicsUnverified]
        guard plan.capability.canLaunch || remotePendingProbe else {
            throw RuntimeLaunchError.blocked(plan.profile?.displayName ?? title, plan.capability.issues)
        }
        if plan.preferredBackend == .wine {
            guard let bottle = request.bottle, bottle.isAvailable else {
                throw RuntimeLaunchError.issue(.bottleUnavailable)
            }
        }
        guard plan.preferredBackend != .remotePhysics,
              request.bottle?.settings.runtimeStorageDirectory != nil else { return plan }
        let storage = checkStorage(executableURL, bottle: request.bottle, backend: plan.preferredBackend,
                                   guestConfiguration: request.guestConfiguration)
        guard storage.isReady else { throw RuntimeLaunchError.storagePreflight(storage) }
        return RuntimePlan(profile: plan.profile, host: plan.host, capability: plan.capability,
                           storagePreflight: storage)
    }

    public func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        try Task.checkCancellation()
        let plan = try validate(request, allowUnverifiedRemotePhysics: true)
        let guestConfiguration = resolveGuestConfiguration(request.guestConfiguration, bottle: request.bottle)
        let resolvedRequest = request.resolving(profile: plan.profile, guestConfiguration: guestConfiguration)
        switch plan.preferredBackend {
        case .wine: return try await wine.start(resolvedRequest)
        case .windowsGuest: return try await windowsGuest.start(resolvedRequest)
        case .remotePhysics: return try await remotePhysics.start(resolvedRequest)
        }
    }

    public func launch(_ request: RuntimeLaunchRequest) async throws {
        let session = try await start(request)
        let result = try await withTaskCancellationHandler {
            try await session.wait()
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        if result.reason == .cancelled { throw CancellationError() }
        if result.reason == .signal { throw RuntimeLaunchError.processSignal(result.status) }
        if result.status != 0 { throw RuntimeLaunchError.processExit(result.status) }
    }

    public func launch(
        executableURL: URL, bottle: Bottle?, arguments: [String] = [], environment: [String: String] = [:],
        selection: RuntimeTargetSelection = .automatic
    ) async throws {
        try await launch(RuntimeLaunchRequest(executableURL: executableURL, bottle: bottle, arguments: arguments,
                                               environment: environment, selection: selection))
    }
}
