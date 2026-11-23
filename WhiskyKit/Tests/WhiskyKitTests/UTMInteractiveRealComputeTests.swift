// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

struct RealGuestTestContext {
  let provider: UTMWindowsGuestProvider
  let configuration: RuntimeGuestConfiguration
  let desktopProbe: URL
  let computeProbe: URL
  let evidence: URL

  func request(
    executable: URL, arguments: [String], environment: [String: String] = [:]
  ) -> RuntimeLaunchRequest {
    RuntimeLaunchRequest(
      executableURL: executable, bottle: nil, arguments: arguments,
      environment: environment, backend: .windowsGuest,
      guestConfiguration: configuration)
  }
}

extension UTMInteractiveRealTests {
  func testRealExplicitComputeRoundtripTimeoutCancellationAndErrorsWhenConfigured() async throws {
    let context = try realContext()
    let env = ProcessInfo.processInfo.environment
    let bind = try XCTUnwrap(env["DEMO_REAL_GUEST_BIND_ADDRESS"])
    let guestHost = try XCTUnwrap(env["DEMO_REAL_GUEST_HOST_ADDRESS"])
    var cases: [[String: Any]] = []
    for kind in ["success", "hostError", "overflow", "timeout", "cancel"] {
      let item = try await runRealComputeCase(
        kind: kind, context: context, bind: bind, guestHost: guestHost)
      cases.append(item)
      try writeEvidence(
        context, name: "real-m1.json",
        value: [
          "schemaVersion": 1, "scope": "explicitComputeInterfaceOnly",
          "transparentPEMigration": false, "cases": cases
        ])
    }
  }

  private func runRealComputeCase(
    kind: String, context: RealGuestTestContext, bind: String, guestHost: String
  ) async throws -> [String: Any] {
    let slot = RealGuestCancellationSlot()
    let slow = kind == "timeout" || kind == "cancel"
    let budgetSeconds = kind == "cancel" ? 30 : (kind == "timeout" ? 3 : 10)
    let service = WindowsGuestComputeService(
      bindAddress: bind, requestTimeout: .seconds(budgetSeconds),
      sessionTimeout: .seconds(60), cancelGuest: { await slot.cancel() },
      handler: { request in
        if slow { try await Task.sleep(for: .seconds(30)) }
        return try WindowsGuestComputeService.evaluate(request)
      })
    let endpoint = try await service.start()
    let arguments = computeProbeArguments(
      kind: kind, guestHost: guestHost, endpoint: endpoint, budgetSeconds: budgetSeconds)
    let session: WindowsGuestInteractiveSession
    do {
      session = try await context.provider.startInteractive(
        context.request(executable: context.computeProbe, arguments: arguments))
    } catch {
      await service.cancel()
      throw error
    }
    do {
      await slot.attach(session)
      if kind == "cancel" { try await triggerCancellationAfterAccept(service) }
      let response = try await service.wait()
      let earlyTraceData = try JSONEncoder().encode(await service.snapshot())
      try writeEvidence(
        context, name: "real-m1-host-progress.json",
        value: [
          "schemaVersion": 1, "case": kind,
          "hostTrace": try JSONSerialization.jsonObject(with: earlyTraceData)
        ])
      return try await verifyComputeCaseOutcome(
        kind: kind, service: service, session: session, response: response)
    } catch {
      await cleanupAfterComputeError(kind: kind, context: context, service: service, session: session)
      throw error
    }
  }

  private func computeProbeArguments(
    kind: String, guestHost: String, endpoint: WindowsGuestComputeEndpoint, budgetSeconds: Int
  ) -> [String] {
    var arguments = [
      "--host", guestHost, "--port", String(endpoint.port), "--nonce", endpoint.nonce,
      "--request-id", "101", "--deadline-ms", String(budgetSeconds * 1000)
    ]
    if kind == "hostError" { arguments += ["--operation", "reject"] }
    if kind == "overflow" {
      arguments += ["--scale", "9223372036854775807", "--values", "2147483647"]
    }
    return arguments
  }

