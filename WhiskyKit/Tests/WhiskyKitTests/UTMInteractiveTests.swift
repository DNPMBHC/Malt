// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class UTMInteractiveTests: XCTestCase, @unchecked Sendable {
  func testManifestPreservesSpecialArgumentsAndRejectsAmbiguousEnvironment() throws {
    let encoded = try WindowsGuestInteractiveManifest.encode(
      executable: #"C:\demo-app\tool.exe"#,
      arguments: ["", "two words", "literal \"quote\"", "&%!=", #"tail\"#, "示例参数 Ω 🙂"],
      environment: ["DEMO_VALUE": "two words\n&%!="])
    let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
    XCTAssertEqual(bytes.prefix(4), Data("MBD1".utf8))
    XCTAssertTrue(bytes.range(of: Data("&%!=".utf8)) != nil)
    XCTAssertThrowsError(
      try WindowsGuestInteractiveManifest.encode(
        executable: "tool.exe", arguments: [], environment: ["Path": "a", "PATH": "b"]))
    XCTAssertThrowsError(
      try WindowsGuestInteractiveManifest.encode(
        executable: "tool.exe", arguments: ["bad\0argument"], environment: [:]))
  }

  func testCapturedResponseRejectsStaleQGAPIDOutput() throws {
    let id = UUID().uuidString.lowercased()
    XCTAssertTrue(
      UTMAppleScriptTransport.capturedResponseMatches(
        DesktopFakeTransport.response(id: id), requestID: id))
    XCTAssertFalse(
      UTMAppleScriptTransport.capturedResponseMatches(
        DesktopFakeTransport.response(id: UUID().uuidString), requestID: id))
    XCTAssertFalse(
      UTMAppleScriptTransport.capturedResponseMatches(
        Data("unrelated completed process".utf8), requestID: id))
  }

  func testManifestHasBoundedSize() {
    XCTAssertThrowsError(
      try WindowsGuestInteractiveManifest.encode(
        executable: "tool.exe", arguments: [String(repeating: "x", count: 16_384)], environment: [:]
      ))
  }

  func testResponseRejectsOtherRequestAndWindowsSessionZero() throws {
    let id = UUID().uuidString.lowercased()
    let data = DesktopFakeTransport.response(id: id, session: 0)
    XCTAssertThrowsError(
      try WindowsGuestInteractiveResponse.decode(data, requestID: UUID().uuidString))
    let response = try WindowsGuestInteractiveResponse.decode(data, requestID: id)
    XCTAssertThrowsError(try response.snapshot())
  }

  func testResponsePreservesUnsignedWindowsExceptionCodeAndOutput() throws {
    let id = UUID().uuidString.lowercased()
    let response = try WindowsGuestInteractiveResponse.decode(
      DesktopFakeTransport.response(id: id, exited: true, exit: 3_221_225_477, cancelled: false),
      requestID: id)
    let snapshot = try response.snapshot()
    XCTAssertEqual(snapshot.exitCode, Int32(bitPattern: 0xC000_0005))
    XCTAssertEqual(String(data: snapshot.standardOutput, encoding: .utf8), "target-output")
    XCTAssertEqual(String(data: snapshot.standardError, encoding: .utf8), "target-error")
  }

  func testRealTargetPIDDrivesStatusAndRepeatedCancellation() async throws {
    let transport = DesktopFakeTransport()
    let handle = try await launchInteractive(transport)
    XCTAssertEqual(handle.controllerPID, 101)
    XCTAssertEqual(handle.targetPID, 202)
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: "test-vm", handle: handle, interval: .milliseconds(1))
    await session.cancel()
    await session.cancel()
    let result = try await session.wait()
    XCTAssertEqual(result.status, 1223)
    let cancelCount = await transport.cancelCount
    XCTAssertEqual(cancelCount, 1)
    let polledPIDs = await transport.polledPIDs
    XCTAssertFalse(polledPIDs.contains(202))
  }

  func testControllerExitCannotMasqueradeAsTargetExit() async throws {
    let transport = DesktopFakeTransport()
    let handle = try await launchInteractive(transport)
    await transport.loseController()
    do {
      _ = try await transport.interactiveSnapshot(
        "test-vm", handle: handle, until: .now + .seconds(1), pollInterval: .milliseconds(1))
      XCTFail("A lost controller cannot complete a still-running target.")
    } catch let error as WindowsGuestInteractiveError {
      XCTAssertEqual(error, .helperFailure(code: "controllerExited", win32Error: nil))
    }
  }

  func testTerminalCommitBetweenSnapshotAndControllerPollIsRecovered() async throws {
    let transport = DesktopFakeTransport(completeOnControllerPoll: true)
    let handle = try await launchInteractive(transport)
    let snapshot = try await transport.interactiveSnapshot(
      "test-vm", handle: handle, until: .now + .seconds(2), pollInterval: .milliseconds(1))
    XCTAssertEqual(snapshot.state, .exited)
    XCTAssertEqual(snapshot.exitCode, 0)
    XCTAssertFalse(snapshot.cancelled)
    let polled = await transport.polledPIDs
    XCTAssertTrue(polled.isEmpty)
  }

  func testCancelledChildTreeDoesNotReportExitedRootAsSuccessfulSession() async throws {
    let transport = DesktopFakeTransport(rootExitedEarly: true)
    let handle = try await launchInteractive(transport)
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: "test-vm", handle: handle, interval: .milliseconds(1))
    let running = try await session.latestSnapshot()
    XCTAssertEqual(running.state, .running)
    XCTAssertTrue(running.rootExited)
    XCTAssertEqual(running.rootExitCode, 0)
    XCTAssertGreaterThan(running.activeProcessCount, 0)
    await session.cancel()
    let result = try await session.wait()
    let terminal = try await session.latestSnapshot()
    XCTAssertEqual(result.status, 1223)
    XCTAssertEqual(terminal.rootExitCode, 0)
    XCTAssertEqual(terminal.exitCode, 1223)
    XCTAssertTrue(terminal.cancelled)
    XCTAssertEqual(terminal.activeProcessCount, 0)
  }

  func testCancelledLaunchBeforePIDReturnUsesRequestIdentityToRecover() async throws {
    let transport = DesktopFakeTransport(ambiguousLaunch: true)
    do {
      _ = try await launchInteractive(transport)
      XCTFail("The original launch cancellation must propagate.")
    } catch is CancellationError {}
    let cancelCount = await transport.cancelCount
    let identityRecovered = await transport.identityRecovered
    XCTAssertEqual(cancelCount, 1)
    XCTAssertTrue(identityRecovered)
  }

  func testAmbiguousLaunchRetriesMissingRecordUntilCancellationIsConfirmed() async throws {
    let transport = DesktopFakeTransport(ambiguousLaunch: true, missingCancelRecords: 2)
    do {
      _ = try await launchInteractive(transport)
      XCTFail("The original launch cancellation must propagate.")
    } catch is CancellationError {}
    let cancelCount = await transport.cancelCount
    XCTAssertEqual(cancelCount, 3)
  }

  func testPersistentPrelaunchCancellationFenceIsRecognized() async throws {
    let transport = DesktopFakeTransport(ambiguousLaunch: true, prelaunchFence: true)
    do {
      _ = try await launchInteractive(transport)
      XCTFail("The original cancellation must propagate.")
    } catch is CancellationError {}
    let cancelCount = await transport.cancelCount
    let terminated = await transport.terminatedPIDs
    XCTAssertEqual(cancelCount, 1)
    XCTAssertTrue(terminated.isEmpty)
  }

  func testCancelFallbackUsesAuthenticatedRequestAndPreservesRootExit() async throws {
    let transport = DesktopFakeTransport(rootExitedEarly: true, gracefulFailure: true)
    let handle = try await launchInteractive(transport)
    try await transport.cancelInteractive(
      "test-vm", handle: handle, until: .now + .seconds(2), pollInterval: .milliseconds(1))
    let forced = await transport.forceCancelCount
    let terminated = await transport.terminatedPIDs
    XCTAssertEqual(forced, 1)
    XCTAssertTrue(terminated.isEmpty)
  }

  func testUnconfirmedForceCleanupCannotReportSuccess() async throws {
    let transport = DesktopFakeTransport(gracefulFailure: true, forceFailure: true)
    let handle = try await launchInteractive(transport)
    do {
      try await transport.cancelInteractive(
        "test-vm", handle: handle, until: .now + .seconds(2), pollInterval: .milliseconds(1))
      XCTFail("An unconfirmed process tree must not be reported as reclaimed.")
    } catch let error as WindowsGuestInteractiveError {
      XCTAssertEqual(error, .cancellationFailed)
    }
    let terminated = await transport.terminatedPIDs
    XCTAssertTrue(terminated.isEmpty)
  }

  func testFailedCancellationCanRetryAfterTransportRecovery() async throws {
    let transport = DesktopFakeTransport(gracefulFailure: true, forceFailure: true)
    let handle = try await launchInteractive(transport)
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: "test-vm", handle: handle, interval: .milliseconds(1))
    await session.cancel()
    await transport.allowForceCleanup()
    await session.cancel()
    let result = try await session.wait()
    XCTAssertEqual(result.status, 1223)
    let forced = await transport.forceCancelCount
    XCTAssertEqual(forced, 2)
  }

  func testConcurrentCancellationSharesConfirmedCleanup() async throws {
    let transport = DesktopFakeTransport()
    let handle = try await launchInteractive(transport)
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: "test-vm", handle: handle, interval: .milliseconds(1))
    async let first: Void = session.cancel()
    async let second: Void = session.cancel()
    _ = await (first, second)
    let result = try await session.wait()
    XCTAssertEqual(result.status, 1223)
    let count = await transport.cancelCount
    XCTAssertEqual(count, 1)
  }

  func testDelayedRunningSnapshotCannotOverwriteConcurrentTerminalState() async throws {
    let transport = DesktopFakeTransport()
    let handle = try await launchInteractive(transport)
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: "test-vm", handle: handle, interval: .milliseconds(1))
    await transport.armSnapshotRace()
    async let delayed = session.latestSnapshot()
    while !(await transport.firstSnapshotWaiting) {
      try await Task.sleep(for: .milliseconds(1))
    }
    let terminal = try await session.latestSnapshot()
    let earlier = try await delayed
    XCTAssertEqual(terminal.state, .exited)
    XCTAssertEqual(earlier.state, .exited)
    let cached = try await session.latestSnapshot()
    XCTAssertEqual(cached.state, .exited)
    XCTAssertEqual(cached.exitCode, 0)
  }

  func testSnapshotHonorsEarlierParentDeadline() async throws {
    let transport = DesktopFakeTransport()
    let handle = try await launchInteractive(transport)
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: "test-vm", handle: handle, interval: .milliseconds(1))
    let deadline = ContinuousClock.now + .seconds(1)
    _ = try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      try await session.latestSnapshot()
    }
    let observed = await transport.observedDeadline
    XCTAssertEqual(observed, deadline)
  }

  func testNoDesktopIsExplicitFailureAndReclaimsRequest() async throws {
    let transport = DesktopFakeTransport(noDesktop: true)
    do {
      _ = try await launchInteractive(transport, timeout: .seconds(1))
      XCTFail("An interactive desktop is required.")
    } catch let error as WindowsGuestInteractiveError {
      XCTAssertEqual(error, .desktopUnavailable)
    }
    let terminated = await transport.terminatedPIDs
    XCTAssertTrue(terminated.isEmpty)
    let forced = await transport.forceCancelCount
    XCTAssertEqual(forced, 1)
  }

  private func launchInteractive(
    _ transport: DesktopFakeTransport, timeout: Duration = .seconds(2)
  ) async throws -> WindowsGuestInteractiveProcessHandle {
    let request = WindowsGuestInteractiveLaunchRequest(
      helperGuestPath: #"C:\demo-app\desktop-helper.exe"#,
      executable: #"C:\demo-app\tool.exe"#, arguments: [], environment: [:])
    let timing = WindowsGuestInteractiveTiming(
      deadline: .now + timeout, pollInterval: .milliseconds(1))
    return try await transport.executeInteractive("test-vm", request: request, timing: timing)
  }
}
