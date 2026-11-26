// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class GuestAppShellSessionTests: XCTestCase {
  private let fixture = ShellSignalFixture()

  func testValidForegroundBindsTheSelectedProcess() throws {
    let signal = try XCTUnwrap(fixture.validate())
    XCTAssertEqual(signal.event, "game_foreground")
    XCTAssertEqual(signal.identity?.pid, 731)
    XCTAssertEqual(signal.identity?.creationTicks, "638960000000000000")
    XCTAssertEqual(signal.identity?.path, fixture.session.targetExecutable)
  }

  func testWaitingWithoutProcessIdentityRemainsNonForeground() throws {
    let signal = try XCTUnwrap(fixture.validate(signalChanges: [
      "event": "waiting", "rootPID": 0, "foregroundPID": 0, "sourcePID": 0,
      "processCreationTicks": "", "processCreatedAt": 0, "processPath": "", "processName": ""
    ]))
    XCTAssertEqual(signal.event, "waiting")
    XCTAssertNil(signal.identity)
  }

  func testCompactPreservesOnlyTheKnownProcessIdentity() throws {
    let signal = try XCTUnwrap(fixture.validate(signalChanges: ["event": "compact", "foregroundPID": 0]))
    XCTAssertEqual(signal.event, "compact")
    XCTAssertEqual(signal.identity?.pid, 731)
  }

  func testAbsentSignalDoesNotBecomeForeground() throws {
    let data = try fixture.data(envelopeChanges: ["signal": NSNull()])
    XCTAssertNil(try GuestAppShellSignalValidator.validate(
      data, session: fixture.session, challenge: fixture.challenge))
  }

  func testStartedReceiptIsNotAForegroundEvent() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["event": "started"]))
  }

  func testUnknownEventIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["event": "window_visible"]))
  }

  func testOrdinaryLauncherCannotBecomeGameForeground() throws {
    let launcher = ShellSignalFixture(target: #"C:\Launchers\launcher.exe"#)
    XCTAssertThrowsError(try launcher.validate())
  }

  func testDifferentForegroundPIDIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["foregroundPID": 732]))
  }

  func testDifferentSourcePIDIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sourcePID": 732]))
  }

  func testSamePIDWithChangedCreationTicksIsRejected() throws {
    let previous = try XCTUnwrap(fixture.validate())
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "sequence": 2, "processCreationTicks": "638960000000000001"
    ], previous: previous))
  }

  func testChangedRootPIDIsRejectedEvenWhenOtherPIDsAgree() throws {
    let previous = try XCTUnwrap(fixture.validate())
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "sequence": 2, "rootPID": 732, "foregroundPID": 732, "sourcePID": 732
    ], previous: previous))
  }

  func testDifferentProcessPathIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "processPath": #"C:\Other\d3d11_probe.exe"#
    ]))
  }

  func testDifferentProcessNameIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["processName": "launcher"]))
  }

  func testDifferentVMIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "vmIdentifier": "10000000-0000-0000-0000-000000000099"
    ]))
  }

  func testDifferentSessionIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "sessionID": "20000000-0000-0000-0000-000000000099"
    ]))
  }

  func testDifferentChallengeIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(envelopeChanges: [
      "challenge": "30000000-0000-0000-0000-000000000099"
    ]))
  }

  func testInvalidChallengeCannotAuthenticateAResponse() throws {
    let data = try fixture.data(envelopeChanges: ["challenge": "not-a-uuid"])
    XCTAssertThrowsError(try GuestAppShellSignalValidator.validate(
      data, session: fixture.session, challenge: "not-a-uuid"))
  }

  func testDifferentTargetIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "targetExecutable": #"C:\Other\d3d11_probe.exe"#
    ]))
  }

  func testUnknownSourceEventIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sourceEvent": "started"]))
  }

  func testUnknownSourceActionIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sourceAction": "show_window"]))
  }

  func testExpiredObservationIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["observedAt": fixture.now - 4]))
  }

  func testFutureObservationIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["observedAt": fixture.now + 2]))
  }

  func testObservationBeforeSessionStartIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["observedAt": fixture.now - 21]))
  }

  func testSourceBeforeSessionStartIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sourceObservedAt": fixture.now - 21]))
  }

  func testSourceAfterTheObservationIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sourceObservedAt": fixture.now + 1]))
  }

  func testFirstExpiredSourceIsRejectedDespiteFreshObservation() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sourceObservedAt": fixture.now - 11]))
  }

  func testPreviouslyVerifiedSourceSurvivesANewObservationHeartbeat() throws {
    let previous = try XCTUnwrap(fixture.validate())
    let signal = try XCTUnwrap(fixture.validate(signalChanges: [
      "sequence": 2, "observedAt": fixture.now + 19
    ], envelopeChanges: ["guestNow": fixture.now + 20], previous: previous,
      verifiedSourceTime: fixture.sourceTime))
    XCTAssertEqual(signal.sequence, 2)
    XCTAssertEqual(signal.sourceObservedAt, fixture.sourceTime)
  }

  func testVerifiedSourceCannotBeReplacedByAnotherTimestamp() throws {
    let previous = try XCTUnwrap(fixture.validate())
    XCTAssertThrowsError(try fixture.validate(signalChanges: [
      "sequence": 2, "sourceObservedAt": fixture.sourceTime + 0.5
    ], previous: previous, verifiedSourceTime: fixture.sourceTime))
  }

  func testSequenceCannotMoveBackwards() throws {
    let previous = try XCTUnwrap(fixture.validate(signalChanges: ["sequence": 2]))
    XCTAssertThrowsError(try fixture.validate(previous: previous))
  }

  func testSameSequenceCannotCarryDifferentContent() throws {
    let previous = try XCTUnwrap(fixture.validate())
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["event": "compact"], previous: previous))
  }

  func testExactSameSequenceAndContentCanBeReadAgain() throws {
    let previous = try XCTUnwrap(fixture.validate())
    XCTAssertEqual(try fixture.validate(previous: previous), previous)
  }

  func testZeroSequenceIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["sequence": 0]))
  }

  func testInvalidCreationTicksAreRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["processCreationTicks": "not-ticks"]))
  }

  func testProcessCreatedBeforeSessionIsRejected() throws {
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["processCreatedAt": fixture.now - 23]))
  }

  func testDuplicateEnvelopeJSONKeyIsRejected() throws {
    let json = """
      {"schemaVersion":1,"schemaVersion":1,"challenge":"\(fixture.challenge)","guestNow":1800000100,"signal":null}
      """
    XCTAssertThrowsError(try GuestAppShellSignalValidator.validate(
      Data(json.utf8), session: fixture.session, challenge: fixture.challenge))
  }

  func testDuplicateNestedJSONKeyIsRejected() throws {
    let original = try XCTUnwrap(String(data: fixture.data(), encoding: .utf8))
    let duplicated = original.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1,\"sequence\":1")
    XCTAssertNotEqual(duplicated, original)
    XCTAssertThrowsError(try GuestAppShellSignalValidator.validate(
      Data(duplicated.utf8), session: fixture.session, challenge: fixture.challenge))
  }

  func testOversizePayloadIsRejected() throws {
    XCTAssertThrowsError(try GuestAppShellSignalValidator.validate(
      Data(repeating: 32, count: 16_385), session: fixture.session, challenge: fixture.challenge))
  }

  func testUnknownEnvelopeAndSignalSchemasAreRejected() throws {
    XCTAssertThrowsError(try fixture.validate(envelopeChanges: ["schemaVersion": 2]))
    XCTAssertThrowsError(try fixture.validate(signalChanges: ["schemaVersion": 2]))
  }

  func testWindowsPathCaseAndSeparatorsAreNormalized() throws {
    let signal = try fixture.validate(signalChanges: [
      "targetExecutable": "c:/GAMES/example/D3D11_PROBE.EXE",
      "processPath": "c:/GAMES/example/D3D11_PROBE.EXE", "processName": "D3D11_PROBE"
    ])
    XCTAssertEqual(signal?.event, "game_foreground")
  }

  func testExitAndFailureRemainTerminalWithoutForegroundProof() throws {
    for event in ["exited", "failed"] {
      let signal = try XCTUnwrap(fixture.validate(signalChanges: [
        "event": event, "foregroundPID": 0, "sourceEvent": "", "sourceAction": ""
      ]))
      XCTAssertTrue(signal.isTerminal)
    }
  }
}