  private func triggerCancellationAfterAccept(
    _ service: WindowsGuestComputeService
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await service.snapshot().hasActiveComputation), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    let accepted = await service.snapshot()
    guard accepted.request != nil, accepted.hasActiveComputation, accepted.response == nil else {
      await service.cancel()
      throw WindowsGuestInteractiveError.timedOut
    }
    await service.cancel()
    await service.cancel()
  }

  private func verifyComputeCaseOutcome(
    kind: String, service: WindowsGuestComputeService,
    session: WindowsGuestInteractiveSession, response: WindowsGuestComputeResponse
  ) async throws -> [String: Any] {
    let exit = try await boundedWait(session)
    let trace = await service.snapshot()
    XCTAssertFalse(trace.hasActiveConnection)
    XCTAssertFalse(trace.hasActiveComputation)
    let snapshot = try await session.latestSnapshot()
    XCTAssertEqual(snapshot.state, .exited)
    XCTAssertEqual(snapshot.activeProcessCount, 0)
    let guestReport = try probeReport(snapshot.standardOutput)
    assertComputeReportMatches(
      guestReport, response: response, handle: session.handle)
    assertComputeKindExpectation(
      kind: kind, response: response, exit: exit, guestReport: guestReport)
    let traceData = try JSONEncoder().encode(trace)
    return [
      "case": kind, "status": String(describing: response.status),
      "targetPID": session.handle.targetPID, "exitCode": exit.status,
      "hostCleanupConfirmed": !trace.hasActiveComputation && !trace.hasActiveConnection,
      "guestTerminalConfirmed": snapshot.state == .exited,
      "guestActiveProcessCount": snapshot.activeProcessCount, "transparentPEMigration": false,
      "probe": guestReport, "hostTrace": try JSONSerialization.jsonObject(with: traceData)
    ]
  }

  private func assertComputeReportMatches(
    _ guestReport: [String: Any], response: WindowsGuestComputeResponse,
    handle: WindowsGuestInteractiveProcessHandle
  ) {
    XCTAssertEqual((guestReport["requestID"] as? NSNumber)?.uint64Value, response.requestID)
    XCTAssertEqual((guestReport["targetPID"] as? NSNumber)?.int32Value, handle.targetPID)
    XCTAssertEqual((guestReport["sessionID"] as? NSNumber)?.uint32Value, handle.sessionID)
    XCTAssertEqual(guestReport["status"] as? String, String(describing: response.status))
    XCTAssertEqual(
      (guestReport["errorCode"] as? NSNumber)?.uint32Value, response.errorCode?.rawValue ?? 0)
    XCTAssertEqual((guestReport["checksum"] as? NSNumber)?.uint64Value, response.checksum)
    XCTAssertEqual((guestReport["values"] as? [NSNumber])?.map(\.int64Value), response.values)
  }

  private func assertComputeKindExpectation(
    kind: String, response: WindowsGuestComputeResponse,
    exit: RuntimeExitResult, guestReport: [String: Any]
  ) {
    switch kind {
    case "success":
      XCTAssertEqual(response.status, .succeeded)
      XCTAssertEqual(exit.status, 0)
      XCTAssertEqual(guestReport["dataConsistent"] as? Bool, true)
    case "hostError":
      XCTAssertEqual(response.errorCode, .unsupportedOperation)
      XCTAssertEqual(exit.status, 22)
    case "overflow":
      XCTAssertEqual(response.errorCode, .arithmeticOverflow)
      XCTAssertEqual(exit.status, 22)
    case "timeout":
      XCTAssertEqual(response.status, .timedOut)
      XCTAssertEqual(exit.status, 20)
    default:
      XCTAssertEqual(response.status, .cancelled)
      XCTAssertEqual(exit.status, 21)
    }
  }

  private func cleanupAfterComputeError(
    kind: String, context: RealGuestTestContext,
    service: WindowsGuestComputeService, session: WindowsGuestInteractiveSession
  ) async {
    // A failed assertion payload or transport must not leave a Guest probe or listener alive.
    let cleanup = Task {
      await service.cancel()
      await session.cancel()
      return (await service.snapshot(), try? await session.latestSnapshot())
    }
    let (trace, terminal) = await cleanup.value
    try? writeEvidence(
      context, name: "real-m1-cleanup-after-error.json",
      value: [
        "schemaVersion": 1, "case": kind,
        "hostCleanupConfirmed": !trace.hasActiveConnection && !trace.hasActiveComputation,
        "guestCleanupConfirmed": terminal?.state == .exited
          && terminal?.activeProcessCount == 0
      ])
  }

  func realContext() throws -> RealGuestTestContext {
    let env = ProcessInfo.processInfo.environment
    guard env["DEMO_REAL_GUEST_ENABLED"] == "1" else {
      throw XCTSkip("Real Guest lease and desktop/compute probe configuration is required.")
    }
    let vmID = try XCTUnwrap(env["DEMO_REAL_GUEST_VM_ID"])
    let evidence = URL(
      fileURLWithPath: try XCTUnwrap(env["DEMO_WINDOW_A_EVIDENCE"]), isDirectory: true)
    let native = evidence.appendingPathComponent("m0-native", isDirectory: true)
    let compute = evidence.appendingPathComponent("m1", isDirectory: true)
    let helper = native.appendingPathComponent("desktop-helper.exe")
    let configuration = RuntimeGuestConfiguration(
      identifier: vmID, architecture: "arm64",
      fileMappings: [
        .init(hostDirectory: native, guestDirectory: #"C:\demo-app\window-a\m0"#),
        .init(hostDirectory: compute, guestDirectory: #"C:\demo-app\window-a\m1"#)
      ], startupTimeoutSeconds: 60)
    // Only small self-owned probe files are staged; installation reserve is not claimed.
    let provider = UTMWindowsGuestProvider(
      configuration: configuration,
      transport: makeWindowsGuestTransport(), pollInterval: .milliseconds(250),
      executionMode: .interactiveDesktop, minimumFreeBytes: 0,
      interactiveConfiguration: .init(
        helperURL: helper, guestHelperPath: #"C:\demo-app\window-a\m0\desktop-helper.exe"#))
    return RealGuestTestContext(
      provider: provider, configuration: configuration,
      desktopProbe: native.appendingPathComponent("desktop-probe.exe"),
      computeProbe: compute.appendingPathComponent("compute-probe.exe"), evidence: evidence)
  }

  func boundedWait(
    _ session: WindowsGuestInteractiveSession, timeout: Duration = .seconds(45)
  ) async throws -> RuntimeExitResult {
    try await withThrowingTaskGroup(of: RuntimeExitResult.self) { group in
      group.addTask { try await session.wait() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WindowsGuestInteractiveError.timedOut
      }
      defer { group.cancelAll() }
      let result = try await group.next()
      return try XCTUnwrap(result)
    }
  }

  func probeReport(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func writeEvidence(
    _ context: RealGuestTestContext, name: String, value: [String: Any]
  ) throws {
    var recorded = value
    recorded["capturedAt"] = ISO8601DateFormatter().string(from: Date())
    if let runID = ProcessInfo.processInfo.environment["DEMO_REAL_RUN_ID"] {
      recorded["realRunID"] = runID
    }
    let data = try JSONSerialization.data(
      withJSONObject: recorded, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: context.evidence.appendingPathComponent(name), options: .atomic)
  }
}

actor RealGuestCancellationSlot {
  private var session: WindowsGuestInteractiveSession?
  private var pending = false

  func attach(_ session: WindowsGuestInteractiveSession) async {
    self.session = session
    if pending { await cancelAttached(session) }
  }

  func cancel() async {
    pending = true
    if let session { await cancelAttached(session) }
  }

  private func cancelAttached(_ session: WindowsGuestInteractiveSession) async {
    // Allow the explicit cancellation response to reach the cooperative probe.
    // Enforce target-tree termination after a bounded grace period if it stays alive.
    let deadline = ContinuousClock.now + .seconds(2)
    try? await UTMGuestOperationDeadline.$value.withValue(deadline) {
      while ContinuousClock.now < deadline {
        if try await session.latestSnapshot().state == .exited { return }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    await session.cancel()
  }
}
