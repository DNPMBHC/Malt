// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class RuntimeProcessTests: XCTestCase, @unchecked Sendable {
    func testArgumentsPreserveSpacesQuotesEmptyValuesAndEscapes() throws {
        let input = #""two words" 'say "hello"' '' before\ after plain"#
        XCTAssertEqual(try RuntimeArguments.parse(input), ["two words", "say \"hello\"", "", "before after", "plain"])
        XCTAssertEqual(try RuntimeArguments.parse("  \t\n  "), [])
    }

    func testArgumentsRejectIncompleteQuoting() {
        XCTAssertThrowsError(try RuntimeArguments.parse("'missing"))
        XCTAssertThrowsError(try RuntimeArguments.parse("ending\\"))
    }

    func testExplicitArgumentsReplaceSavedValuesWithoutParsingThem() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let executable = directory.appending(path: "sample.exe")
        try Data().write(to: executable)
        let program = Program(url: executable, bottle: Bottle(bottleUrl: directory))
        program.settings.arguments = #""saved value" ''"#
        XCTAssertEqual(try program.runtimeRequest().arguments, ["saved value", ""])

        program.settings.arguments = "'unfinished"
        XCTAssertThrowsError(try program.runtimeRequest()) { error in
            guard case RuntimeLaunchError.issue(.unmatchedQuote) = error else {
                return XCTFail("Expected an unmatched quote error, got \(error)")
            }
        }
        let override = ["two words", #"literal "quote""#, ""]
        XCTAssertEqual(try program.runtimeRequest(arguments: override).arguments, override)
        XCTAssertEqual(try program.runtimeRequest(arguments: []).arguments, [])
    }

    func testShellQuotingRoundTripsLiteralArguments() throws {
        let values = ["", "one two", "quote ' and \"", "line one\nline two", "$0 and *"]
        let command = "printf '%s\\n' " + values.map(RuntimeArguments.quote).joined(separator: " ")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let actualOutput = String(bytes: data, encoding: .utf8)
        XCTAssertEqual(actualOutput, values.joined(separator: "\n") + "\n")
    }

    func testProgramSettingsFollowSymlinksAndContainerMoves() throws {
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        let container = workspace.appendingPathComponent("container", isDirectory: true)
        let programs = container.appendingPathComponent("programs", isDirectory: true)
        try files.createDirectory(at: programs, withIntermediateDirectories: true)
        let program = programs.appendingPathComponent("sample.exe")
        try Data().write(to: program)
        let programLink = programs.appendingPathComponent("sample-link.exe")
        try files.createSymbolicLink(atPath: programLink.path, withDestinationPath: program.lastPathComponent)
        let containerLink = workspace.appendingPathComponent("container-link", isDirectory: true)
        try files.createSymbolicLink(at: containerLink, withDestinationURL: container)
        let linkedProgram = containerLink.appendingPathComponent("programs/sample-link.exe")

        let original = Program(url: program, bottle: Bottle(bottleUrl: container))
        let arguments = #""two words" 'say "hello"' '' 日本語"#
        let expected = ["two words", "say \"hello\"", "", "日本語"]
        let target = RuntimeTargetSelection.profile("sample-profile")
        original.settings.arguments = arguments
        original.settings.launchTarget = target

        let linked = Program(url: linkedProgram, bottle: Bottle(bottleUrl: containerLink))
        XCTAssertEqual(original.id, linked.id)
        XCTAssertEqual(original.settingsURL.resolvingSymlinksInPath(), linked.settingsURL.resolvingSymlinksInPath())
        let linkedRequest = try linked.runtimeRequest()
        XCTAssertEqual(linkedRequest.executableURL, linkedProgram)
        XCTAssertEqual(linkedRequest.arguments, expected)
        XCTAssertEqual(linkedRequest.selection, target)

        linked.settings.arguments = "updated"
        let movedContainer = workspace.appendingPathComponent("container-moved", isDirectory: true)
        try files.moveItem(at: container, to: movedContainer)
        let moved = Program(url: movedContainer.appendingPathComponent("programs/sample.exe"),
                            bottle: Bottle(bottleUrl: movedContainer))
        XCTAssertEqual(original.settingsURL.lastPathComponent, moved.settingsURL.lastPathComponent)
        XCTAssertEqual(try moved.runtimeRequest().arguments, ["updated"])
        XCTAssertEqual(moved.runtimeSelection, target)
    }

    func testAliasNamesDoNotHideKnownProfilesOrScripts() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let profile = try XCTUnwrap(GameCompatibilityDatabase.profiles.first)
        let knownName = try XCTUnwrap(profile.executableNames.sorted().first)
        let target = directory.appending(path: knownName)
        let alias = directory.appending(path: "demo alias.exe")
        try Data().write(to: target)
        try files.createSymbolicLink(at: alias, withDestinationURL: target)
        let coordinator = RuntimeCoordinator(wineAvailable: { true })
        let plan = coordinator.plan(for: alias, selection: .ordinary)
        XCTAssertEqual(plan.profile?.id, profile.id)
        XCTAssertTrue(plan.capability.issues.contains(.conflictingTarget))

        let script = directory.appending(path: "demo script.cmd")
        let scriptAlias = directory.appending(path: "demo script.exe")
        try Data().write(to: script)
        try files.createSymbolicLink(at: scriptAlias, withDestinationURL: script)
        let scriptPlan = coordinator.plan(for: scriptAlias)
        XCTAssertTrue(scriptPlan.capability.issues.contains(.selectTarget))
    }

    func testProcessSessionReturnsExitCodeAndAllowsAnotherAttempt() async throws {
        let failing = Process()
        failing.executableURL = URL(fileURLWithPath: "/bin/sh")
        failing.arguments = ["-c", "exit 23"]
        let failingResult = try await failing.startRuntimeSession().wait()
        XCTAssertEqual(failingResult.status, 23)
        XCTAssertEqual(failingResult.reason, .exit)

        let retry = Process()
        retry.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let retryResult = try await retry.startRuntimeSession().wait()
        XCTAssertEqual(retryResult.status, 0)
        XCTAssertEqual(retryResult.reason, .exit)
    }

    func testProcessSessionCancellationTerminatesSpawnedChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["3"]
        let session = try process.startRuntimeSession()

        await session.cancel()
        let result = try await session.wait()
        XCTAssertEqual(result.reason, .signal)
        XCTAssertFalse(process.isRunning)
    }
}
