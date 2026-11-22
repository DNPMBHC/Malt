// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RuntimeGuestConfiguration: Codable, Equatable, Sendable {
    public struct FileMapping: Codable, Equatable, Sendable {
        public let hostDirectory: URL
        public let guestDirectory: String

        public init(hostDirectory: URL, guestDirectory: String) {
            self.hostDirectory = hostDirectory
            self.guestDirectory = guestDirectory
        }
    }

    public let identifier: String
    public let architecture: String
    public let fileMappings: [FileMapping]
    public let startupTimeoutSeconds: Double

    public init(identifier: String, architecture: String, fileMappings: [FileMapping] = [],
                startupTimeoutSeconds: Double = 30) {
        self.identifier = identifier
        self.architecture = architecture
        self.fileMappings = fileMappings
        self.startupTimeoutSeconds = startupTimeoutSeconds
    }
}

public struct RuntimeLaunchRequest: Sendable {
    public let executableURL: URL
    public let bottle: Bottle?
    public let arguments: [String]
    public let environment: [String: String]
    public let profile: GameCompatibilityProfile?
    public let host: RuntimeHostSnapshot
    public let selection: RuntimeTargetSelection
    public let backend: RuntimeBackendKind?
    public let guestConfiguration: RuntimeGuestConfiguration?

    public init(executableURL: URL, bottle: Bottle?, arguments: [String] = [], environment: [String: String] = [:],
                profile: GameCompatibilityProfile? = nil, host: RuntimeHostSnapshot = .current(),
                selection: RuntimeTargetSelection = .automatic, backend: RuntimeBackendKind? = nil,
                guestConfiguration: RuntimeGuestConfiguration? = nil) {
        self.executableURL = executableURL
        self.bottle = bottle
        self.arguments = arguments
        self.environment = environment
        self.profile = profile
        self.host = host
        self.selection = selection
        self.backend = backend
        self.guestConfiguration = guestConfiguration
    }

    func resolving(profile: GameCompatibilityProfile?, guestConfiguration: RuntimeGuestConfiguration?) -> Self {
        Self(executableURL: executableURL, bottle: bottle, arguments: arguments, environment: environment,
             profile: profile, host: host, selection: selection, backend: backend,
             guestConfiguration: guestConfiguration)
    }
}

public enum RuntimeExitReason: String, Sendable, Equatable {
    case exit, signal, unreported
}

public struct RuntimeExitResult: Sendable, Equatable {
    public let status: Int32
    public let reason: RuntimeExitReason

    public init(status: Int32, reason: RuntimeExitReason = .exit) {
        self.status = status
        self.reason = reason
    }
}

public struct RuntimeSession: Sendable {
    public let id: UUID
    private let waitForResult: @Sendable () async throws -> RuntimeExitResult
    private let cancelExecution: @Sendable () async -> Void

    public init(id: UUID = UUID(), wait: @escaping @Sendable () async throws -> RuntimeExitResult,
                cancel: @escaping @Sendable () async -> Void) {
        self.id = id
        self.waitForResult = wait
        self.cancelExecution = cancel
    }

    public func wait() async throws -> RuntimeExitResult { try await waitForResult() }
    public func cancel() async { await cancelExecution() }
}

public enum WindowsGuestAvailability: Equatable, Sendable {
    case unconfigured
    case unavailable(String)
    case ready

    public var isReady: Bool { self == .ready }
}

public protocol WindowsGuestProvider: Sendable {
    var availability: WindowsGuestAvailability { get }
    var storageGuestConfiguration: RuntimeGuestConfiguration? { get }
    func launch(_ request: RuntimeLaunchRequest) async throws
    func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession
}

public extension WindowsGuestProvider {
    var storageGuestConfiguration: RuntimeGuestConfiguration? { nil }

    func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        try Task.checkCancellation()
        let task = Task {
            try await launch(request)
            return RuntimeExitResult(status: 0, reason: .unreported)
        }
        return RuntimeSession(wait: { try await task.value }, cancel: { task.cancel() })
    }
}

public struct UnconfiguredWindowsGuestProvider: WindowsGuestProvider {
    public let availability: WindowsGuestAvailability = .unconfigured
    public init() {}

    public func launch(_ request: RuntimeLaunchRequest) async throws {
        throw RuntimeLaunchError.issue(.guestUnconfigured)
    }
}

public protocol RuntimeBackend: Sendable {
    var kind: RuntimeBackendKind { get }
    func capability(for profile: GameCompatibilityProfile?, host: RuntimeHostSnapshot) -> RuntimeCapability
    func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession
}