struct ShellSignalFixture {
  let now = 1_800_000_100.0
  let session: GuestAppShellSession
  let challenge = "30000000-0000-0000-0000-000000000001"
  var sourceTime: Double { now - 2 }

  init(target: String = #"C:\Games\Example\d3d11_probe.exe"#) {
    session = GuestAppShellSession(
      vmIdentifier: "10000000-0000-0000-0000-000000000001", targetExecutable: target,
      id: UUID(uuid: (0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
      createdAt: Date(timeIntervalSince1970: 1_800_000_080))
  }

  func data(
    signalChanges: [String: Any] = [:], envelopeChanges: [String: Any] = [:]
  ) throws -> Data {
    var signal: [String: Any] = [
      "schemaVersion": 1, "sessionID": session.id.uuidString, "vmIdentifier": session.vmIdentifier,
      "targetExecutable": session.targetExecutable, "sequence": 1, "event": "game_foreground",
      "observedAt": now - 1, "sessionStartedAt": now - 20, "rootPID": 731,
      "processCreationTicks": "638960000000000000", "processCreatedAt": now - 19,
      "processPath": session.targetExecutable,
      "processName": GuestAppShellSession.processName(for: session.targetExecutable),
      "foregroundPID": 731, "sourceEvent": "game_foreground_detected",
      "sourceAction": "enter_fullscreen_gamemode", "sourcePID": 731, "sourceObservedAt": sourceTime
    ]
    signal.merge(signalChanges) { _, new in new }
    var envelope: [String: Any] = [
      "schemaVersion": 1, "challenge": challenge, "guestNow": now, "signal": signal
    ]
    envelope.merge(envelopeChanges) { _, new in new }
    return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
  }

  func validate(
    signalChanges: [String: Any] = [:], envelopeChanges: [String: Any] = [:],
    previous: GuestAppShellSignal? = nil, verifiedSourceTime: Double? = nil
  ) throws -> GuestAppShellSignal? {
    try GuestAppShellSignalValidator.validate(
      data(signalChanges: signalChanges, envelopeChanges: envelopeChanges),
      session: session, challenge: challenge, previous: previous, verifiedSourceTime: verifiedSourceTime)
  }
}
