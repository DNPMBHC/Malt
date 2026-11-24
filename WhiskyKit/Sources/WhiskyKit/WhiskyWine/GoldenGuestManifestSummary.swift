// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Read-only compatibility summary for a tracked target from `compatibility-matrix.json`.
public struct CompatibilityTargetSummary: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let targetID: String
    public let productName: String
    public let updatedOn: String
    public let visualStage: String
    public let rootCauseCode: String
    public let dxvkVenusStatus: String
    public let aceArm64Coverage: String
    public let vendorVMSupport: String
    public let recommendedDisplayMode: String
    public let pointerGuidanceCode: String
    public let phase8VerificationStatus: String
    public let fiveDimensionStates: BundledMatrixFiveDimensionStates
    public let boundaryNote: String
}

/// Redacted external volume capacity summary for storage readiness checks.
public struct ExternalVolumeSummary: Codable, Sendable, Equatable, Identifiable {
    public let volumeName: String
    public let freeBytes: Int64

    public var id: String { volumeName }
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

/// Unified host runtime lock + golden guest baseline + compatibility + external storage self-check summary.
public struct UnifiedRuntimeBaselineReport: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let runtimeManifestSHA256: String?
    public let runtimeVerification: RuntimeManifestVerificationReport?
    public let goldenGuestState: GoldenGuestManifestState
    public let goldenGuestManifestSHA256: String?
    public let goldenGuestManifest: GoldenGuestBaselineManifest?
    public let compatibilitySummary: CompatibilityTargetSummary?
    public let externalVolumes: [ExternalVolumeSummary]
    public let guestSurfaceGate: GuestSurfaceIntegrationGateStatus
    public let hostIntegrity: RuntimeIntegrityReport
    public let advisoryLocalizationKeys: [String]

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

        let volumes = WhiskyWineInstaller.mountedExternalVolumes(fileManager: fileManager).map {
            ExternalVolumeSummary(volumeName: $0.url.lastPathComponent, freeBytes: $0.freeBytes)
        }

        let advisories = diagnosticAdvisories(for: goldenResult.manifest)

        return UnifiedRuntimeBaselineReport(
            schemaVersion: "1.2.0",
            runtimeManifestSHA256: runtimeSHA,
            runtimeVerification: verification,
            goldenGuestState: goldenResult.state,
            goldenGuestManifestSHA256: goldenResult.sha256,
            goldenGuestManifest: goldenResult.manifest,
            compatibilitySummary: loadTargetCompatibilitySummary(bundle: bundle),
            externalVolumes: volumes,
            guestSurfaceGate: .current,
            hostIntegrity: RuntimeIntegrityAttestor.currentReport(),
            advisoryLocalizationKeys: advisories
        )
    }

    private static func diagnosticAdvisories(for manifest: GoldenGuestBaselineManifest?) -> [String] {
        guard let version = manifest?.driverVersion,
              version == "100.6.101.58000" || version == "v100.6.101.58000" else {
            return []
        }
        return [
            "settings.goldenGuest.advisory.viogpu3dResize",
            "settings.goldenGuest.advisory.doNotReplaceSignedDLL",
            "settings.goldenGuest.advisory.pointerModeCheck"
        ]
    }

    private static func loadTargetCompatibilitySummary(bundle: Bundle) -> CompatibilityTargetSummary? {
        let resolvedBundle = (bundle == .main
            ? RuntimeManifestVerifier.defaultAppBundleURL().flatMap(Bundle.init(url:))
            : nil) ?? bundle
        guard let matrix = try? BundledCompatibilityMatrix.load(bundle: resolvedBundle),
              let record = matrix.records.first(where: { $0.targetID == "target-cn" })
                ?? matrix.records.first else {
            return nil
        }
        return CompatibilityTargetSummary(
            snapshotID: matrix.sourceSnapshotID,
            targetID: record.targetID ?? record.recordID,
            productName: record.productName,
            updatedOn: record.updatedOn,
            visualStage: "entered_game_ui_freeze_on_resize",
            rootCauseCode: "neptune_umd_swapchain_resize_deadlock",
            dxvkVenusStatus: "probe_passed_0lsb_launcher_purges_dropin_dll",
            aceArm64Coverage: "partial_core_arm64_running_ace_game_x64_blocked_1275",
            vendorVMSupport: "unknown",
            recommendedDisplayMode: "1280x720_windowed_static_no_dynamic_resolution",
            pointerGuidanceCode: "utm_check_usb_tablet_or_capture_cursor_on_window_mode",
            phase8VerificationStatus: "pending_8a_verification",
            fiveDimensionStates: record.fiveDimensionStates,
            boundaryNote: "Entered fullscreen/windowed UI on WHQL viogpu3d; SwapChain resize "
                + "triggers neptune_umd deadlock. ACE-CORE runs natively on ARM64 while "
                + "ACE-GAME.sys (x64) is blocked with 1275; vendor VM support remains unknown."
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
        var probe = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<5 {
            candidates.append(probe.appending(path: "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"))
            candidates.append(probe.appending(path: "Whisky/Modules/guest-golden/golden-guest-manifest.json"))
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        return candidates
    }
}
