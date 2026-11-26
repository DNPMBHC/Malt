// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class LauncherProcessTreeShellTests: XCTestCase {
    private let vmID = "10000000-0000-0000-0000-000000000001"
    private let sessionID = UUID(uuidString: "20000000-0000-0000-0000-000000000002") ?? UUID()
    private let challenge = "30000000-0000-0000-0000-000000000003"
    private let launcherPath = #"C:\Riot Games\Riot Client\RiotClientServices.exe"#
    private let gamePath = #"C:\Riot Games\VALORANT\live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe"#

    private func makeSession(expected: Set<String> = []) -> GuestAppShellSession {
        GuestAppShellSession(
            vmIdentifier: vmID,
            targetExecutable: launcherPath,
            expectedGameProcessNames: expected,
            id: sessionID
        )
    }

    private func makeDerivedPayload(
        sequence: Int = 2,
        event: String = "game_foreground",
        lineage: [[String: Any]]? = nil,
        signalOverrides: [String: Any] = [:]
    ) throws -> Data {
        let defaultLineage: [[String: Any]] = [
            [
                "pid": 1200, "parentPID": 400, "creationTicks": "638960000000000100",
                "createdAt": 1_000.0, "processName": "riotclientservices", "processPath": launcherPath
            ],
            [
                "pid": 1450, "parentPID": 1200, "creationTicks": "638960000050000200",
                "createdAt": 1_005.0, "processName": "valorant",
                "processPath": #"C:\Riot Games\VALORANT\live\VALORANT.exe"#
            ],
            [
                "pid": 1888, "parentPID": 1450, "creationTicks": "638960000120000300",
                "createdAt": 1_012.0, "processName": "valorant-win64-shipping", "processPath": gamePath
            ]
        ]
        var signal: [String: Any] = [
            "schemaVersion": 1, "sessionID": sessionID.uuidString, "vmIdentifier": vmID,
            "targetExecutable": launcherPath, "sequence": sequence, "event": event,
            "observedAt": 1_020.0, "sessionStartedAt": 999.0,
            "rootPID": 1200, "processCreationTicks": "638960000000000100", "processCreatedAt": 1_000.0,
            "processPath": launcherPath, "processName": "riotclientservices",
            "foregroundPID": 1888, "sourceEvent": "game_foreground_detected",
            "sourceAction": "enter_fullscreen_gamemode", "sourcePID": 1888, "sourceObservedAt": 1_019.0,
            "foregroundProcessName": "valorant-win64-shipping", "foregroundProcessPath": gamePath,
            "foregroundCreationTicks": "638960000120000300", "foregroundCreatedAt": 1_012.0,
            "foregroundWindowFullscreen": true, "lineageChain": lineage ?? defaultLineage
        ]
        for (key, value) in signalOverrides { signal[key] = value }
        let envelope: [String: Any] = [
            "schemaVersion": 1, "challenge": challenge, "guestNow": 1_021.0, "signal": signal
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    func testMultiHopLauncherToValorantDescendantEntersGameForeground() throws {
        let session = makeSession()
        let data = try makeDerivedPayload()
        let signal = try XCTUnwrap(
            GuestAppShellSignalValidator.validate(data, session: session, challenge: challenge)
        )
        XCTAssertEqual(signal.event, "game_foreground")
        XCTAssertEqual(signal.rootPID, 1200)
        XCTAssertEqual(signal.foregroundPID, 1888)
        XCTAssertEqual(signal.lineageChain?.count, 3)
    }

    func testFullscreenUnknownGameDescendantTriggersForegroundWhenLineageValid() throws {
        let customExe = #"C:\Games\MyTitle\Binaries\MyCustomGame.exe"#
        let lineage: [[String: Any]] = [
            [
                "pid": 1200, "parentPID": 400, "creationTicks": "638960000000000100",
                "createdAt": 1_000.0, "processName": "riotclientservices", "processPath": launcherPath
            ],
            [
                "pid": 2100, "parentPID": 1200, "creationTicks": "638960000080000500",
                "createdAt": 1_008.0, "processName": "mycustomgame", "processPath": customExe
            ]
        ]
        let data = try makeDerivedPayload(
            lineage: lineage,
            signalOverrides: [
                "foregroundPID": 2100, "sourcePID": 2100,
                "foregroundProcessName": "mycustomgame", "foregroundProcessPath": customExe,
                "foregroundCreationTicks": "638960000080000500", "foregroundCreatedAt": 1_008.0,
                "foregroundWindowFullscreen": true
            ]
        )
        let signal = try XCTUnwrap(
            GuestAppShellSignalValidator.validate(data, session: makeSession(), challenge: challenge)
        )
        XCTAssertEqual(signal.event, "game_foreground")
        XCTAssertEqual(signal.foregroundPID, 2100)
    }

    func testPidReuseAttackWithChildOlderThanParentIsRejected() throws {
        let spoofedLineage: [[String: Any]] = [
            [
                "pid": 1200, "parentPID": 400, "creationTicks": "638960000000000100",
                "createdAt": 1_000.0, "processName": "riotclientservices", "processPath": launcherPath
            ],
            [
                "pid": 1888, "parentPID": 1200, "creationTicks": "638959999000000000",
                "createdAt": 950.0, "processName": "valorant-win64-shipping", "processPath": gamePath
            ]
        ]
        let data = try makeDerivedPayload(
            lineage: spoofedLineage,
            signalOverrides: [
                "foregroundCreationTicks": "638959999000000000",
                "foregroundCreatedAt": 950.0
            ]
        )
        XCTAssertThrowsError(
            try GuestAppShellSignalValidator.validate(data, session: makeSession(), challenge: challenge)
        )
    }

    func testBrokenParentLinkOrUnrelatedProcessIsRejected() throws {
        let brokenLineage: [[String: Any]] = [
            [
                "pid": 1200, "parentPID": 400, "creationTicks": "638960000000000100",
                "createdAt": 1_000.0, "processName": "riotclientservices", "processPath": launcherPath
            ],
            [
                "pid": 1888, "parentPID": 9999, "creationTicks": "638960000120000300",
                "createdAt": 1_012.0, "processName": "valorant-win64-shipping", "processPath": gamePath
            ]
        ]
        let data = try makeDerivedPayload(lineage: brokenLineage)
        XCTAssertThrowsError(
            try GuestAppShellSignalValidator.validate(data, session: makeSession(), challenge: challenge)
        )
    }

    func testExcludedUtilityDescendantEvenFullscreenIsRejected() throws {
        let cmdExe = #"C:\Windows\System32\cmd.exe"#
        let lineage: [[String: Any]] = [
            [
                "pid": 1200, "parentPID": 400, "creationTicks": "638960000000000100",
                "createdAt": 1_000.0, "processName": "riotclientservices", "processPath": launcherPath
            ],
            [
                "pid": 2222, "parentPID": 1200, "creationTicks": "638960000100000400",
                "createdAt": 1_010.0, "processName": "cmd", "processPath": cmdExe
            ]
        ]
        let data = try makeDerivedPayload(
            lineage: lineage,
            signalOverrides: [
                "foregroundPID": 2222, "sourcePID": 2222,
                "foregroundProcessName": "cmd", "foregroundProcessPath": cmdExe,
                "foregroundCreationTicks": "638960000100000400", "foregroundCreatedAt": 1_010.0,
                "foregroundWindowFullscreen": true
            ]
        )
        XCTAssertThrowsError(
            try GuestAppShellSignalValidator.validate(data, session: makeSession(), challenge: challenge)
        )
    }

    func testBridgeTransitionsLauncherToGameFullscreenAndRestoresCompactOnExit() async throws {
        let bridge = AppShellSessionBridge()
        let stateDir = FileManager.default.temporaryDirectory
            .appending(path: "malt-bridge-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateDir) }

        let helperPath = "/Applications/Malt.app/Contents/Helpers/MaltContainerHelper.app/Contents/MacOS/UTM"
        let binding = try await bridge.createBinding(
            vmIdentifier: vmID, helper: helperPath,
            directory: stateDir, title: "VALORANT", windowSize: "1024x680"
        )
        let session = makeSession()
        let generation = try await bridge.begin(session: session, bindingID: binding.id)

        // 1. Launcher compact state stays installer
        let compactData = try makeDerivedPayload(
            sequence: 1, event: "compact",
            signalOverrides: ["foregroundPID": 1200, "foregroundWindowFullscreen": false]
        )
        _ = try await bridge.consume(compactData, session: session, challenge: challenge, generation: generation)
        XCTAssertEqual(try readBridgeState(binding.stateURL), "installer")

        // 2. Derived VALORANT-Win64-Shipping.exe enters foreground -> game_foreground
        let gameData = try makeDerivedPayload(sequence: 2, event: "game_foreground")
        _ = try await bridge.consume(gameData, session: session, challenge: challenge, generation: generation)
        XCTAssertEqual(try readBridgeState(binding.stateURL), "game_foreground")

        // 3. Game exits -> returns to installer compact state
        let exitedData = try makeDerivedPayload(sequence: 3, event: "exited", signalOverrides: ["foregroundPID": 0])
        _ = try await bridge.consume(exitedData, session: session, challenge: challenge, generation: generation)
        XCTAssertEqual(try readBridgeState(binding.stateURL), "installer")
    }

    func testObserverScriptIncludesReadOnlyParentProcessIdAndNoHooks() {
        let script = GuestAppShellScripts.observer(for: makeSession())
        XCTAssertTrue(script.contains("Win32_Process"))
        XCTAssertTrue(script.contains("ParentProcessId"))
        XCTAssertTrue(script.contains("GetWindowRect"))
        XCTAssertTrue(script.contains("lineageChain"))
        XCTAssertFalse(script.lowercased().contains("setwindowshookex"))
        XCTAssertFalse(script.lowercased().contains("createremotethread"))
    }

    private func readBridgeState(_ url: URL) throws -> String {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        return obj["state"] ?? ""
    }
}
