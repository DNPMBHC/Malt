// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class IntegrationBoundaryTests: XCTestCase, @unchecked Sendable {
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

    func testGuestCapabilityMatrix() {
        let availabilities: [WindowsGuestAvailability] = [
            .unconfigured,
            .unavailable("test provider unavailable"),
            .ready
        ]
        let compatibilities: [RuntimeCompatibility] = [
            .supported, .unknown, .requiresWindowsKernel, .vendorRestricted, .unavailable
        ]

        for availability in availabilities {
            for compatibility in compatibilities {
                let provider = RecordingGuestProvider(availability: availability)
                let backend = WindowsGuestRuntimeBackend(provider: provider)
                let profile = makeProfile(guestCompatibility: compatibility)
                let capability = backend.capability(for: profile, host: host)
                let expected = availability.isReady &&
                    (compatibility == .supported || compatibility == .unknown)

                XCTAssertEqual(capability.canLaunch, expected,
                               "availability=\(availability), compatibility=\(compatibility.rawValue)")
                XCTAssertEqual(capability.backend, .windowsGuest)
                XCTAssertEqual(capability.compatibility, compatibility)
                let expectedReadiness: RuntimeBackendReadiness
                var expectedIssues: [RuntimeIssue] = []
                switch availability {
                case .unconfigured:
                    expectedReadiness = .unconfigured
                    expectedIssues.append(.guestUnconfigured)
                case .unavailable:
                    expectedReadiness = .unavailable
                    expectedIssues.append(.guestUnavailable)
                case .ready:
                    expectedReadiness = .ready
                }
                if [.requiresWindowsKernel, .vendorRestricted, .unavailable].contains(compatibility) {
                    expectedIssues.append(.guestNotSupported)
                }
                XCTAssertEqual(capability.readiness, expectedReadiness)
                XCTAssertEqual(capability.issues, expectedIssues)
            }
        }
    }

    func testRejectedGuestLaunchNeverCallsProvider() async {
        let rejectedCases: [(WindowsGuestAvailability, RuntimeCompatibility)] = [
            (.unconfigured, .unknown),
            (.unavailable("test provider unavailable"), .supported),
            (.ready, .requiresWindowsKernel),
            (.ready, .vendorRestricted),
            (.ready, .unavailable)
        ]

        for (availability, compatibility) in rejectedCases {
            let provider = RecordingGuestProvider(availability: availability)
            let backend = WindowsGuestRuntimeBackend(provider: provider)
            let request = RuntimeLaunchRequest(
                executableURL: URL(fileURLWithPath: "/tmp/demo-app.exe"),
                bottle: nil,
                arguments: [],
                environment: [:],
                profile: makeProfile(guestCompatibility: compatibility),
                host: host
            )

            do {
                try await backend.launch(request)
                XCTFail("Rejected guest launch unexpectedly succeeded")
            } catch RuntimeLaunchError.blocked(let title, let issues) {
                XCTAssertEqual(title, "Demo App")
                switch availability {
                case .unconfigured: XCTAssertEqual(issues, [.guestUnconfigured])
                case .unavailable: XCTAssertEqual(issues, [.guestUnavailable])
                case .ready: XCTAssertEqual(issues, [.guestNotSupported])
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(provider.requestCount, 0)
        }
    }

    // The request and its failure path belong to the same scenario.
    // swiftlint:disable:next function_body_length
    func testReadyUnknownGuestForwardsRequestAndProviderError() async {
        let requestedHost = RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 13, minor: 2, patch: 1),
            architecture: "x86_64",
            isAppleSilicon: false,
            gameModePlatformAvailable: false,
            isMacOS27OrLater: false,
            thermalState: .fair,
            isLowPowerModeEnabled: true,
            metalDeviceName: nil,
            metalFXSpatialScalingAvailable: false,
            metalFXTemporalScalingAvailable: false,
            gpuDeveloperToolsAvailable: false
        )
        let executableURL = URL(fileURLWithPath: "/tmp/demo-app.exe")
        let profile = makeProfile(guestCompatibility: .unknown)
        let arguments = ["", "two words", "\"quoted value\"", "Unicode 雪"]
        let environment = ["DEMO_VALUE": "value with spaces", "EMPTY_VALUE": ""]
        let request = RuntimeLaunchRequest(
            executableURL: executableURL,
            bottle: nil,
            arguments: arguments,
            environment: environment,
            profile: profile,
            host: requestedHost
        )

        let provider = RecordingGuestProvider(availability: .ready)
        let backend = WindowsGuestRuntimeBackend(provider: provider)
        do {
            try await backend.launch(request)
        } catch {
            XCTFail("Unexpected provider error: \(error)")
        }

        XCTAssertEqual(provider.requestCount, 1)
        let forwarded = provider.request(at: 0)
        XCTAssertEqual(forwarded?.executableURL, executableURL)
        XCTAssertNil(forwarded?.bottle)
        XCTAssertEqual(forwarded?.arguments, arguments)
        XCTAssertEqual(forwarded?.environment, environment)
        XCTAssertEqual(forwarded?.profile, profile)
        XCTAssertEqual(forwarded?.host, requestedHost)

        let failingProvider = RecordingGuestProvider(availability: .ready, throwsOnLaunch: true)
        let failingBackend = WindowsGuestRuntimeBackend(provider: failingProvider)
        var propagatedProviderError = false
        do {
            try await failingBackend.launch(request)
        } catch ProviderFailure.expected {
            propagatedProviderError = true
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(propagatedProviderError)
        XCTAssertEqual(failingProvider.requestCount, 1)
    }

    func testPerformancePolicyForEveryThermalAndPowerCombination() {
        // swiftlint:disable:next large_tuple
        let cases: [(HostThermalState, Bool, RuntimePerformancePolicy)] = [
            (.nominal, false, .maximumPerformance), (.nominal, true, .conserveEnergy),
            (.fair, false, .maximumPerformance), (.fair, true, .conserveEnergy),
            (.serious, false, .balanced), (.serious, true, .conserveEnergy),
            (.critical, false, .conserveEnergy), (.critical, true, .conserveEnergy)
        ]

        for (thermalState, lowPower, expected) in cases {
            let snapshot = makeHost(thermalState: thermalState, lowPower: lowPower)
            XCTAssertEqual(snapshot.performancePolicy, expected,
                           "thermalState=\(thermalState.rawValue), lowPower=\(lowPower)")
        }
    }

    func testWineLaunchWithoutBottleReportsBottleUnavailable() async {
        let request = RuntimeLaunchRequest(
            executableURL: URL(fileURLWithPath: "/tmp/demo-app.exe"),
            bottle: nil,
            arguments: [],
            environment: [:],
            profile: nil,
            host: host
        )
        var rejectedForMissingBottle = false

        do {
            try await WineRuntimeBackend().launch(request)
        } catch RuntimeLaunchError.issue(.bottleUnavailable) {
            rejectedForMissingBottle = true
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(rejectedForMissingBottle)
    }

    func testProfileMatchingIsCaseInsensitiveAndRejectsSimilarNames() {
        let profile = makeProfile(guestCompatibility: .unknown)

        XCTAssertTrue(profile.matches(executableURL: URL(fileURLWithPath: "/tmp/DEMO-APP.EXE")))
        XCTAssertFalse(profile.matches(executableURL: URL(fileURLWithPath: "/tmp/x-demo-app.exe")))
        XCTAssertFalse(profile.matches(executableURL: URL(fileURLWithPath: "/tmp/demo-app.exe.backup")))
    }

    private func makeProfile(
        wineCompatibility: RuntimeCompatibility = .supported,
        guestCompatibility: RuntimeCompatibility
    ) -> GameCompatibilityProfile {
        GameCompatibilityProfile(
            id: "demo-profile",
            displayName: "Demo App",
            executableNames: ["demo-app.exe"],
            antiCheat: .none,
            wineCompatibility: wineCompatibility,
            windowsGuestCompatibility: guestCompatibility,
            notes: "Synthetic test profile"
        )
    }

    private func makeHost(
        thermalState: HostThermalState,
        lowPower: Bool
    ) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: host.operatingSystemVersion,
            architecture: host.architecture,
            isAppleSilicon: host.isAppleSilicon,
            gameModePlatformAvailable: host.gameModePlatformAvailable,
            isMacOS27OrLater: host.isMacOS27OrLater,
            thermalState: thermalState,
            isLowPowerModeEnabled: lowPower,
            metalDeviceName: host.metalDeviceName,
            metalFXSpatialScalingAvailable: host.metalFXSpatialScalingAvailable,
            metalFXTemporalScalingAvailable: host.metalFXTemporalScalingAvailable,
            gpuDeveloperToolsAvailable: host.gpuDeveloperToolsAvailable
        )
    }
}

private enum ProviderFailure: Error, Sendable {
    case expected
}

private final class RecordingGuestProvider: WindowsGuestProvider, @unchecked Sendable {
    let availability: WindowsGuestAvailability

    private let lock = NSLock()
    private let throwsOnLaunch: Bool
    private var recordedRequests: [RuntimeLaunchRequest] = []

    init(availability: WindowsGuestAvailability, throwsOnLaunch: Bool = false) {
        self.availability = availability
        self.throwsOnLaunch = throwsOnLaunch
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    func request(at index: Int) -> RuntimeLaunchRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard recordedRequests.indices.contains(index) else { return nil }
        return recordedRequests[index]
    }

    func launch(_ request: RuntimeLaunchRequest) async throws {
        record(request)
        if throwsOnLaunch { throw ProviderFailure.expected }
    }

    private func record(_ request: RuntimeLaunchRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
    }
}
