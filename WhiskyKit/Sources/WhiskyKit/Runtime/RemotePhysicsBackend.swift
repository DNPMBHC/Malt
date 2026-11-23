// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// Provider contract for launching a compliant streaming session to a physical Windows host.
/// Mirrors WindowsGuestProvider while keeping remote_physical_windows strictly separated.
public protocol RemotePhysicsProvider: Sendable {
    var executionDomain: RemotePhysicsExecutionDomain { get }
    var configuration: RemotePhysicsConfiguration? { get }

    func checkAvailability() async -> RemotePhysicsAvailability
    func resolveStreamPolicy(host: RuntimeHostSnapshot) -> RemotePhysicsStreamPolicy?
    func start(host: RuntimeHostSnapshot) async throws -> RuntimeSession
}

public extension RemotePhysicsProvider {
    var executionDomain: RemotePhysicsExecutionDomain { .remotePhysicalWindows }

    func resolveStreamPolicy(host: RuntimeHostSnapshot) -> RemotePhysicsStreamPolicy? {
        guard let configuration else { return nil }
        return RemotePhysicsStreamPolicy(preferences: configuration.streamPreferences, snapshot: host)
    }
}

/// Default safe fallback when no physical Windows streaming host has been configured.
public struct UnconfiguredRemotePhysicsProvider: RemotePhysicsProvider {
    public let configuration: RemotePhysicsConfiguration? = nil

    public init() {}

    public func checkAvailability() async -> RemotePhysicsAvailability {
        .unconfigured
    }

    public func start(host: RuntimeHostSnapshot = .current()) async throws -> RuntimeSession {
        throw RemotePhysicsError.unconfigured
    }
}

/// Invocation descriptor produced for a streaming client process (zero shell interpolation).
public struct RemotePhysicsClientInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let qualityOfService: QualityOfService
    public let executionDomain: RemotePhysicsExecutionDomain

    public init(
        executableURL: URL,
        arguments: [String],
        qualityOfService: QualityOfService,
        executionDomain: RemotePhysicsExecutionDomain = .remotePhysicalWindows
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.qualityOfService = qualityOfService
        self.executionDomain = executionDomain
    }
}

/// Reachability result returned by the non-blocking TCP preflight probe.
public enum RemotePhysicsReachabilityResult: Equatable, Sendable {
    case reachable
    case unreachable(String)
    case timedOut
}

/// Lightweight, non-blocking TCP handshake probe using Network.framework.
public enum RemotePhysicsTCPProbe {
    public static func check(
        host: String,
        port: UInt16,
        timeoutSeconds: Double
    ) async -> RemotePhysicsReachabilityResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .unreachable("invalid port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "whisky.remote-physics.tcp-probe", qos: .userInitiated)
        let gate = ProbeCompletionGate(connection: connection)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation: continuation, timeoutSeconds: timeoutSeconds, queue: queue)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.finish(with: .reachable)
                    case .failed(let error):
                        gate.finish(with: .unreachable(error.localizedDescription))
                    case .waiting(let error):
                        gate.finish(with: .unreachable(error.localizedDescription))
                    case .cancelled:
                        gate.finish(with: .unreachable("cancelled"))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            gate.finish(with: .unreachable("cancelled"))
        }
    }
}

private final class ProbeCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<RemotePhysicsReachabilityResult, Never>?
    private var timer: DispatchSourceTimer?
    private var completed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func arm(
        continuation: CheckedContinuation<RemotePhysicsReachabilityResult, Never>,
        timeoutSeconds: Double,
        queue: DispatchQueue
    ) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(returning: .unreachable("cancelled"))
            return
        }
        self.continuation = continuation
        let source = DispatchSource.makeTimerSource(queue: queue)
        let nanos = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
        source.schedule(deadline: .now() + .nanoseconds(Int(min(nanos, UInt64(Int.max)))))
        source.setEventHandler { [weak self] in
            self?.finish(with: .timedOut)
        }
        timer = source
        lock.unlock()
        source.resume()
    }

    func finish(with result: RemotePhysicsReachabilityResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let pending = continuation
        continuation = nil
        let activeTimer = timer
        timer = nil
        lock.unlock()

        activeTimer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending?.resume(returning: result)
    }
}

/// Compliant streaming provider delegating display and physical input to Moonlight.app or a vetted client binary.
/// Contains zero frame-capture hooks, macro injection, or hardware spoofing primitives.
public struct ExternalClientRemotePhysicsProvider: RemotePhysicsProvider {
    public typealias ReachabilityChecker = @Sendable (String, UInt16, Double) async -> RemotePhysicsReachabilityResult
    public typealias ExecutableExistsChecker = @Sendable (URL) -> Bool
    public typealias ProcessStarter = @Sendable (RemotePhysicsClientInvocation) throws -> RuntimeSession

    public let configuration: RemotePhysicsConfiguration?
    private let moonlightSearchPaths: [URL]
    private let isExecutable: ExecutableExistsChecker
    private let checkReachability: ReachabilityChecker
    private let startClientProcess: ProcessStarter