public struct WineRuntimeBackend: RuntimeBackend {
    public let kind: RuntimeBackendKind = .wine
    private let isAvailable: @Sendable () -> Bool
    private let evidence: RuntimeEvidenceProvider

    public init(
        isAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(atPath: Wine.wineBinary.path(percentEncoded: false))
        },
        evidence: @escaping RuntimeEvidenceProvider = { _, _ in
            RuntimeEvidence(kernelDiagnostics: .notApplicable)
        }
    ) {
        self.isAvailable = isAvailable
        self.evidence = evidence
    }

    public func capability(for profile: GameCompatibilityProfile?, host: RuntimeHostSnapshot) -> RuntimeCapability {
        let compatibility = profile?.wineCompatibility ?? .unknown
        let available = isAvailable()
        var issues: [RuntimeIssue] = available ? [] : [.wineUnavailable]
        if compatibility == .requiresWindowsKernel { issues.append(.requiresWindowsKernel) }
        if compatibility == .vendorRestricted || compatibility == .unavailable { issues.append(.wineNotSupported) }
        return RuntimeCapability(backend: kind, compatibility: compatibility,
                                 readiness: available ? .ready : .unavailable,
                                 evidence: evidence(kind, profile), issues: issues)
    }

    public func resolvedRequest(
        for request: RuntimeLaunchRequest,
        availableBackends: HostAvailableWineBackends = WhiskyWineInstaller.availableGraphicsBackends()
    ) -> RuntimeLaunchRequest {
        guard let bottle = request.bottle else { return request }
        let selectedBackend = bottle.settings.effectiveGraphicsBackend(available: availableBackends)
        let policy = HostWineLaunchPolicy(
            snapshot: request.host,
            graphicsBackend: selectedBackend,
            enabled: bottle.settings.adaptiveResourcePolicyEnabled
        )
        var mergedEnvironment = policy.applyingNonDestructively(to: request.environment)
        if selectedBackend == .dxmt {
            if mergedEnvironment["DXMT_SHADER_CACHE"] == nil {
                mergedEnvironment["DXMT_SHADER_CACHE"] = "1"
            }
            if mergedEnvironment["DXMT_SHADER_CACHE_PATH"] == nil {
                mergedEnvironment["DXMT_SHADER_CACHE_PATH"] = BottleSettings
                    .dxmtShaderCacheDirectory(for: bottle.url)
                    .path(percentEncoded: false)
            }
        }
        guard mergedEnvironment != request.environment else { return request }
        return RuntimeLaunchRequest(
            executableURL: request.executableURL,
            bottle: request.bottle,
            arguments: request.arguments,
            environment: mergedEnvironment,
            profile: request.profile,
            host: request.host,
            selection: request.selection,
            backend: request.backend,
            guestConfiguration: request.guestConfiguration
        )
    }

    public func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        guard request.bottle?.isAvailable == true else { throw RuntimeLaunchError.issue(.bottleUnavailable) }
        let capability = capability(for: request.profile, host: request.host)
        guard capability.canLaunch else {
            throw RuntimeLaunchError.blocked(request.executableURL.lastPathComponent, capability.issues)
        }
        return try Wine.startProgramInWine(resolvedRequest(for: request))
    }

    public func launch(_ request: RuntimeLaunchRequest) async throws {
        let session = try await start(request)
        _ = try await session.wait()
    }
}

public struct WindowsGuestRuntimeBackend: RuntimeBackend {
    public let kind: RuntimeBackendKind = .windowsGuest
    private let provider: any WindowsGuestProvider
    var storageGuestConfiguration: RuntimeGuestConfiguration? { provider.storageGuestConfiguration }
    private let evidence: RuntimeEvidenceProvider

    public init(
        provider: any WindowsGuestProvider = UnconfiguredWindowsGuestProvider(),
        evidence: @escaping RuntimeEvidenceProvider = { _, _ in
            RuntimeEvidence()
        }
    ) {
        self.provider = provider
        self.evidence = evidence
    }

    public func capability(for profile: GameCompatibilityProfile?, host: RuntimeHostSnapshot) -> RuntimeCapability {
        let compatibility = profile?.windowsGuestCompatibility ?? .unknown
        let readiness: RuntimeBackendReadiness
        var issues: [RuntimeIssue] = []
        switch provider.availability {
        case .unconfigured:
            readiness = .unconfigured
            issues.append(.guestUnconfigured)
        case .unavailable:
            readiness = .unavailable
            issues.append(.guestUnavailable)
        case .ready:
            readiness = .ready
        }
        let evidence = evidence(kind, profile)
        if [.vendorRestricted, .unavailable, .requiresWindowsKernel].contains(compatibility) {
            issues.append(.guestNotSupported)
        } else if let profile, profile.antiCheat != .none, evidence.vendorSupport != .confirmed {
            issues.append(.guestNotSupported)
        }
        return RuntimeCapability(backend: kind, compatibility: compatibility, readiness: readiness,
                                 evidence: evidence, issues: issues)
    }

