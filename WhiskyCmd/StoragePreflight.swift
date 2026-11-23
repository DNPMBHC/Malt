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
