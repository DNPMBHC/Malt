// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

@MainActor
final class InstalledGameRegistrationTests: XCTestCase {
    func testDiscoveryDeduplicatesCandidatesWithoutMarkingInstallerReady() async throws {
        let fixture = try fixture()
        let item: [String: String] = [
            "name": "Sample Game", "executablePath": candidate(fixture).executablePath,
            "arguments": "--launch-product=sample"
        ]
        let result = try output("GAME_DISCOVERY_V1=", [
            "schemaVersion": 1, "vmIdentifier": fixture.identifier, "candidates": [item, item]
        ])
        let candidates = try await service(fixture) { _, _, _ in result }.discover(for: fixture.entry)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.arguments, "--launch-product=sample")
        XCTAssertEqual(fixture.store.entries.first?.installationState, .installerRequested)
    }

    func testDiscoveryAcceptsEmptyResultsAndUsesLiteralReadOnlyShortcutQuery() async throws {
        let fixture = try fixture()
        let result = try output("GAME_DISCOVERY_V1=", [
            "schemaVersion": 1, "vmIdentifier": fixture.identifier, "candidates": []
        ])
        let service = service(fixture) { _, arguments, environment in
            XCTAssertEqual(arguments.first, "exec")
            XCTAssertTrue(arguments.contains(fixture.identifier))
            XCTAssertEqual(environment["__DEMOAPP_TIMEOUT_SECONDS"], "30")
            let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(arguments.last)))
            let script = try XCTUnwrap(String(data: data, encoding: .utf16LittleEndian))
            XCTAssertTrue(script.contains("CreateShortcut"))
            XCTAssertTrue(script.contains("Win32_ComputerSystem"))
            XCTAssertTrue(script.contains("ProfileList"))
            XCTAssertTrue(script.contains("Test-Path -LiteralPath"))
            XCTAssertFalse(script.contains("Start-Process"))
            XCTAssertFalse(script.contains("Invoke-Expression"))
            XCTAssertTrue(script.contains("sam''ple"))
            return result
        }
        let candidates = try await service.discover(for: fixture.entry, query: "sam'ple")
        XCTAssertTrue(candidates.isEmpty)
    }

    func testDiscoveryRejectsWrongGuestAndMalformedResponse() async throws {
        let fixture = try fixture()
        let wrongGuest = try output("GAME_DISCOVERY_V1=", [
            "schemaVersion": 1, "vmIdentifier": UUID().uuidString, "candidates": []
        ])
        for result in [wrongGuest, OrchestratorCommandResult(exitCode: 0, stdout: "not-json")] {
            do {
                _ = try await service(fixture) { _, _, _ in result }.discover(for: fixture.entry)
                XCTFail("Invalid discovery must fail")
            } catch is UnifiedOrchestrationError {}
        }
        XCTAssertEqual(fixture.store.entries.first?.installationState, .installerRequested)
    }

    func testRegisterChecksExistencePersistsArgumentsAndPreservesIdentity() async throws {
        let fixture = try fixture()
        let result = try registrationOutput(fixture)
        let arguments = "--launch-product=sample --launch-patchline=live"
        let registered = try await service(fixture) { _, _, _ in result }
            .register(entry: fixture.entry, candidate: candidate(fixture, arguments: arguments))
        XCTAssertEqual(registered.id, fixture.entry.id)
        XCTAssertEqual(registered.installationState, .ready)
        XCTAssertEqual(registered.launchArguments, arguments)
        XCTAssertEqual(registered.launchWorkingDirectory, #"C:\Games\Sample"#)
        XCTAssertEqual(registered.executablePath, candidate(fixture).executablePath)
        let reloaded = UnifiedGameLibraryStore(storageURL: fixture.store.storageURL)
        reloaded.load()
        XCTAssertEqual(reloaded.entries.first?.launchArguments, arguments)
        XCTAssertEqual(reloaded.entries.first?.installationState, .ready)
    }

    func testCustomWorkingDirectoryAndQuotedArgumentsArePreserved() async throws {
        let fixture = try fixture()
        let directory = #"C:\Games\Player's Files"#
        let arguments = #"--profile "Player One" --tag=O'Neil"#
        let selected = InstalledGameCandidate(
            name: "Sample", executablePath: candidate(fixture).executablePath,
            arguments: arguments, workingDirectory: directory, vmIdentifier: fixture.identifier)
        let result = try output("GAME_ENTRY_V1=", [
            "schemaVersion": 1, "vmIdentifier": fixture.identifier, "exists": true,
            "executablePath": selected.executablePath, "directoryExists": true, "workingDirectory": directory
        ])
        let registered = try await service(fixture) { _, args, _ in
            let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(args.last)))
            let script = try XCTUnwrap(String(data: data, encoding: .utf16LittleEndian))
            XCTAssertTrue(script.contains("Player''s Files"))
            return result
        }.register(entry: fixture.entry, candidate: selected)
        XCTAssertEqual(registered.launchWorkingDirectory, directory)
        XCTAssertEqual(registered.launchArguments, arguments)
    }

    func testMissingExecutableDoesNotMarkInstallationComplete() async throws {
        let fixture = try fixture()
        let result = try registrationOutput(fixture, exists: false)
        do {
            _ = try await service(fixture) { _, _, _ in result }
                .register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("Missing executable must fail")
        } catch is UnifiedOrchestrationError {}
        XCTAssertEqual(fixture.store.entries.first, fixture.entry)
    }

    func testUnsafeOrCrossGuestCandidateNeverDispatches() async throws {
        let fixture = try fixture()
        let candidates = [
            InstalledGameCandidate(name: "Game", executablePath: #"C:\setup.msi"#, vmIdentifier: fixture.identifier),
            InstalledGameCandidate(name: "Game", executablePath: #"C:\..\game.exe"#, vmIdentifier: fixture.identifier),
            InstalledGameCandidate(name: "Game", executablePath: "/game.exe", vmIdentifier: fixture.identifier),
            InstalledGameCandidate(
                name: "Game", executablePath: #"C:\game.exe"#,
                arguments: "bad\nargs", vmIdentifier: fixture.identifier),
            InstalledGameCandidate(name: "Game", executablePath: #"C:\game.exe"#, vmIdentifier: UUID().uuidString)
        ]
        for candidate in candidates {
            do {
                _ = try await service(fixture) { _, _, _ in
                    XCTFail("Unsafe candidate must not dispatch")
                    return OrchestratorCommandResult(exitCode: 1)
                }.register(entry: fixture.entry, candidate: candidate)
                XCTFail("Unsafe candidate must fail")
            } catch is UnifiedOrchestrationError {}
        }
    }

    func testAutomationDenialPreservesInstallerState() async throws {
        let fixture = try fixture()
        do {
            _ = try await service(fixture) { _, _, _ in
                OrchestratorCommandResult(exitCode: 1, stderr: "AUTOMATION_PERMISSION_DENIED -1743")
            }.register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("Denied permission must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("自动化"))
        }
        XCTAssertEqual(fixture.store.entries.first, fixture.entry)
    }

    func testCancellationNeverSavesReadyEntry() async throws {
        let fixture = try fixture()
        do {
            _ = try await service(fixture) { _, _, _ in throw CancellationError() }
                .register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.store.entries.first, fixture.entry)
    }

    func testConcurrentEntryChangeIsNotOverwritten() async throws {
        let fixture = try fixture()
        let result = try registrationOutput(fixture)
        do {
            _ = try await service(fixture) { _, _, _ in
                await MainActor.run {
                    var updated = fixture.entry
                    updated.name = "Updated by another operation"
                    fixture.store.upsert(updated)
                }
                return result
            }.register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("Concurrent changes must not be overwritten")
        } catch is UnifiedOrchestrationError {}
        XCTAssertEqual(fixture.store.entries.first?.name, "Updated by another operation")
        XCTAssertEqual(fixture.store.entries.first?.installationState, .installerRequested)
    }

    func testStaleInputCannotReplaceANewerStoredEntry() async throws {
        let fixture = try fixture()
        var newer = fixture.entry
        newer.name = "Newer title"
        fixture.store.upsert(newer)
        do {
            _ = try await service(fixture) { _, _, _ in
                XCTFail("A stale entry must fail before querying the guest")
                return OrchestratorCommandResult(exitCode: 1)
            }.register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("A stale entry must not replace current data")
        } catch is UnifiedOrchestrationError {}
        XCTAssertEqual(fixture.store.entries.first, newer)
    }

    func testGuestReplacementDuringQueryDoesNotRegisterOldResponse() async throws {
        let fixture = try fixture()
        let result = try registrationOutput(fixture)
        do {
            _ = try await service(fixture) { _, _, _ in
                let config: [String: Any] = ["Information": ["UUID": UUID().uuidString]]
                try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
                    .write(to: fixture.bundle.appending(path: "config.plist"))
                return result
            }.register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("A response from the replaced guest must not be saved")
        } catch is UnifiedOrchestrationError {}
        XCTAssertEqual(fixture.store.entries.first, fixture.entry)
    }

    func testMissingWorkingDirectoryDoesNotMarkEntryReady() async throws {
        let fixture = try fixture()
        let result = try output("GAME_ENTRY_V1=", [
            "schemaVersion": 1, "vmIdentifier": fixture.identifier, "exists": true,
            "executablePath": candidate(fixture).executablePath,
            "directoryExists": false, "workingDirectory": ""
        ])
        do {
            _ = try await service(fixture) { _, _, _ in result }
                .register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("A missing working directory must not be registered")
        } catch is UnifiedOrchestrationError {}
        XCTAssertEqual(fixture.store.entries.first, fixture.entry)
    }

    func testPersistenceFailureRestoresInMemoryInstallerState() async throws {
        let fixture = try fixture()
        let result = try registrationOutput(fixture)
        try FileManager.default.removeItem(at: fixture.store.storageURL)
        try FileManager.default.createDirectory(at: fixture.store.storageURL, withIntermediateDirectories: false)
        do {
            _ = try await service(fixture) { _, _, _ in result }
                .register(entry: fixture.entry, candidate: candidate(fixture))
            XCTFail("Persistence failure must be visible")
        } catch is UnifiedOrchestrationError {}
        XCTAssertEqual(fixture.store.entries.first, fixture.entry)
    }

    func testLegacyGameEntriesDecodeWithoutLaunchArguments() throws {
        let entry = UnifiedGameEntry(name: "Sample", executablePath: #"C:\game.exe"#, engineKind: .antiCheatVM)
        let data = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "launchArguments")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(UnifiedGameEntry.self, from: legacy)
        XCTAssertNil(decoded.launchArguments)
        XCTAssertNil(decoded.launchWorkingDirectory)
    }

    func testGameAliasesAndInvalidSearchQuery() throws {
        XCTAssertEqual(try InstalledGameRegistrationService.searchTerms("无畏契约安装器"), ["VALORANT", "无畏契约"])
        XCTAssertThrowsError(try InstalledGameRegistrationService.searchTerms("x"))
        XCTAssertThrowsError(try InstalledGameRegistrationService.searchTerms("sample\ncommand"))
    }
}

extension InstalledGameRegistrationTests {
    private struct Fixture: Sendable {
        let directory: URL
        let bundle: URL
        let identifier: String
        let store: UnifiedGameLibraryStore
        let resolved: ResolvedRuntimePaths
        let entry: UnifiedGameEntry
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bundle = directory.appending(path: "playable.utm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let identifier = UUID().uuidString
        let config: [String: Any] = ["Information": ["UUID": identifier]]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            .write(to: bundle.appending(path: "config.plist"))
        let store = UnifiedGameLibraryStore(storageURL: directory.appending(path: "library.json"))
        let entry = UnifiedGameEntry(
            name: "Sample Game", executablePath: "/installer.exe", engineKind: .antiCheatVM,
            lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            vmBundlePath: bundle.path, installationState: .installerRequested)
        store.upsert(entry)
        return Fixture(
            directory: directory, bundle: bundle, identifier: identifier, store: store,
            resolved: ResolvedRuntimePaths(
                containerHelperBinaryPath: nil, isEmbeddedHelper: false,
                goldenManagerScriptPath: nil, kioskShellScriptPath: nil,
                usesEmbeddedScripts: false, playableVMBundlePath: bundle.path), entry: entry)
    }

    private func service(
        _ fixture: Fixture, runner: @escaping UnifiedRuntimeOrchestrator.CommandRunner
    ) -> InstalledGameRegistrationService {
        InstalledGameRegistrationService(
            libraryStore: fixture.store, resolved: fixture.resolved,
            controlBinaryPath: "/usr/bin/true", commandRunner: runner)
    }

    private func candidate(_ fixture: Fixture, arguments: String = "") -> InstalledGameCandidate {
        InstalledGameCandidate(
            name: "Sample Game", executablePath: #"C:\Games\Sample\launcher.exe"#,
            arguments: arguments, vmIdentifier: fixture.identifier)
    }

    private func output(_ marker: String, _ object: [String: Any]) throws -> OrchestratorCommandResult {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        return OrchestratorCommandResult(exitCode: 0, stdout: marker + json)
    }

    private func registrationOutput(_ fixture: Fixture, exists: Bool = true) throws -> OrchestratorCommandResult {
        try output("GAME_ENTRY_V1=", [
            "schemaVersion": 1, "vmIdentifier": fixture.identifier,
            "exists": exists, "executablePath": exists ? candidate(fixture).executablePath : "",
            "directoryExists": true, "workingDirectory": #"C:\Games\Sample"#
        ])
    }
}