    /// Runs the guest's own diagnostic probe without changing vendor support or launch policy.
    public func assessSelfProbe(
        now: Date = .now,
        maximumAge: TimeInterval = 120
    ) async throws -> AntiCheatProbeAssessment {
        try await WindowsGuestProbeService(provider: provider).assess(now: now, maximumAge: maximumAge)
    }

    public func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        let capability = capability(for: request.profile, host: request.host)
        guard capability.canLaunch else {
            throw RuntimeLaunchError.blocked(request.profile?.displayName ?? request.executableURL.lastPathComponent,
                                             capability.issues)
        }
        return try await provider.start(request)
    }

    public func launch(_ request: RuntimeLaunchRequest) async throws {
        let session = try await start(request)
        _ = try await session.wait()
    }
}

public enum RuntimeIssue: String, Equatable, Sendable {
    case selectTarget, conflictingTarget, unknownTarget
    case wineUnavailable, requiresWindowsKernel, wineNotSupported
    case guestUnconfigured, guestUnavailable, guestNotSupported, guestTimeout, guestFileUnavailable
    case localFileRequired, invalidFileType, fileMissing, invalidArgumentsOrEnvironment, bottleUnavailable
    case unfinishedEscape, unmatchedQuote, terminalUnavailable

    private static let fallback: [RuntimeIssue: String] = [
        .selectTarget: "Select the game this file will start, or choose Generic Windows Program.",
        .conflictingTarget: "The selected profile conflicts with the profile identified from this file name.",
        .unknownTarget: "The selected launch profile is unavailable. Choose another profile.",
        .wineUnavailable: "The Wine runtime is missing or unavailable. Check the runtime setup.",
        .requiresWindowsKernel: "This profile requires a Windows kernel.",
        .wineNotSupported: "This profile has no verified Wine launch path.",
        .guestUnconfigured: "No Windows guest provider is configured.",
        .guestUnavailable: "The configured Windows guest is unavailable. Check the provider and try again.",
        .guestNotSupported: "Vendor support has not been confirmed for this Windows guest configuration.",
        .guestTimeout: "The Windows guest did not become ready in time.",
        .guestFileUnavailable: "The Windows guest cannot access the selected file. Check its file mapping.",
        .localFileRequired: "Choose a local Windows program.",
        .invalidFileType: "This Windows file type cannot be launched.",
        .fileMissing: "The selected program file could not be found.",
        .invalidArgumentsOrEnvironment: "A program argument or environment entry is invalid.",
        .bottleUnavailable: "Choose an available bottle and try again.",
        .unfinishedEscape: "The saved arguments end with an incomplete escape.",
        .unmatchedQuote: "The saved arguments contain an unclosed quote.",
        .terminalUnavailable: "The terminal command could not be opened. Check Terminal permissions and try again."
    ]

    public func localized(in bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: "runtime.issue.\(rawValue)", value: Self.fallback[self], table: nil)
    }
}

public enum RuntimeLaunchError: LocalizedError, Sendable {
    case issue(RuntimeIssue)
    case blocked(String, [RuntimeIssue])
    case processExit(Int32)
    case processSignal(Int32)
    case storagePreflight(RuntimeStoragePreflight)

    public var errorDescription: String? { description(in: .main) }

    public func description(in bundle: Bundle) -> String {
        switch self {
        case .issue(let issue): return issue.localized(in: bundle)
        case .blocked(let name, let issues):
            return "\(name): \(issues.map { $0.localized(in: bundle) }.joined(separator: " "))"
        case .storagePreflight(let storage):
            let title = bundle.localizedString(forKey: "runtime.storage.launchBlocked",
                                               value: "Storage preflight blocked launch.", table: nil)
            let detail = bundle.localizedString(forKey: storage.state.localizationKey,
                                                value: storage.state.fallback, table: nil)
            return "\(title) \(detail)"
        case .processExit(let code):
            let format = bundle.localizedString(forKey: "runtime.issue.processExit",
                                                value: "The program exited with code %d.", table: nil)
            return String.localizedStringWithFormat(format, code)
        case .processSignal(let signal):
            let format = bundle.localizedString(forKey: "runtime.issue.processSignal",
                                                value: "The program was terminated by signal %d.", table: nil)
            return String.localizedStringWithFormat(format, signal)
        }
    }
}
