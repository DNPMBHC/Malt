// SPDX-License-Identifier: GPL-3.0-or-later
// Unified runtime orchestrator bridging native Wine bottles and Anti-Cheat VM sessions.

import Combine
import Foundation

/// Errors raised by UnifiedRuntimeOrchestrator during launch or installation.
public enum UnifiedOrchestrationError: LocalizedError, Equatable, Sendable {
    case missingExecutable(String)
    case missingBottleURL(String)
    case missingVMBundle(String)
    case missingInstaller(String)
    case backendUnavailable(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            return "Executable not found: \(path)"
        case .missingBottleURL(let name):
            return "Wine bottle URL missing for game: \(name)"
        case .missingVMBundle(let path):
            return "Anti-Cheat VM bundle not found: \(path)"
        case .missingInstaller(let path):
            return "Installer not found: \(path)"
        case .backendUnavailable(let detail):
            return "Runtime backend unavailable: \(detail)"
        case .commandFailed(let detail):
            return "Runtime command failed: \(detail)"
        }
    }
}

/// Result of executing an external runtime helper command.
public struct OrchestratorCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Configuration paths for locating Wine, UTM-Custom, UTM.app, and guest lifecycle scripts.
public struct UnifiedOrchestratorConfiguration: Sendable {
    public let utmCustomAppPath: String
    public let utmAppPath: String
    public let goldenManagerScriptPath: String
    public let kioskShellScriptPath: String
    public let defaultPlayableVMBundlePath: String?
    public let defaultBottleURL: URL?

    public init(
        utmCustomAppPath: String = "/Applications/UTM-Custom.app",
        utmAppPath: String = "/Applications/UTM.app",
        goldenManagerScriptPath: String = "graphics-lab/golden_guest_manager.py",
        kioskShellScriptPath: String = "Whisky/Modules/guest-optimizer/scripts/kiosk-app-shell.ps1",
        defaultPlayableVMBundlePath: String? = nil,
        defaultBottleURL: URL? = nil
    ) {
        self.utmCustomAppPath = utmCustomAppPath
        self.utmAppPath = utmAppPath
        self.goldenManagerScriptPath = goldenManagerScriptPath
        self.kioskShellScriptPath = kioskShellScriptPath
        self.defaultPlayableVMBundlePath = defaultPlayableVMBundlePath
        self.defaultBottleURL = defaultBottleURL
    }
}

/// Unified entry point for launching, installing, and health-checking Wine and Anti-Cheat VM titles.
public final class UnifiedRuntimeOrchestrator: ObservableObject, @unchecked Sendable {
    public typealias CommandRunner = @Sendable (String, [String]) async throws -> OrchestratorCommandResult

    @Published public private(set) var activeEntryID: UUID?
    @Published public private(set) var lastStatusMessage: String = ""

    public let libraryStore: UnifiedGameLibraryStore
    public let configuration: UnifiedOrchestratorConfiguration

    private let fileManager: FileManager
    private let commandRunner: CommandRunner

    public init(
        libraryStore: UnifiedGameLibraryStore = UnifiedGameLibraryStore(),
        configuration: UnifiedOrchestratorConfiguration = UnifiedOrchestratorConfiguration(),
        fileManager: FileManager = .default,
        commandRunner: CommandRunner? = nil
    ) {
        self.libraryStore = libraryStore
        self.configuration = configuration
        self.fileManager = fileManager
        self.commandRunner = commandRunner ?? Self.defaultCommandRunner
    }

    public func launch(entry: UnifiedGameEntry) async throws {
        activeEntryID = entry.id
        defer { activeEntryID = nil }

        switch entry.engineKind {
        case .nativeWine:
            try await launchWineEntry(entry)
        case .antiCheatVM:
            try await launchAntiCheatVMEntry(entry)
        }

        var updated = entry
        updated.lastPlayedAt = Date()
        libraryStore.upsert(updated)
        lastStatusMessage = "Launched \(entry.name)"
    }

    public func install(
        installerURL: URL,
        engineKind: UnifiedEngineKind,
        title: String
    ) async throws -> UnifiedGameEntry {
        let installerPath = installerURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: installerPath) else {
            throw UnifiedOrchestrationError.missingInstaller(installerPath)
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty
            ? installerURL.deletingPathExtension().lastPathComponent
            : cleanTitle

        let entry: UnifiedGameEntry
        switch engineKind {
        case .nativeWine:
            entry = try await installViaWine(installerURL: installerURL, title: resolvedTitle)
        case .antiCheatVM:
            entry = try await installViaAntiCheatVM(installerURL: installerURL, title: resolvedTitle)
        }

        libraryStore.upsert(entry)
        lastStatusMessage = "Installed \(entry.name)"
        return entry
    }

