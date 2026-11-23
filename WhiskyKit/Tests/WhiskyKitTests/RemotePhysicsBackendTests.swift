// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

final class RemotePhysicsConfigurationTests: XCTestCase {
    func testExecutionDomainIsStrictlyRemotePhysicalWindows() {
        let unconfigured = RemotePhysicsBackend()
        XCTAssertEqual(unconfigured.executionDomain, .remotePhysicalWindows)
        XCTAssertEqual(unconfigured.executionDomain.rawValue, "remote_physical_windows")
    }

    func testConfigurationRejectsPlaintextCredentialKeysInJSON() {
        let forbiddenKeys = ["password", "pin", "token", "secret", "apiKey", "private_key", "authorization"]
        for key in forbiddenKeys {
            let json = """
            {
              "hostIdentifier": "192.168.1.50",
              "applicationName": "Desktop",
              "\(key)": "sensitive-value"
            }
            """
            let data = Data(json.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(RemotePhysicsConfiguration.self, from: data)) { error in
                XCTAssertEqual(error as? RemotePhysicsError, .forbiddenPlaintextCredential(key))
            }
        }
    }

    func testConfigurationRejectsEmbeddedCredentialsAndInvalidBounds() {
        let withAtSign = RemotePhysicsConfiguration(
            hostIdentifier: "user:pass@192.168.1.50",
            applicationName: "Desktop"
        )
        XCTAssertThrowsError(try withAtSign.validate()) { error in
            XCTAssertEqual(error as? RemotePhysicsError, .forbiddenPlaintextCredential("hostIdentifier"))
        }

        let withQueryToken = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50?token=abc",
            applicationName: "Desktop"
        )
        XCTAssertThrowsError(try withQueryToken.validate()) { error in
            XCTAssertEqual(error as? RemotePhysicsError, .forbiddenPlaintextCredential("hostIdentifier"))
        }

        let badTimeout = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50",
            applicationName: "Desktop",
            connectionTimeoutSeconds: 0
        )
        XCTAssertThrowsError(try badTimeout.validate())

        let badResolution = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50",
            applicationName: "Desktop",
            streamPreferences: .init(resolution: .init(width: 100, height: 100))
        )
        XCTAssertThrowsError(try badResolution.validate())
    }

    func testConfigurationRejectsShellInterpretersAsExternalClient() {
        for shellPath in ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/osascript"] {
            let config = RemotePhysicsConfiguration(
                hostIdentifier: "192.168.1.50",
                transport: .externalClient,
                applicationName: "Desktop",
                clientExecutableURL: URL(fileURLWithPath: shellPath),
                externalArguments: ["-c", "echo blocked"]
            )
            XCTAssertThrowsError(try config.validate()) { error in
                let expected = RemotePhysicsError.forbiddenShellClient(
                    URL(fileURLWithPath: shellPath).lastPathComponent
                )
                XCTAssertEqual(error as? RemotePhysicsError, expected)
            }
        }
    }

    func testStreamPolicyConsumesHostThermalAndPowerStateWithReversibleFallback() {
        let prefs = RemotePhysicsStreamPreferences(
            resolution: .qhd1440p,
            targetFPS: 120,
            bitrateKbps: 40_000,
            audioEnabled: true,
            adaptiveResourcePolicyEnabled: true
        )

        let nominal = RemotePhysicsStreamPolicy(
            preferences: prefs,
            snapshot: Self.snapshot(thermal: .nominal, lowPower: false)
        )
        XCTAssertEqual(nominal.effectiveFPS, 120)
        XCTAssertEqual(nominal.effectiveBitrateKbps, 40_000)
        XCTAssertEqual(nominal.processQualityOfService, .userInitiated)

        let serious = RemotePhysicsStreamPolicy(
            preferences: prefs,
            snapshot: Self.snapshot(thermal: .serious, lowPower: false)
        )
        XCTAssertEqual(serious.effectiveFPS, 60)
        XCTAssertEqual(serious.effectiveBitrateKbps, 28_000)
        XCTAssertEqual(serious.processQualityOfService, .utility)

        let lowPower = RemotePhysicsStreamPolicy(
            preferences: prefs,
            snapshot: Self.snapshot(thermal: .nominal, lowPower: true)
        )
        XCTAssertEqual(lowPower.effectiveFPS, 30)
        XCTAssertEqual(lowPower.effectiveBitrateKbps, 18_000)
        XCTAssertEqual(lowPower.processQualityOfService, .utility)

        let disabledPrefs = RemotePhysicsStreamPreferences(
            resolution: .qhd1440p,
            targetFPS: 120,
            bitrateKbps: 40_000,
            audioEnabled: false,
            adaptiveResourcePolicyEnabled: false
        )
        let fallback = RemotePhysicsStreamPolicy(
            preferences: disabledPrefs,
            snapshot: Self.snapshot(thermal: .critical, lowPower: true)
        )
        XCTAssertEqual(fallback.effectiveFPS, 120)
        XCTAssertEqual(fallback.effectiveBitrateKbps, 40_000)
        XCTAssertEqual(fallback.processQualityOfService, .userInitiated)
        XCTAssertEqual(
            fallback.moonlightStreamArguments(host: "192.168.1.50", applicationName: "VALORANT"),
            ["stream", "--resolution", "2560x1440", "--fps", "120", "--bitrate", "40000",
             "--no-audio", "192.168.1.50", "VALORANT"]
        )
    }

    private static func snapshot(
        thermal: HostThermalState = .nominal,
        lowPower: Bool = false
    ) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 27, minor: 2, patch: 1),
            architecture: "arm64",
            isAppleSilicon: true,
            gameModePlatformAvailable: true,
            isMacOS27OrLater: true,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            metalDeviceName: "Apple M4",
            metalFXSpatialScalingAvailable: true,
            metalFXTemporalScalingAvailable: true,
            gpuDeveloperToolsAvailable: true
        )
    }
}

