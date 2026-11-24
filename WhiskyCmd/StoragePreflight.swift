// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import WhiskyKit

extension Whisky {
    struct StoragePreflight: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: RuntimeCLI.localized(
            "runtime.cli.storagePreflight", fallback: "Check storage for a local Windows installer and print JSON."
        ))

        @Flag(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.bottlePath", fallback: "Interpret the bottle argument as a path instead of a name."
        )))
        var bottlePath = false

        @Option(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.storageTarget", fallback: "Check this directory for this command only."
        )))
        var target: String?

        @Option(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.storageGuestConfig", fallback: "Read a guest configuration from a JSON file for this preview."
        )))
        var guestConfig: String?

        @Argument(help: ArgumentHelp(RuntimeCLI.localized("runtime.cli.bottle", fallback: "The bottle name or path.")))
        var bottle: String

        @Argument(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.installer", fallback: "The path of the local Windows installer."
        )))
        var installer: String

        func run() throws {
            let result: RuntimeStoragePreflight
            do {
                let selectedBottle = try RuntimeCLI.findBottle(bottle, byPath: bottlePath, readOnly: true)
                let program = Program(url: URL(filePath: installer), bottle: selectedBottle, loadSettingsOnly: true)
                result = program.runtimeStoragePreflight(
                    targetDirectory: target.map { URL(filePath: $0, directoryHint: .isDirectory) },
                    guestConfiguration: try readGuestConfiguration()
                )
            } catch {
                writeStandardError(RuntimeCLI.message(for: error))
                throw ExitCode.failure
            }
            try Self.writeReport(result)
            guard result.isReady else { throw ExitCode.failure }
        }

        private func readGuestConfiguration() throws -> RuntimeGuestConfiguration? {
            guard let guestConfig else { return nil }
            do {
                let url = URL(filePath: guestConfig)
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw StorageGuestConfigurationError.invalidFile
                }
                return try JSONDecoder().decode(RuntimeGuestConfiguration.self, from: Data(contentsOf: url))
            } catch {
                throw StorageGuestConfigurationError.invalidFile
            }
        }

        private static func writeReport(_ result: RuntimeStoragePreflight) throws {
            let report: [String: Any] = [
                "version": 1,
                "state": result.state.rawValue,
                "isWritable": result.isWritable,
                "hasTargetDirectory": result.targetDirectory != nil,
                "availableBytes": (result.availableBytes as Any?) ?? NSNull(),
                "installerBytes": (result.installerBytes as Any?) ?? NSNull(),
                "reservedBytes": result.reservedBytes,
                "requiredBytes": (result.requiredBytes as Any?) ?? NSNull(),
                "guestMapping": result.guestMapping.rawValue
            ]
            do {
                var data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
                data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                writeStandardError(RuntimeCLI.localized(
                    "runtime.cli.storageEncodingFailed", fallback: "The storage check could not be reported."
                ))
                throw ExitCode.failure
            }
        }
    }

    struct IntegrityReport: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "integrity-report",
            abstract: RuntimeCLI.localized(
                "runtime.cli.integrityReport",
                fallback: "Print a read-only host SIP, signature, and Hardened Runtime attestation JSON."
            )
        )

        func run() throws {
            let report = RuntimeIntegrityAttestor.currentReport()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(report)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    struct BaselineReport: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "baseline-report",
            abstract: RuntimeCLI.localized(
                "runtime.cli.baselineReport",
                fallback: "Print unified host runtime lock, golden guest baseline, and 5C gate self-check JSON."
            )
        )

        @Option(help: ArgumentHelp("Optional path to golden-guest-manifest.json."))
        var goldenManifest: String?

        @Flag(help: ArgumentHelp("Print a human-readable diagnostic summary instead of compact JSON."))
        var summary = false

        func run() throws {
            let goldenURL = goldenManifest.map { URL(fileURLWithPath: $0) }
            let report = UnifiedRuntimeBaselineReport.collect(goldenManifestURL: goldenURL)
            if summary {
                print(Self.formatSummary(report))
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(report)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }

        private static func formatSummary(_ report: UnifiedRuntimeBaselineReport) -> String {
            var lines: [String] = []
            lines.append("Runtime Lock SHA-256 : \(report.runtimeManifestSHA256 ?? "unavailable")")
            lines.append("Golden Guest State   : \(report.goldenGuestState.rawValue)")
            if let golden = report.goldenGuestManifest {
                lines.append("  ID / Status        : \(golden.guestID) (\(golden.status ?? "unknown"))")
                let feature = golden.featureLevel ?? "?"
                lines.append("  WHQL 3D Driver     : \(golden.driverVersion ?? "unknown") (FL \(feature))")
                lines.append("  4C Optimizer       : \(golden.optimizerProfileID ?? "none")")
                let secState = golden.securityInvariantsPassed.map { $0 ? "passed" : "failed" } ?? "unknown"
                lines.append("  Security Invariants: \(secState)")
            }
            if let compat = report.compatibilitySummary {
                lines.append("Target Compatibility : \(compat.targetID) (snapshot \(compat.snapshotID))")
                lines.append("  Visual Stage       : \(compat.visualStage)")
                lines.append("  Root Cause         : \(compat.rootCauseCode)")
                lines.append("  DXVK/Venus Status  : \(compat.dxvkVenusStatus)")
                lines.append("  ACE ARM64 Coverage : \(compat.aceArm64Coverage)")
                lines.append("  Vendor VM Support  : \(compat.vendorVMSupport)")
                lines.append("  Mitigation Status  : \(compat.mitigationStatus)")
                lines.append("  Lobby / Match      : \(compat.protectedLobbyAndMatch)")
                lines.append("  Display Guidance   : \(compat.recommendedDisplayMode)")
                lines.append("  Pointer Guidance   : \(compat.pointerGuidanceCode)")
                lines.append("  Boundary           : \(compat.boundaryNote)")
            }
            for key in report.advisoryLocalizationKeys {
                lines.append("Advisory (\(key)) : \(RuntimeCLI.localized(key, fallback: key))")
            }
            if report.externalVolumes.isEmpty {
                lines.append("External Volumes     : none mounted")
            } else {
                for volume in report.externalVolumes {
                    let free = ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .file)
                    lines.append("External Volume      : \(volume.volumeName) (\(free) free)")
                }
            }
            let gate = report.guestSurfaceGate
            let gateRev = "Rev \(gate.contractRevision)/S\(gate.snapshotRevision)"
            lines.append("5C GuestSurface Gate : enabled=\(gate.gameShellEntryEnabled) (\(gateRev))")
            return lines.joined(separator: "\n")
        }
    }
}

private enum StorageGuestConfigurationError: LocalizedError {
    case invalidFile
    case invalidBackend(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            RuntimeCLI.localized(
                "runtime.cli.storageGuestConfigInvalid",
                fallback: "The guest configuration could not be read. Check that it is a valid JSON file."
            )
        case .invalidBackend(let value):
            String(
                format: RuntimeCLI.localized(
                    "runtime.cli.backendInvalid",
                    fallback: "Unknown backend '%@'. Use auto, wine, windowsGuest, or remotePhysics."
                ),
                value
            )
        }
    }
}

extension RuntimeCLI {
    static func parseBackend(_ rawValue: String?) throws -> RuntimeBackendKind? {
        guard let rawValue else { return nil }
        if rawValue == "auto" { return nil }
        guard let parsed = RuntimeBackendKind(rawValue: rawValue) else {
            throw StorageGuestConfigurationError.invalidBackend(rawValue)
        }
        return parsed
    }
}
