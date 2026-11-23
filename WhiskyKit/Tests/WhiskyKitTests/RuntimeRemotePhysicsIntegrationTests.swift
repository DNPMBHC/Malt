// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class RuntimeRemotePhysicsIntegrationTests: XCTestCase, @unchecked Sendable {
    private struct AvailabilityExpectation {
        let availability: RemotePhysicsAvailability
        let readiness: RuntimeBackendReadiness
        let issues: [RuntimeIssue]
        let canLaunch: Bool
    }

    private let host = RuntimeHostSnapshot(
        operatingSystemVersion: .init(major: 27, minor: 0, patch: 0),
        architecture: "arm64",
        isAppleSilicon: true,
        gameModePlatformAvailable: true,
        thermalState: .nominal,
        isLowPowerModeEnabled: false,
        metalDeviceName: "Test GPU",
        metalFXSpatialScalingAvailable: true,
        metalFXTemporalScalingAvailable: true,
        gpuDeveloperToolsAvailable: true
    )

    func testRemotePhysicsAvailabilityMatrixAndDomainIsolation() {
        let cases = [
            AvailabilityExpectation(
                availability: .unconfigured, readiness: .unconfigured,
                issues: [.remotePhysicsUnconfigured], canLaunch: false
            ),
            AvailabilityExpectation(
                availability: .unverified, readiness: .unavailable,
                issues: [.remotePhysicsUnverified], canLaunch: false
            ),
            AvailabilityExpectation(
                availability: .clientMissing("Moonlight.app"), readiness: .unavailable,
                issues: [.remotePhysicsClientMissing], canLaunch: false
            ),
            AvailabilityExpectation(
                availability: .hostUnreachable("refused"), readiness: .unavailable,
                issues: [.remotePhysicsHostUnreachable], canLaunch: false
            ),
            AvailabilityExpectation(
                availability: .ready, readiness: .ready,
                issues: [], canLaunch: true
            )
        ]
        for item in cases {
            let provider = RecordingRemotePhysicsProvider(availability: item.availability)
            let backend = RemotePhysicsRuntimeBackend(provider: provider, availability: item.availability)
            let capability = backend.capability(for: nil, host: host)
            XCTAssertEqual(backend.executionDomain, .remotePhysicalWindows)
            XCTAssertEqual(capability.backend, .remotePhysics)
            XCTAssertEqual(capability.readiness, item.readiness)
            XCTAssertEqual(capability.issues, item.issues)
            XCTAssertEqual(capability.canLaunch, item.canLaunch)
        }
    }

    func testRemotePhysicsNeverSilentlyOverridesBlockedLocalBackends() {
        let config = RemotePhysicsConfiguration(hostIdentifier: "192.168.1.50", applicationName: "VALORANT")
        let provider = RecordingRemotePhysicsProvider(configuration: config, availability: .ready)
        let coordinator = RuntimeCoordinator(
            remotePhysicsProvider: provider,
            remotePhysicsAvailability: .ready
        )
        let target = URL(fileURLWithPath: "/tmp/VALORANT.exe")
        let defaultPlan = coordinator.plan(for: target, host: host)
        XCTAssertEqual(defaultPlan.preferredBackend, .windowsGuest)
        XCTAssertFalse(defaultPlan.capability.canLaunch)
        XCTAssertTrue(coordinator.recommendsRemotePhysicsFallback(for: target, host: host))

        let explicitRemotePlan = coordinator.plan(for: target, backend: .remotePhysics, host: host)
        XCTAssertEqual(explicitRemotePlan.preferredBackend, .remotePhysics)
        XCTAssertTrue(explicitRemotePlan.capability.canLaunch)
        XCTAssertEqual(explicitRemotePlan.capability.vendorSupport, .unknown)
    }

    func testRemotePhysicsLaunchSkipsLocalExecutableAndPropagatesExitCode() async throws {
        let config = RemotePhysicsConfiguration(hostIdentifier: "192.168.1.50", applicationName: "VALORANT")
        let provider = RecordingRemotePhysicsProvider(configuration: config, availability: .ready, exitStatus: 17)
        let coordinator = RuntimeCoordinator(
            remotePhysicsProvider: provider,
            remotePhysicsAvailability: .ready
        )
        let nonExistentRemoteTarget = URL(fileURLWithPath: "/nonexistent/remote-only/VALORANT.exe")
        let request = RuntimeLaunchRequest(
            executableURL: nonExistentRemoteTarget,
            bottle: nil,
            host: host,
            backend: .remotePhysics
        )
        do {
            try await coordinator.launch(request)
            XCTFail("Expected remote physics nonzero exit code")
        } catch RuntimeLaunchError.processExit(let status) {
            XCTAssertEqual(status, 17)
        }
        XCTAssertEqual(provider.startCount, 1)
    }

    func testConfiguredRemotePhysicsStaysUnverifiedUntilAsyncProbeRuns() async {
        let config = RemotePhysicsConfiguration(hostIdentifier: "192.168.1.50", applicationName: "VALORANT")
        let provider = RecordingRemotePhysicsProvider(configuration: config, availability: .hostUnreachable("refused"))
        let backend = RemotePhysicsRuntimeBackend(provider: provider)
        let initial = backend.capability(for: nil, host: host)
        XCTAssertEqual(initial.readiness, .unavailable)
        XCTAssertEqual(initial.issues, [.remotePhysicsUnverified])
        XCTAssertFalse(initial.canLaunch)

        let probed = await backend.refreshCapability(for: nil, host: host)
        XCTAssertEqual(probed.readiness, .unavailable)
        XCTAssertEqual(probed.issues, [.remotePhysicsHostUnreachable])
        XCTAssertFalse(probed.canLaunch)
    }

    func testControlPortPropagatesToMoonlightInvocationForCustomAndIPv6Hosts() throws {
        let clientURL = URL(fileURLWithPath: "/usr/bin/true")
        let customPortConfig = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50",
            controlPort: 57984,
            applicationName: "Desktop",
            clientExecutableURL: clientURL
        )
        let customProvider = ExternalClientRemotePhysicsProvider(
            configuration: customPortConfig,
            isExecutable: { $0 == clientURL }
        )
        let customInvocation = try customProvider.buildInvocation(host: host)
        XCTAssertEqual(customInvocation.arguments.suffix(2), ["192.168.1.50:57984", "Desktop"])

        let ipv6Config = RemotePhysicsConfiguration(
            hostIdentifier: "fe80::1",
            controlPort: 57984,
            applicationName: "Desktop",
            clientExecutableURL: clientURL
        )
        let ipv6Provider = ExternalClientRemotePhysicsProvider(
            configuration: ipv6Config,
            isExecutable: { $0 == clientURL }
        )
        let ipv6Invocation = try ipv6Provider.buildInvocation(host: host)
        XCTAssertEqual(ipv6Invocation.arguments.suffix(2), ["[fe80::1]:57984", "Desktop"])

        let defaultPortConfig = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50",
            controlPort: RemotePhysicsConfiguration.defaultControlPort,
            applicationName: "Desktop",
            clientExecutableURL: clientURL
        )
        let defaultProvider = ExternalClientRemotePhysicsProvider(
            configuration: defaultPortConfig,
            isExecutable: { $0 == clientURL }
        )
        let defaultInvocation = try defaultProvider.buildInvocation(host: host)
        XCTAssertEqual(defaultInvocation.arguments.suffix(2), ["192.168.1.50", "Desktop"])
    }

    func testBottleAndProgramSettingsPersistRemotePhysicsAndBackendSelection() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-remote-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: true)
        let config = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.88",
            controlPort: 48000,
            applicationName: "VALORANT"
        )
        bottle.settings.remotePhysicsConfiguration = config

        let reloaded = try BottleSettings.decode(from: tempDir.appending(path: "Metadata.plist"), readOnly: true)
        XCTAssertEqual(reloaded.remotePhysicsConfiguration, config)

        let programURL = tempDir.appending(path: "VALORANT.exe")
        let program = Program(url: programURL, bottle: bottle)
        program.settings.preferredBackend = .remotePhysics
        let request = try program.runtimeRequest()
        XCTAssertEqual(request.backend, .remotePhysics)

        let plan = program.runtimeCoordinator().plan(for: programURL, backend: request.backend, host: host)
        XCTAssertEqual(plan.preferredBackend, .remotePhysics)
        XCTAssertEqual(plan.capability.issues, [.remotePhysicsUnverified])
    }

    func testSharedInteractiveExecutionModeAndCancellationSemantics() async throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("interactive-\(UUID().uuidString).exe")
        try Data().write(to: executable)
        defer { try? FileManager.default.removeItem(at: executable) }

        let provider = CancelledGuestProvider()
        let coordinator = RuntimeCoordinator(guestProvider: provider)
        let request = RuntimeLaunchRequest(
            executableURL: executable,
            bottle: nil,
            host: host,
            backend: .windowsGuest,
            guestExecutionMode: .interactiveDesktop
        )
        let session = try await coordinator.start(request)
        let result = try await session.wait()
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertEqual(result.status, 1223)
        XCTAssertEqual(result.rootExitCode, 0)
        XCTAssertEqual(provider.recordedMode, .interactiveDesktop)

        do {
            try await coordinator.launch(request)
            XCTFail("Expected CancellationError when session result reason is .cancelled")
        } catch is CancellationError {
            // Expected cancellation semantics
        }
    }
}