final class RemotePhysicsBackendTests: XCTestCase {
    func testAvailabilityCoversAllFourSpecifiedStates() async {
        let unconfiguredProvider = UnconfiguredRemotePhysicsProvider()
        let unconfiguredState = await unconfiguredProvider.checkAvailability()
        XCTAssertEqual(unconfiguredState, .unconfigured)
        XCTAssertFalse(unconfiguredState.isReady)

        let config = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50",
            transport: .moonlightClient,
            applicationName: "Desktop"
        )

        let missingClient = ExternalClientRemotePhysicsProvider(
            configuration: config,
            moonlightSearchPaths: [URL(fileURLWithPath: "/nonexistent/Moonlight")],
            isExecutable: { _ in false },
            checkReachability: { _, _, _ in .reachable }
        )
        let missingState = await missingClient.checkAvailability()
        XCTAssertEqual(missingState, .clientMissing("Moonlight.app"))

        let unreachableHost = ExternalClientRemotePhysicsProvider(
            configuration: config,
            moonlightSearchPaths: [URL(fileURLWithPath: "/Applications/Moonlight.app/Contents/MacOS/Moonlight")],
            isExecutable: { _ in true },
            checkReachability: { _, _, _ in .unreachable("connection refused") }
        )
        let unreachableState = await unreachableHost.checkAvailability()
        XCTAssertEqual(unreachableState, .hostUnreachable("connection refused"))

