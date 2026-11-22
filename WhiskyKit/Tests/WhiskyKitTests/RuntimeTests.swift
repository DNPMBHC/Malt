// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class RuntimeTests: XCTestCase, @unchecked Sendable {
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

    func testProtectedGameRoutesToUnconfiguredGuestAndCannotLaunch() {
        let url = URL(fileURLWithPath: "/tmp/VALORANT.exe")
        let plan = RuntimeCoordinator().plan(for: url, host: host)

        XCTAssertEqual(plan.preferredBackend, .windowsGuest)
        XCTAssertEqual(plan.capability.compatibility, .vendorRestricted)
        XCTAssertFalse(plan.capability.canLaunch)
    }

    func testUnknownExecutableDefaultsToWine() {
        let url = URL(fileURLWithPath: "/tmp/example.exe")
        let plan = RuntimeCoordinator(wineAvailable: { true }).plan(for: url, host: host)

        XCTAssertEqual(plan.preferredBackend, .wine)
        XCTAssertTrue(plan.capability.canLaunch)
        XCTAssertNil(plan.profile)
    }

    func testTheFinalsProfileUsesVendorRestrictedStatus() {
        let url = URL(fileURLWithPath: "/tmp/Discovery-Win64-Shipping.exe")
        let profile = GameCompatibilityDatabase.profile(for: url)

        XCTAssertEqual(profile?.antiCheat, .easyAntiCheat)
        XCTAssertEqual(profile?.wineCompatibility, .vendorRestricted)
    }

    func testExplicitProfileResolvesAnIndirectLauncher() throws {
        let directTarget = URL(fileURLWithPath: "/tmp/VALORANT.exe")
        let profile = try XCTUnwrap(GameCompatibilityDatabase.profile(for: directTarget))
        let launcher = URL(fileURLWithPath: "/tmp/demo launcher.cmd")
        let coordinator = RuntimeCoordinator()

        let selected = coordinator.plan(for: launcher, selection: .profile(profile.id), host: host)
        XCTAssertEqual(selected.profile?.id, profile.id)
        XCTAssertEqual(selected.preferredBackend, .windowsGuest)
        XCTAssertFalse(selected.capability.canLaunch)

        let ordinary = coordinator.plan(for: launcher, selection: .ordinary, host: host)
        XCTAssertNil(ordinary.profile)
        XCTAssertEqual(ordinary.preferredBackend, .wine)
    }

    func testAmbiguousTargetsAndConflictingProfilesAreBlocked() throws {
        let coordinator = RuntimeCoordinator(wineAvailable: { true })
        let batch = URL(fileURLWithPath: "/tmp/demo command.bat")
        let automatic = coordinator.plan(for: batch, host: host)
        XCTAssertTrue(automatic.capability.issues.contains(.selectTarget))
        XCTAssertFalse(automatic.capability.canLaunch)

        let direct = URL(fileURLWithPath: "/tmp/VALORANT.exe")
        let ordinary = coordinator.plan(for: direct, selection: .ordinary, host: host)
        XCTAssertTrue(ordinary.capability.issues.contains(.conflictingTarget))
        XCTAssertEqual(ordinary.preferredBackend, .windowsGuest)
    }

    func testReadyGuestAndSelfProbeDoNotImplyVendorSupportOrGameVerification() {
        let provider = RecordingGuest()
        let coordinator = RuntimeCoordinator(guestProvider: provider, wineAvailable: { true }, evidence: { _, _ in
            RuntimeEvidence(kernelDiagnostics: .selfProbeVerified)
        })
        let direct = URL(fileURLWithPath: "/tmp/VALORANT.exe")
        let plan = coordinator.plan(for: direct, host: host)
        XCTAssertEqual(plan.capability.readiness, .ready)
        XCTAssertEqual(plan.capability.evidence.kernelDiagnostics, .selfProbeVerified)
        XCTAssertEqual(plan.capability.evidence.vendorSupport, .unknown)
        XCTAssertEqual(plan.capability.evidence.gameVerification, .untested)
        XCTAssertFalse(plan.capability.canLaunch)
    }

    func testGuestLaunchPreservesRequestAndReportsNonzeroExit() async throws {
        let provider = RecordingGuest(statuses: [27, 0])
        let coordinator = RuntimeCoordinator(guestProvider: provider)
        let file = try createProgramFixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let arguments = ["--setting", "a b", "literal \"quote\"", ""]
        let environment = ["DEMO_VALUE": "a b='quoted'"]
        let configuration = RuntimeGuestConfiguration(identifier: "demo-guest", architecture: "arm64")
        let request = RuntimeLaunchRequest(executableURL: file, bottle: nil, arguments: arguments,
                                           environment: environment, host: host, backend: .windowsGuest,
                                           guestConfiguration: configuration)

        do {
            try await coordinator.launch(request)
            XCTFail("Expected nonzero guest process exit")
        } catch RuntimeLaunchError.processExit(let status) {
            XCTAssertEqual(status, 27)
        }
        try await coordinator.launch(request)
        let launches = await provider.launches
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.first?.arguments, arguments)
        XCTAssertEqual(launches.first?.environment, environment)
        XCTAssertEqual(launches.first?.guestConfiguration, configuration)
    }

    func testUnconfiguredGuestStopsBeforeStartingSession() throws {
        let file = try createProgramFixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let request = RuntimeLaunchRequest(executableURL: file, bottle: nil, host: host, backend: .windowsGuest)
        XCTAssertThrowsError(try RuntimeCoordinator().validate(request)) { error in
            guard case RuntimeLaunchError.blocked(_, let issues) = error else {
                return XCTFail("Expected blocked guest launch")
            }
            XCTAssertEqual(issues, [.guestUnconfigured])
        }
    }

    func testEvidenceMetadataRoundTripsSnakeCaseJSON() throws {
        let metadata = RuntimeEvidenceMetadata(
            distributionID: "demo-cn-windows",
            clientPlatform: "windows",
            hostCPUArchitecture: "arm64",
            guestCPUArchitecture: "aarch64",
            guestOSBuild: "26100",
            guestOSEdition: "Windows 11 Pro",
            securityCapabilities: ["tpm2": .enabled, "hvci": .presentDisabled],
            securityEnabledState: ["secure_boot": .enabled, "iommu": .absent],
            installedClientBuild: "1.2.3.4",
            driverBinaryMachine: "0xAA64",
            driverFileVersion: "1.0.0.1",
            sourceSnapshotID: "snapshot-2026-11-22"
        )
        let evidence = RuntimeEvidence(
            kernelDiagnostics: .selfProbeVerified,
            vendorSupport: .unknown,
            gameVerification: .untested,
            metadata: metadata
        )
        let encoded = try JSONEncoder().encode(evidence)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedMeta = try XCTUnwrap(jsonObject["metadata"] as? [String: Any])
        XCTAssertEqual(encodedMeta["distribution_id"] as? String, "demo-cn-windows")
        XCTAssertEqual(encodedMeta["client_platform"] as? String, "windows")
        XCTAssertEqual(encodedMeta["host_cpu_architecture"] as? String, "arm64")
        XCTAssertEqual(encodedMeta["guest_cpu_architecture"] as? String, "aarch64")
        XCTAssertEqual(encodedMeta["guest_os_build"] as? String, "26100")
        XCTAssertEqual(encodedMeta["guest_os_edition"] as? String, "Windows 11 Pro")
        XCTAssertEqual(encodedMeta["installed_client_build"] as? String, "1.2.3.4")
        XCTAssertEqual(encodedMeta["driver_binary_machine"] as? String, "0xAA64")
        XCTAssertEqual(encodedMeta["driver_file_version"] as? String, "1.0.0.1")
        XCTAssertEqual(encodedMeta["source_snapshot_id"] as? String, "snapshot-2026-11-22")
        XCTAssertEqual(try JSONDecoder().decode(RuntimeEvidence.self, from: encoded), evidence)
    }

    func testLegacyProfileAndEvidenceJSONUseDefaults() throws {
        let emptyEvidence = try JSONDecoder().decode(RuntimeEvidence.self, from: Data("{}".utf8))
        XCTAssertEqual(emptyEvidence, RuntimeEvidence())
        XCTAssertNil(emptyEvidence.metadata)

        let legacyProfileJSON = """
        {
          "id": "legacy-game",
          "displayName": "Legacy Game",
          "executableNames": ["legacy.exe"],
          "antiCheat": "none",
          "wineCompatibility": "supported",
          "windowsGuestCompatibility": "unknown",
          "notes": "Legacy notes"
        }
        """
        let legacyProfile = try JSONDecoder().decode(
            GameCompatibilityProfile.self, from: Data(legacyProfileJSON.utf8)
        )
        XCTAssertNil(legacyProfile.metadata)
        XCTAssertEqual(legacyProfile.notesLocalizationKey, "runtime.profile.legacy-game")
        XCTAssertEqual(legacyProfile.localizedNotes(), "Legacy notes")
    }

    func testWineResourcePolicyWiringRespectsFallbackAndNonDestructiveOverride() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.exe")
        try Data().write(to: file)

        let bottle = Bottle(bottleUrl: directory)
        bottle.settings.dxvk = true
        let stressedHost = RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 27, minor: 0, patch: 0),
            architecture: "arm64",
            isAppleSilicon: true,
            gameModePlatformAvailable: true,
            thermalState: .serious,
            isLowPowerModeEnabled: true,
            metalDeviceName: "Test GPU",
            metalFXSpatialScalingAvailable: true,
            metalFXTemporalScalingAvailable: true,
            gpuDeveloperToolsAvailable: true
        )
        let backend = WineRuntimeBackend(isAvailable: { true })
        let baseRequest = RuntimeLaunchRequest(
            executableURL: file, bottle: bottle, environment: ["DXVK_FRAME_RATE": "120"], host: stressedHost
        )

        // Default fallback switch is off: environment remains unchanged.
        XCTAssertFalse(bottle.settings.adaptiveResourcePolicyEnabled)
        XCTAssertEqual(backend.resolvedRequest(for: baseRequest).environment, ["DXVK_FRAME_RATE": "120"])

        // Enabled + DXVK + conserveEnergy injects missing compiler thread cap without clobbering user FPS cap.
        bottle.settings.adaptiveResourcePolicyEnabled = true
        let dxvkResolved = backend.resolvedRequest(for: baseRequest)
        XCTAssertEqual(dxvkResolved.environment["DXVK_FRAME_RATE"], "120")
        XCTAssertEqual(dxvkResolved.environment["DXVK_NUM_COMPILER_THREADS"], "1")

        // Enabled + D3DMetal injects no undocumented variables.
        bottle.settings.dxvk = false
        let d3dmRequest = RuntimeLaunchRequest(
            executableURL: file, bottle: bottle, environment: [:], host: stressedHost
        )
        XCTAssertEqual(backend.resolvedRequest(for: d3dmRequest).environment, [:])
        let plan = RuntimeCoordinator(wineAvailable: { true }).plan(for: file, host: stressedHost)
        XCTAssertNotNil(plan.wineResourcePolicy(dxvk: false, enabled: true).unmanagedDomainNote)
        XCTAssertEqual(plan.guestResourcePolicy(enabled: true).suggestedPresentationFrameRateCap, 30)
    }

    private func createProgramFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sample app.exe")
        try Data().write(to: file)
        return file
    }
}

private actor RecordingGuest: WindowsGuestProvider {
    nonisolated let availability: WindowsGuestAvailability = .ready
    private var statuses: [Int32]
    private(set) var launches: [RuntimeLaunchRequest] = []

    init(statuses: [Int32] = []) {
        self.statuses = statuses
    }

    func start(_ request: RuntimeLaunchRequest) async throws -> RuntimeSession {
        launches.append(request)
        let status = statuses.removeFirst()
        return RuntimeSession(wait: { RuntimeExitResult(status: status) }, cancel: {})
    }

    func launch(_ request: RuntimeLaunchRequest) async throws {
        _ = try await start(request).wait()
    }
}