    public init(
        configuration: RemotePhysicsConfiguration?,
        moonlightSearchPaths: [URL] = Self.defaultMoonlightExecutableURLs(),
        isExecutable: @escaping ExecutableExistsChecker = { url in
            FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
        },
        checkReachability: @escaping ReachabilityChecker = { host, port, timeout in
            await RemotePhysicsTCPProbe.check(host: host, port: port, timeoutSeconds: timeout)
        },
        startClientProcess: @escaping ProcessStarter = Self.launchProcess
    ) {
        self.configuration = configuration
        self.moonlightSearchPaths = moonlightSearchPaths
        self.isExecutable = isExecutable
        self.checkReachability = checkReachability
        self.startClientProcess = startClientProcess
    }

    public static func defaultMoonlightExecutableURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Moonlight.app/Contents/MacOS/Moonlight"),
            homeDirectory.appendingPathComponent("Applications/Moonlight.app/Contents/MacOS/Moonlight")
        ]
    }

    public func resolveClientExecutableURL() -> URL? {
        guard let configuration else { return nil }
        switch configuration.transport {
        case .moonlightClient:
            if let explicit = configuration.clientExecutableURL {
                return isExecutable(explicit) ? explicit : nil
            }
            return moonlightSearchPaths.first(where: isExecutable)
        case .externalClient:
            guard let explicit = configuration.clientExecutableURL else { return nil }
            return isExecutable(explicit) ? explicit : nil
        }
    }

    public func buildInvocation(host: RuntimeHostSnapshot = .current()) throws -> RemotePhysicsClientInvocation {
        guard let configuration else { throw RemotePhysicsError.unconfigured }
        try configuration.validate()
        guard let clientURL = resolveClientExecutableURL() else {
            let label = configuration.clientExecutableURL?.lastPathComponent ?? "Moonlight.app"
            throw RemotePhysicsError.clientMissing(label)
        }
        let policy = RemotePhysicsStreamPolicy(preferences: configuration.streamPreferences, snapshot: host)
        let arguments: [String]
        switch configuration.transport {
        case .moonlightClient:
            arguments = policy.moonlightStreamArguments(
                host: configuration.hostIdentifier,
                port: configuration.controlPort,
                applicationName: configuration.applicationName
            )
        case .externalClient:
            arguments = configuration.externalArguments
        }
        return RemotePhysicsClientInvocation(
            executableURL: clientURL,
            arguments: arguments,
            qualityOfService: policy.processQualityOfService,
            executionDomain: executionDomain
        )
    }

    public func checkAvailability() async -> RemotePhysicsAvailability {
        guard let configuration else { return .unconfigured }
        do {
            try configuration.validate()
        } catch {
            return .unconfigured
        }
        guard resolveClientExecutableURL() != nil else {
            let label = configuration.clientExecutableURL?.lastPathComponent ?? "Moonlight.app"
            return .clientMissing(label)
        }
        let reachability = await checkReachability(
            configuration.hostIdentifier,
            configuration.controlPort,
            configuration.connectionTimeoutSeconds
        )
        switch reachability {
        case .reachable:
            return .ready
        case .unreachable(let detail):
            return .hostUnreachable(detail)
        case .timedOut:
            return .hostUnreachable("timed out after \(configuration.connectionTimeoutSeconds)s")
        }
    }

    public func start(host: RuntimeHostSnapshot = .current()) async throws -> RuntimeSession {
        try Task.checkCancellation()
        guard let configuration else { throw RemotePhysicsError.unconfigured }
        let invocation = try buildInvocation(host: host)

        let reachability = await checkReachability(
            configuration.hostIdentifier,
            configuration.controlPort,
            configuration.connectionTimeoutSeconds
        )
        try Task.checkCancellation()
        switch reachability {
        case .reachable:
            break
        case .timedOut:
            throw RemotePhysicsError.connectionTimedOut(configuration.connectionTimeoutSeconds)
        case .unreachable(let detail):
            throw RemotePhysicsError.hostUnreachable(detail)
        }

        let rawSession = try startClientProcess(invocation)
        let cancelLock = NSLock()
        let cancelState = IdempotentCancelState()
        return RuntimeSession(
            id: rawSession.id,
            wait: { try await rawSession.wait() },
            cancel: {
                let shouldCancel = cancelLock.withLock {
                    guard !cancelState.cancelled else { return false }
                    cancelState.cancelled = true
                    return true
                }
                if shouldCancel {
                    await rawSession.cancel()
                }
            }
        )
    }

    public static func launchProcess(_ invocation: RemotePhysicsClientInvocation) throws -> RuntimeSession {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.qualityOfService = invocation.qualityOfService
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try process.startRuntimeSession()
    }
}

private final class IdempotentCancelState: @unchecked Sendable {
    var cancelled = false
}

/// Facade aligning with WineRuntimeBackend / WindowsGuestRuntimeBackend for coordinator integration.
public struct RemotePhysicsBackend: Sendable {
    public let executionDomain: RemotePhysicsExecutionDomain = .remotePhysicalWindows
    public let provider: any RemotePhysicsProvider

    public init(provider: any RemotePhysicsProvider = UnconfiguredRemotePhysicsProvider()) {
        self.provider = provider
    }

    public func checkAvailability() async -> RemotePhysicsAvailability {
        await provider.checkAvailability()
    }

    public func resolveStreamPolicy(host: RuntimeHostSnapshot = .current()) -> RemotePhysicsStreamPolicy? {
        provider.resolveStreamPolicy(host: host)
    }

    public func start(host: RuntimeHostSnapshot = .current()) async throws -> RuntimeSession {
        try await provider.start(host: host)
    }
}