        let readyProvider = ExternalClientRemotePhysicsProvider(
            configuration: config,
            moonlightSearchPaths: [URL(fileURLWithPath: "/Applications/Moonlight.app/Contents/MacOS/Moonlight")],
            isExecutable: { _ in true },
            checkReachability: { _, _, _ in .reachable }
        )
        let readyState = await readyProvider.checkAvailability()
        XCTAssertEqual(readyState, .ready)
        XCTAssertTrue(readyState.isReady)
    }

    func testMoonlightInvocationAppliesHostResourcePolicyWithoutShell() throws {
        let config = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.88",
            transport: .moonlightClient,
            applicationName: "Desktop",
            streamPreferences: .init(resolution: .fullHD1080p, targetFPS: 120, bitrateKbps: 30_000)
        )
        let moonlightURL = URL(fileURLWithPath: "/Applications/Moonlight.app/Contents/MacOS/Moonlight")
        let provider = ExternalClientRemotePhysicsProvider(
            configuration: config,
            moonlightSearchPaths: [moonlightURL],
            isExecutable: { $0 == moonlightURL }
        )
        let invocation = try provider.buildInvocation(host: Self.snapshot(thermal: .serious, lowPower: false))
        XCTAssertEqual(invocation.executableURL, moonlightURL)
        XCTAssertEqual(invocation.qualityOfService, .utility)
        XCTAssertEqual(invocation.executionDomain, .remotePhysicalWindows)
        XCTAssertEqual(
            invocation.arguments,
            ["stream", "--resolution", "1920x1080", "--fps", "60", "--bitrate", "21000", "192.168.1.88", "Desktop"]
        )
    }

    func testStartPropagatesTimeoutUnreachableAndCancellationErrors() async {
        let config = RemotePhysicsConfiguration(
            hostIdentifier: "192.168.1.50",
            transport: .moonlightClient,
            applicationName: "Desktop",
            connectionTimeoutSeconds: 2
        )
        let moonlightURL = URL(fileURLWithPath: "/Applications/Moonlight.app/Contents/MacOS/Moonlight")

        let timedOutProvider = ExternalClientRemotePhysicsProvider(
            configuration: config,
            moonlightSearchPaths: [moonlightURL],
            isExecutable: { _ in true },
            checkReachability: { _, _, _ in .timedOut }
        )
        do {
            _ = try await timedOutProvider.start(host: Self.snapshot())
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertEqual(error as? RemotePhysicsError, .connectionTimedOut(2))
        }

        let unreachableProvider = ExternalClientRemotePhysicsProvider(
            configuration: config,
            moonlightSearchPaths: [moonlightURL],
            isExecutable: { _ in true },
            checkReachability: { _, _, _ in .unreachable("no route") }
        )
        do {
            _ = try await unreachableProvider.start(host: Self.snapshot())
            XCTFail("Expected hostUnreachable error")
        } catch {
            XCTAssertEqual(error as? RemotePhysicsError, .hostUnreachable("no route"))
        }

        let cancelledTask = Task {
            try await timedOutProvider.start(host: Self.snapshot())
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected cancellation propagation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRealProcessSessionReportsExitCodesAndIdempotentCancellation() async throws {
        let trueConfig = RemotePhysicsConfiguration(
            hostIdentifier: "127.0.0.1",
            transport: .externalClient,
            applicationName: "Desktop",
            clientExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let trueBackend = RemotePhysicsBackend(
            provider: ExternalClientRemotePhysicsProvider(
                configuration: trueConfig,
                checkReachability: { _, _, _ in .reachable }
            )
        )
        let okSession = try await trueBackend.start(host: Self.snapshot())
        let okResult = try await okSession.wait()
        XCTAssertEqual(okResult, RuntimeExitResult(status: 0, reason: .exit))

        let falseConfig = RemotePhysicsConfiguration(
            hostIdentifier: "127.0.0.1",
            transport: .externalClient,
            applicationName: "Desktop",
            clientExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        let falseBackend = RemotePhysicsBackend(
            provider: ExternalClientRemotePhysicsProvider(
                configuration: falseConfig,
                checkReachability: { _, _, _ in .reachable }
            )
        )
        let failSession = try await falseBackend.start(host: Self.snapshot())
        let failResult = try await failSession.wait()
        XCTAssertEqual(failResult, RuntimeExitResult(status: 1, reason: .exit))

        let sleepConfig = RemotePhysicsConfiguration(
            hostIdentifier: "127.0.0.1",
            transport: .externalClient,
            applicationName: "Desktop",
            clientExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
            externalArguments: ["30"]
        )
        let sleepBackend = RemotePhysicsBackend(
            provider: ExternalClientRemotePhysicsProvider(
                configuration: sleepConfig,
                checkReachability: { _, _, _ in .reachable }
            )
        )
        let runningSession = try await sleepBackend.start(host: Self.snapshot())
        await runningSession.cancel()
        await runningSession.cancel()
        let cancelledResult = try await runningSession.wait()
        XCTAssertEqual(cancelledResult.reason, .signal)
    }

    func testTCPProbeReturnsNonReadyForClosedLoopbackPortWithinTimeout() async {
        let result = await RemotePhysicsTCPProbe.check(host: "127.0.0.1", port: 1, timeoutSeconds: 0.5)
        XCTAssertNotEqual(result, .reachable)
    }

    private static func snapshot(
        thermal: HostThermalState = .nominal,
        lowPower: Bool = false
    ) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 27, minor: 2, patch: 1),
            architecture: "arm64",
            isAppleSilicon: true,
            gameModePlatformAvailable: true,
            isMacOS27OrLater: true,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            metalDeviceName: "Apple M4",
            metalFXSpatialScalingAvailable: true,
            metalFXTemporalScalingAvailable: true,
            gpuDeveloperToolsAvailable: true
        )
    }
}
