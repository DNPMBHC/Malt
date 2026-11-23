// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class UTMInteractiveRealTests: XCTestCase, @unchecked Sendable {
  func testRealDesktopGUIArgumentsExitAndCancellationWhenConfigured() async throws {
    let context = try realContext()
    let arguments = [
      "--gui", "--sleep-ms", "1000", "--exit-code", "42", "--echo",
      "", "two words", "literal \"quote\"", "&%!=", #"tail\"#, "示例参数 Ω 🙂"
    ]
    let session = try await context.provider.startInteractive(
      context.request(
        executable: context.desktopProbe, arguments: arguments,
        environment: ["DEMO_E2E_ENV": "synthetic-value &%!="]))
    let result = try await boundedWait(session)
    XCTAssertEqual(result.status, 42)
    let snapshot = try await session.latestSnapshot()
    let report = try probeReport(snapshot.standardOutput)
    XCTAssertEqual((report["processID"] as? NSNumber)?.int32Value, session.handle.targetPID)
    XCTAssertGreaterThan(session.handle.sessionID, 0)
    XCTAssertEqual(report["windowVisible"] as? Bool, true)
    XCTAssertEqual(report["swapChainCreated"] as? Bool, true)
    XCTAssertEqual(report["presentSucceeded"] as? Bool, true)
    XCTAssertEqual(report["arguments"] as? [String], arguments)
    XCTAssertEqual(report["environment"] as? String, "synthetic-value &%!=")
    XCTAssertTrue(
      String(data: snapshot.standardError, encoding: .utf8)?.contains("demo-app stderr marker")
        == true)
    try writeEvidence(
      context, name: "real-m0-gui.json",
      value: [
        "schemaVersion": 1, "scope": "selfOwnedDesktopProbe", "targetPID": session.handle.targetPID,
        "controllerPID": session.handle.controllerPID, "sessionID": session.handle.sessionID,
        "exitCode": result.status, "probe": report, "outputCaptured": true,
        "stderrMarkerMatched": true,
        "controllerIsTarget": session.handle.controllerPID == session.handle.targetPID
      ])

    let cancelled = try await context.provider.startInteractive(
      context.request(
        executable: context.desktopProbe, arguments: ["--sleep-ms", "30000"]))
    let targetPID = cancelled.handle.targetPID
    await cancelled.cancel()
    await cancelled.cancel()
    let cancelledResult = try await boundedWait(cancelled)
    XCTAssertNotEqual(cancelledResult.status, 0)
    let cancelledSnapshot = try await cancelled.latestSnapshot()
    XCTAssertEqual(cancelledSnapshot.state, .exited)
    try writeEvidence(
      context, name: "real-m0-cancel.json",
      value: [
        "schemaVersion": 1, "targetPID": targetPID, "sessionID": cancelled.handle.sessionID,
        "exitCode": cancelledResult.status, "state": "exited", "repeatedCancel": true
      ])
  }

  func testRealParentExitPreservesChildTreeAndCancellationWhenConfigured() async throws {
    let context = try realContext()
    let session = try await context.provider.startInteractive(
      context.request(
        executable: context.desktopProbe, arguments: ["--spawn-child", "30000"]))
    let deadline = ContinuousClock.now + .seconds(5)
    var running = try await session.latestSnapshot()
    while !running.rootExited, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
      running = try await session.latestSnapshot()
    }
    XCTAssertTrue(running.rootExited)
    XCTAssertEqual(running.rootExitCode, 0)
    XCTAssertEqual(running.state, .running)
    XCTAssertGreaterThan(running.activeProcessCount, 0)
    await session.cancel()
    await session.cancel()
    let exit = try await boundedWait(session)
    let terminal = try await session.latestSnapshot()
    XCTAssertEqual(exit.status, 1223)
    XCTAssertEqual(terminal.rootExitCode, 0)
    XCTAssertEqual(terminal.exitCode, 1223)
    XCTAssertTrue(terminal.cancelled)
    XCTAssertEqual(terminal.activeProcessCount, 0)
    let natural = try await context.provider.startInteractive(
      context.request(
        executable: context.desktopProbe, arguments: ["--spawn-child", "2500"]))
    let naturalExit = try await boundedWait(natural)
    let naturalSnapshot = try await natural.latestSnapshot()
    XCTAssertEqual(naturalExit.status, 0)
    XCTAssertFalse(naturalSnapshot.cancelled)
    XCTAssertEqual(naturalSnapshot.activeProcessCount, 0)
    try writeEvidence(
      context, name: "real-m0-process-tree.json",
      value: [
        "schemaVersion": 1, "rootExitCode": 0,
        "childSurvivedRootExit": running.state == .running && running.activeProcessCount > 0,
        "cancelledTreeDrained": terminal.cancelled && terminal.activeProcessCount == 0,
        "naturalTreeDrained": naturalSnapshot.activeProcessCount == 0,
        "realRootPID": session.handle.targetPID, "sessionID": session.handle.sessionID
      ])
  }

  func testRealForceCancellationAuthenticatesRootAndChildTreeWhenConfigured() async throws {
    let context = try realContext()
    let transport = UTMAppleScriptTransport()
    let session = try await context.provider.startInteractive(
      context.request(executable: context.desktopProbe, arguments: ["--spawn-child", "30000"]))
    let handle = session.handle
    do {
      let deadline = ContinuousClock.now + .seconds(10)
      var running = try await session.latestSnapshot()
      while !running.rootExited, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
        running = try await session.latestSnapshot()
      }
      XCTAssertTrue(running.rootExited)
      XCTAssertEqual(running.rootExitCode, 0)
      XCTAssertGreaterThan(running.activeProcessCount, 0)
      for _ in 0..<2 {
        let data = try await transport.collectOutput(
          context.configuration.identifier, executable: handle.helperGuestPath,
          arguments: ["force-cancel", handle.requestID], until: .now + .seconds(10),
          pollInterval: .milliseconds(100), expectedRequestID: handle.requestID)
        let response = try WindowsGuestInteractiveResponse.decode(data, requestID: handle.requestID)
        let terminal = try response.snapshot(matching: handle)
        XCTAssertEqual(terminal.state, .exited)
        XCTAssertEqual(terminal.rootExitCode, 0)
        XCTAssertEqual(terminal.exitCode, 1223)
        XCTAssertTrue(terminal.cancelled)
        XCTAssertEqual(terminal.activeProcessCount, 0)
        XCTAssertTrue(terminal.stdoutTruncated)
        XCTAssertTrue(terminal.stderrTruncated)
      }
      let result = try await boundedWait(session)
      XCTAssertEqual(result.status, 1223)
      try writeEvidence(
        context, name: "real-m0-force-cancel.json",
        value: [
          "schemaVersion": 1, "scope": "authenticatedSelfOwnedTargetTree",
          "rootExitCode": 0, "sessionExitCode": result.status,
          "childSurvivedRootExit": running.activeProcessCount > 0,
          "targetTreeEmpty": true, "repeatedForceCancel": true,
          "forcedOutputTruncationDeclared": true
        ])
    } catch {
      await session.cancel()
      throw error
    }
  }

  func testRealInstallerStyleWindowWhenConfigured() async throws {
    let context = try realContext()
    let session = try await context.provider.startInteractive(
      context.request(
        executable: context.desktopProbe, arguments: ["--installer", "--sleep-ms", "1000"]))
    let result = try await boundedWait(session)
    let snapshot = try await session.latestSnapshot()
    let report = try probeReport(snapshot.standardOutput)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(report["windowVisible"] as? Bool, true)
    try writeEvidence(
      context, name: "real-m0-installer.json",
      value: [
        "schemaVersion": 1, "scope": "selfOwnedInstallerStyleWindow", "probe": report,
        "exitCode": result.status, "uacElevationVerified": false
      ])
  }

  func testRealPrelaunchCancellationSuppressesLateTargetWhenConfigured() async throws {
    let context = try realContext()
    let transport = UTMAppleScriptTransport()
    let helperPath = #"C:\demo-app\window-a\m0\desktop-helper.exe"#
    let deadline = ContinuousClock.now + .seconds(30)
    try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      try await transport.pushCreatingParentDirectory(
        context.configuration.identifier,
        hostURL: context.evidence.appendingPathComponent("m0-native/desktop-helper.exe"),
        guestPath: helperPath, until: deadline, pollInterval: .milliseconds(100))
      try await transport.pushCreatingParentDirectory(
        context.configuration.identifier, hostURL: context.desktopProbe,
        guestPath: #"C:\demo-app\window-a\m0\desktop-probe.exe"#,
        until: deadline, pollInterval: .milliseconds(100))
      let requestID = UUID().uuidString.lowercased()
      let cancellation = try await transport.collectOutput(
        context.configuration.identifier, executable: helperPath,
        arguments: ["cancel", requestID], until: deadline, pollInterval: .milliseconds(100),
        expectedRequestID: requestID)
      let fence = try WindowsGuestInteractiveResponse.decode(cancellation, requestID: requestID)
      XCTAssertEqual(fence.state, .failed)
      XCTAssertEqual(fence.error, "launchCancelled")
      XCTAssertEqual(fence.launchSuppressed, true)
      XCTAssertTrue(fence.cancelled)
      XCTAssertEqual(fence.targetPID, 0)
      let manifest = try WindowsGuestInteractiveManifest.encode(
        executable: #"C:\demo-app\window-a\m0\desktop-probe.exe"#,
        arguments: ["--sleep-ms", "30000"], environment: [:])
      let controllerPID = try await transport.execute(
        context.configuration.identifier, executable: helperPath,
        arguments: ["launch", requestID, manifest], environment: [:])
      XCTAssertGreaterThan(controllerPID, 0)
      // The request fence proves target suppression; QGA completion caches do not prove
      // broker identity or target lifecycle. The final process audit checks residual work.
      let data = try await transport.collectOutput(
        context.configuration.identifier, executable: helperPath,
        arguments: ["status", requestID], until: deadline, pollInterval: .milliseconds(100),
        expectedRequestID: requestID)
      let status = try WindowsGuestInteractiveResponse.decode(data, requestID: requestID)
      XCTAssertEqual(status.state, .failed)
      XCTAssertEqual(status.error, "launchCancelled")
      XCTAssertEqual(status.launchSuppressed, true)
      XCTAssertEqual(status.targetPID, 0)
      try writeEvidence(
        context, name: "real-m0-prelaunch-cancel.json",
        value: [
          "schemaVersion": 1, "scope": "selfOwnedCancelBeforeLaunch",
          "lateLaunchSuppressed": status.launchSuppressed == true,
          "targetPID": status.targetPID, "launchDeliveryAcknowledged": controllerPID > 0
        ])
    }
  }

  func testRealElevationRequirementIsExplicitWhenConfigured() async throws {
    let context = try realContext()
    do {
      let session = try await context.provider.startInteractive(
        context.request(
          executable: context.evidence.appendingPathComponent(
            "m0-native/desktop-elevation-probe.exe"),
          arguments: []))
      let exit = try await boundedWait(session)
      let snapshot = try await session.latestSnapshot()
      let report = try probeReport(snapshot.standardOutput)
      XCTAssertEqual(exit.status, 0)
      XCTAssertEqual(report["elevated"] as? Bool, true)
      XCTAssertGreaterThan(session.handle.sessionID, 0)
      try writeEvidence(
        context, name: "real-m0-elevation-boundary.json",
        value: [
          "schemaVersion": 1, "loggedInTokenAlreadyElevated": true,
          "probe": report, "uacAutomaticApproval": false,
          "scope": "currentLoggedInDesktopTokenOnly"
        ])
    } catch let error as WindowsGuestInteractiveError {
      guard error == .helperFailure(code: "elevationRequired", win32Error: 740) else { throw error }
      try writeEvidence(
        context, name: "real-m0-elevation-boundary.json",
        value: [
          "schemaVersion": 1, "elevationRequired": true, "win32Error": 740,
          "uacElevationVerified": false, "uacAutomaticApproval": false
        ])
    }
  }
}
