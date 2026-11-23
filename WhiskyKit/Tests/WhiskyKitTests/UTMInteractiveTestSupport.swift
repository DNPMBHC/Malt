// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

actor DesktopFakeTransport: UTMGuestTransport {
  private let noDesktop: Bool
  private let gracefulFailure: Bool
  private var forceFailure: Bool
  private let rootExitedEarly: Bool
  private let ambiguousLaunch: Bool
  private let prelaunchFence: Bool
  private let completeOnControllerPoll: Bool
  private var missingCancelRecords: Int
  private(set) var observedDeadline: ContinuousClock.Instant?
  private var launchID: String?
  private(set) var identityRecovered = false
  private var exited = false
  private var statusReadCount = 0
  private var snapshotRace = false
  private var raceReads = 0
  private(set) var firstSnapshotWaiting = false
  private var controllerLost = false
  private(set) var cancelCount = 0
  private(set) var forceCancelCount = 0
  private(set) var polledPIDs: [Int32] = []
  private(set) var terminatedPIDs: [Int32] = []

  init(
    noDesktop: Bool = false, rootExitedEarly: Bool = false, ambiguousLaunch: Bool = false,
    missingCancelRecords: Int = 0, prelaunchFence: Bool = false,
    completeOnControllerPoll: Bool = false, gracefulFailure: Bool = false,
    forceFailure: Bool = false
  ) {
    self.noDesktop = noDesktop
    self.gracefulFailure = gracefulFailure
    self.forceFailure = forceFailure
    self.rootExitedEarly = rootExitedEarly
    self.ambiguousLaunch = ambiguousLaunch
    self.prelaunchFence = prelaunchFence
    self.completeOnControllerPoll = completeOnControllerPoll
    self.missingCancelRecords = missingCancelRecords
  }

  func loseController() { controllerLost = true }
  func allowForceCleanup() { forceFailure = false }
  func armSnapshotRace() { snapshotRace = true }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    observedDeadline = UTMGuestOperationDeadline.value
    return UTMVMSnapshot(
      identifier: identifier, backend: "qemu", status: .started, architecture: "arm64")
  }

  func start(_ identifier: String) async throws {}
  func stop(_ identifier: String) async throws {}
  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {}

  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    if ambiguousLaunch {
      launchID = arguments[1]
      throw CancellationError()
    }
    return 101
  }

  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    polledPIDs.append(pid)
    if completeOnControllerPoll {
      exited = true
      return UTMProcessResult(exitCode: 0, signal: 0)
    }
    return controllerLost ? UTMProcessResult(exitCode: 0, signal: 0) : nil
  }

  func terminate(_ identifier: String, pid: Int32) async throws { terminatedPIDs.append(pid) }

  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    let operation = arguments.first ?? ""
    let requestID = arguments[1]
    if snapshotRace, operation == "status" {
      return try await collectSnapshotRace(requestID: requestID)
    }
    if operation == "force-cancel" { return try collectForceCancel(requestID: requestID) }
    if operation == "cancel" {
      if let early = try collectCancelEarly(requestID: requestID) { return early }
    }
    return try collectStatus(operation: operation, requestID: requestID)
  }

  private func collectSnapshotRace(requestID: String) async throws -> Data {
    raceReads += 1
    if raceReads == 1 {
      let data = Self.response(id: requestID, cancelled: false)
      firstSnapshotWaiting = true
      try await Task.sleep(for: .milliseconds(75))
      return data
    }
    return Self.response(id: requestID, exited: true, exit: 0, cancelled: false)
  }

  private func collectForceCancel(requestID: String) throws -> Data {
    forceCancelCount += 1
    if !forceFailure { exited = true }
    var object = try Self.responseObject(id: requestID, exited: true)
    if forceFailure {
      object["state"] = "failed"
      object["error"] = "cleanupUnconfirmed"
    } else if noDesktop {
      object["state"] = "failed"
      object["error"] = "launchCancelled"
      object["controllerPID"] = 101
      object["targetPID"] = 0
      object["cancelled"] = true
      object["launchSuppressed"] = true
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func collectCancelEarly(requestID: String) throws -> Data? {
    cancelCount += 1
    if gracefulFailure { throw UTMGuestError.automationFailed }
    if missingCancelRecords > 0 {
      missingCancelRecords -= 1
      var object = try Self.responseObject(id: requestID)
      object["state"] = "failed"
      object["error"] = "requestMissing"
      object["controllerPID"] = 0
      object["targetPID"] = 0
      return try JSONSerialization.data(withJSONObject: object)
    }
    if prelaunchFence {
      var object = try Self.responseObject(id: requestID)
      object["state"] = "failed"
      object["error"] = "launchCancelled"
      object["controllerPID"] = 0
      object["targetPID"] = 0
      object["cancelled"] = true
      object["launchSuppressed"] = true
      return try JSONSerialization.data(withJSONObject: object)
    }
    exited = true
    identityRecovered = launchID == requestID
    return nil
  }

  private func collectStatus(operation: String, requestID: String) throws -> Data {
    if completeOnControllerPoll, operation == "status" {
      if statusReadCount > 0 { exited = true }
      statusReadCount += 1
    }
    let data = Self.response(
      id: requestID, exited: exited,
      exit: completeOnControllerPoll ? 0 : 1223, noDesktop: noDesktop,
      cancelled: !completeOnControllerPoll)
    if controllerLost {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      object["state"] = "failed"
      object["error"] = "controllerExited"
      return try JSONSerialization.data(withJSONObject: object)
    }
    if rootExitedEarly {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      object["rootExited"] = true
      object["rootExitCode"] = 0
      if exited { object["exitCode"] = 1223 }
      return try JSONSerialization.data(withJSONObject: object)
    }
    return data
  }

  private static func responseObject(
    id: String, exited: Bool = false
  ) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: response(id: id, exited: exited)) as? [String: Any])
  }

  static func response(
    id: String, session: UInt32 = 2, exited: Bool = false, exit: Int64 = 1223,
    noDesktop: Bool = false, cancelled: Bool = true
  ) -> Data {
    let state = noDesktop ? "failed" : (exited ? "exited" : "running")
    let json = """
      {"schemaVersion":1,"requestID":"\(id)","controllerPID":101,"targetPID":202,"targetCreationTime":"123",\
      "sessionID":\(session),"state":"\(state)","rootExited":\(exited),\
      "rootExitCode":\(exited ? String(exit) : "null"),"activeProcessCount":\(exited ? 0 : 1),\
      "cancelled":\(exited && cancelled),"exitCode":\(exited ? String(exit) : "null"),\
      "stdoutBase64":"\(Data("target-output".utf8).base64EncodedString())",\
      "stderrBase64":"\(Data("target-error".utf8).base64EncodedString())",\
      "stdoutTruncated":false,"stderrTruncated":false,\
      "error":\(noDesktop ? "\"noInteractiveSession\"" : "null"),"win32Error":null}
      """
    return Data(json.utf8)
  }
}