private final class CancelledGuestProvider: WindowsGuestProvider, @unchecked Sendable {
    let availability: WindowsGuestAvailability = .ready
    private let lock = NSLock()
    private var lastMode: WindowsGuestExecutionMode?

    var recordedMode: WindowsGuestExecutionMode? {
        lock.withLock { lastMode }
    }

    func launch(_ request: RuntimeLaunchRequest) async throws {}

    func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        lock.withLock { lastMode = request.guestExecutionMode }
        return RuntimeSession(
            wait: { RuntimeExitResult(status: 1223, reason: .cancelled, rootExitCode: 0) },
            cancel: {}
        )
    }
}

private final class RecordingRemotePhysicsProvider: RemotePhysicsProvider, @unchecked Sendable {
    let configuration: RemotePhysicsConfiguration?
    private let availabilityValue: RemotePhysicsAvailability
    private let exitStatus: Int32
    private let lock = NSLock()
    private var startedHosts: [RuntimeHostSnapshot] = []

    init(
        configuration: RemotePhysicsConfiguration? = nil,
        availability: RemotePhysicsAvailability,
        exitStatus: Int32 = 0
    ) {
        self.configuration = configuration
        self.availabilityValue = availability
        self.exitStatus = exitStatus
    }

    var startCount: Int {
        lock.withLock { startedHosts.count }
    }

    func checkAvailability() async -> RemotePhysicsAvailability {
        availabilityValue
    }

    func start(host: RuntimeHostSnapshot) async throws -> RuntimeSession {
        lock.withLock { startedHosts.append(host) }
        let status = exitStatus
        return RuntimeSession(wait: { RuntimeExitResult(status: status) }, cancel: {})
    }
}