    public func healthStatus() -> [String: Bool] {
        let wineReady = WhiskyWineInstaller.isWhiskyWineInstalled()
        let utmCustomReady = fileManager.fileExists(atPath: configuration.utmCustomAppPath)
        let utmAppReady = fileManager.fileExists(atPath: configuration.utmAppPath)
        let goldenManagerReady = fileManager.fileExists(atPath: configuration.goldenManagerScriptPath)
        let kioskScriptReady = fileManager.fileExists(atPath: configuration.kioskShellScriptPath)
        let storeParent = libraryStore.storageURL.deletingLastPathComponent().path(percentEncoded: false)
        let storeWritable = fileManager.isWritableFile(atPath: storeParent)
            || fileManager.isWritableFile(atPath: fileManager.homeDirectoryForCurrentUser.path(percentEncoded: false))

        return [
            "wine_ready": wineReady,
            "utm_custom_ready": utmCustomReady,
            "utm_app_ready": utmAppReady,
            "golden_manager_ready": goldenManagerReady,
            "kiosk_shell_script_ready": kioskScriptReady,
            "library_store_writable": storeWritable,
            "anti_cheat_vm_ready": utmCustomReady || utmAppReady
        ]
    }

    private func launchWineEntry(_ entry: UnifiedGameEntry) async throws {
        guard let bottleURL = entry.bottleURL ?? configuration.defaultBottleURL else {
            throw UnifiedOrchestrationError.missingBottleURL(entry.name)
        }
        guard fileManager.fileExists(atPath: entry.executablePath) else {
            throw UnifiedOrchestrationError.missingExecutable(entry.executablePath)
        }
        let bottlePath = bottleURL.path(percentEncoded: false)
        let result = try await commandRunner(
            "/usr/bin/env",
            ["WINEPREFIX=\(bottlePath)", "wine64", entry.executablePath]
        )
        guard result.exitCode == 0 else {
            throw UnifiedOrchestrationError.commandFailed(result.stderr)
        }
    }

    private func launchAntiCheatVMEntry(_ entry: UnifiedGameEntry) async throws {
        guard let vmPath = entry.vmBundlePath ?? configuration.defaultPlayableVMBundlePath,
              fileManager.fileExists(atPath: vmPath) else {
            throw UnifiedOrchestrationError.missingVMBundle(entry.vmBundlePath ?? "")
        }

        let executable: String
        let args: [String]
        let utmCustomBinary = "\(configuration.utmCustomAppPath)/Contents/MacOS/UTM"
        if fileManager.fileExists(atPath: utmCustomBinary) {
            executable = utmCustomBinary
            args = ["--game-shell-vm", vmPath]
        } else if fileManager.fileExists(atPath: configuration.goldenManagerScriptPath) {
            executable = "/usr/bin/python3"
            args = [configuration.goldenManagerScriptPath, "resume-launch", "--playable", vmPath]
        } else {
            throw UnifiedOrchestrationError.backendUnavailable("Neither UTM-Custom nor golden_guest_manager found")
        }

        let result = try await commandRunner(executable, args)
        guard result.exitCode == 0 else {
            throw UnifiedOrchestrationError.commandFailed(result.stderr)
        }
    }

    private func installViaWine(installerURL: URL, title: String) async throws -> UnifiedGameEntry {
        let bottleURL = configuration.defaultBottleURL
            ?? libraryStore.storageURL.deletingLastPathComponent().appending(path: "Bottles/Default")
        let result = try await commandRunner(
            "/usr/bin/env",
            ["WINEPREFIX=\(bottleURL.path(percentEncoded: false))", "wine64", installerURL.path(percentEncoded: false)]
        )
        guard result.exitCode == 0 else {
            throw UnifiedOrchestrationError.commandFailed(result.stderr)
        }
        return UnifiedGameEntry(
            name: title,
            executablePath: installerURL.path(percentEncoded: false),
            engineKind: .nativeWine,
            presetTier: .balancedRecommended,
            bottleURL: bottleURL
        )
    }

    private func installViaAntiCheatVM(installerURL: URL, title: String) async throws -> UnifiedGameEntry {
        let vmPath = configuration.defaultPlayableVMBundlePath ?? ""
        let utmCustomBinary = "\(configuration.utmCustomAppPath)/Contents/MacOS/UTM"
        if fileManager.fileExists(atPath: utmCustomBinary), !vmPath.isEmpty {
            let result = try await commandRunner(utmCustomBinary, ["--app-shell-vm", vmPath])
            guard result.exitCode == 0 else {
                throw UnifiedOrchestrationError.commandFailed(result.stderr)
            }
        }
        return UnifiedGameEntry(
            name: title,
            executablePath: installerURL.path(percentEncoded: false),
            engineKind: .antiCheatVM,
            presetTier: .balancedRecommended,
            vmBundlePath: vmPath.isEmpty ? nil : vmPath
        )
    }

    private static func defaultCommandRunner(
        executable: String,
        arguments: [String]
    ) async throws -> OrchestratorCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = OrchestratorCommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
