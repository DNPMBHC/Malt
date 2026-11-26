// SPDX-License-Identifier: GPL-3.0-or-later
// Shared session fixtures and lifecycle regression tests form one focused suite.
// swiftlint:disable file_length

import Foundation
import XCTest

@testable import WhiskyKit

final class GuestSurfaceSessionTests: XCTestCase {
  private var temporaryDirectories: [URL] = []

  override func tearDown() {
    for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
    super.tearDown()
  }
  private func makeConfigAndRequest() -> (RuntimeGuestConfiguration, RuntimeLaunchRequest) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "guest-shell-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try? Data().write(to: tmp.appendingPathComponent("desktop-helper.exe"))
    temporaryDirectories.append(tmp)
    let guestConfig = RuntimeGuestConfiguration(
      identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      architecture: "arm64",
      fileMappings: [.init(hostDirectory: tmp, guestDirectory: #"C:\guest-share"#)],
      startupTimeoutSeconds: 30
    )
    let request = RuntimeLaunchRequest(
      executableURL: tmp.appendingPathComponent("game.exe"),
      bottle: nil,
      arguments: [],
      environment: [:],
      backend: .windowsGuest,
      guestConfiguration: guestConfig
    )
    return (guestConfig, request)
  }

  func testHeadlessSessionAppliesDisplayStreamsFramesRestoresAndSuspendsOnExit() async throws {
    let (guestConfig, request) = makeConfigAndRequest()
    let provider = MockGuestProviderForShell(configuration: guestConfig)
    let displaySync = MockDisplaySync()
    let frameSource = SyntheticIOSurfaceFrameSource(width: 1920, height: 1200)
    let hooks = MockPresentationHooks()
    let hostDisplay = HostDisplayDescriptor(
      logicalWidth: 1440, logicalHeight: 900, backingScaleFactor: 2.0, maxRefreshRateHz: 120
    )
    let sessionConfig = GuestSurfaceSessionConfiguration(
      resolutionPreset: .highPerformance,
      hostDisplay: hostDisplay,
      idlePolicy: .suspendOnExit
    )
    let session = GuestSurfaceSession(
      provider: provider,
      displaySync: displaySync,
      configuration: sessionConfig,
      frameSource: frameSource,
      presentationHooks: hooks
    )

    let result = try await session.run(request)
    XCTAssertEqual(result.exitResult.status, 0)
    XCTAssertEqual(result.targetDisplayMode.width, 1920)
    XCTAssertEqual(result.targetDisplayMode.height, 1200)
    XCTAssertTrue(result.displayRestored)
    XCTAssertTrue(result.guestSuspendedOnExit)

    let restored = await displaySync.restoredSnapshots
    let stops = await provider.stopCount
    let ends = await hooks.endedCount
    XCTAssertEqual(restored.count, 1)
    XCTAssertEqual(stops, 1)
    XCTAssertEqual(ends, 1)
  }

  func testHeadlessSessionRestoresDisplayWhenGuestLaunchFails() async throws {
    let (guestConfig, request) = makeConfigAndRequest()
    let provider = MockGuestProviderForShell(configuration: guestConfig, failStart: true)
    let displaySync = MockDisplaySync()
    let hooks = MockPresentationHooks()
    let hostDisplay = HostDisplayDescriptor(
      logicalWidth: 1440, logicalHeight: 900, backingScaleFactor: 2.0, maxRefreshRateHz: 60
    )
    let session = GuestSurfaceSession(
      provider: provider,
      displaySync: displaySync,
      configuration: GuestSurfaceSessionConfiguration(
        resolutionPreset: .highPerformance, hostDisplay: hostDisplay, idlePolicy: .keepWarm
      ),
      presentationHooks: hooks
    )

    do {
      _ = try await session.run(request)
      XCTFail("Expected launch error")
    } catch {
      let restored = await displaySync.restoredSnapshots
      let stops = await provider.stopCount
      let ends = await hooks.endedCount
      XCTAssertEqual(restored.count, 1)
      XCTAssertEqual(stops, 0)
      XCTAssertEqual(ends, 1)
    }
  }

  func testUTMProviderDisplaySyncParsesValidResponseAndRejectsFailureStatus() async throws {
    let (guestConfig, _) = makeConfigAndRequest()
    let okJSON = Data(
      #"""
      {"ok":true,"device_name":"\\\\.\\DISPLAY1","previous_width":1280,"previous_height":720,
       "previous_refresh_hz":60,"current_width":1920,"current_height":1200,
       "current_refresh_hz":120,"status_code":0,"session_id":1,"dpi_percent":100}
      """#.utf8
    )
    let transport = FakeDisplaySyncUTMTransport(responsePayload: okJSON)
    let provider = UTMWindowsGuestProvider(
      configuration: guestConfig, transport: transport, installed: true,
      pollInterval: .milliseconds(1)
    )
    let target = GuestDisplayMode(width: 1920, height: 1200, refreshRateHz: 120)
    let snapshot = try await provider.applyGuestDisplayMode(target, configuration: guestConfig)
    XCTAssertEqual(snapshot.previousMode.width, 1280)
    XCTAssertEqual(snapshot.appliedMode.width, 1920)
    XCTAssertEqual(snapshot.appliedMode.height, 1200)

    let failJSON = Data(
      #"""
      {"ok":false,"device_name":"\\\\.\\DISPLAY1","previous_width":1280,"previous_height":720,
       "previous_refresh_hz":60,"current_width":1280,"current_height":720,
       "current_refresh_hz":60,"status_code":-2,"session_id":1,"dpi_percent":100}
      """#.utf8
    )
    let failingProvider = UTMWindowsGuestProvider(
      configuration: guestConfig,
      transport: FakeDisplaySyncUTMTransport(responsePayload: failJSON),
      installed: true,
      pollInterval: .milliseconds(1)
    )
    do {
      _ = try await failingProvider.applyGuestDisplayMode(target, configuration: guestConfig)
      XCTFail("Expected changeDisplaySettingsFailed")
    } catch let error as GuestDisplaySyncError {
      XCTAssertEqual(error, .changeDisplaySettingsFailed(-2))
    }
  }
  func testPartiallyAppliedDisplayFailureStillRestoresOriginalBaseline() async throws {
    let (config, request) = makeConfigAndRequest()
    let display = MockDisplaySync(failApply: true)
    let provider = MockGuestProviderForShell(configuration: config)
    let session = GuestSurfaceSession(
      provider: provider, displaySync: display,
      configuration: GuestSurfaceSessionConfiguration(
        hostDisplay: HostDisplayDescriptor(
          logicalWidth: 1440, logicalHeight: 900, backingScaleFactor: 2, maxRefreshRateHz: 60)))
    do {
      _ = try await session.run(request)
      XCTFail("Expected display failure")
    } catch {}
    let restores = await display.restoredSnapshots
    let starts = await provider.startCount
    XCTAssertEqual(restores.count, 1)
    XCTAssertEqual(restores.first?.previousMode.width, 1280)
    XCTAssertEqual(starts, 0)
  }

  func testRestoreFailureIsVisibleAndDoesNotSuspendGuest() async throws {
    let (config, request) = makeConfigAndRequest()
    let display = MockDisplaySync(failRestore: true)
    let provider = MockGuestProviderForShell(configuration: config)
    let session = GuestSurfaceSession(
      provider: provider, displaySync: display,
      configuration: GuestSurfaceSessionConfiguration(
        hostDisplay: HostDisplayDescriptor(
          logicalWidth: 1440, logicalHeight: 900, backingScaleFactor: 2, maxRefreshRateHz: 60),
        idlePolicy: .suspendOnExit))
    let result = try await session.run(request)
    XCTAssertFalse(result.displayRestored)
    XCTAssertFalse(result.guestSuspendedOnExit)
    let stops = await provider.stopCount
    let state = await session.state
    let failure = await session.lastCleanupFailure
    XCTAssertEqual(stops, 0)
    XCTAssertEqual(state, .failed)
    XCTAssertEqual(failure, "display_restore_failed")
  }

  func testCancellationDuringDisplayPreparationClosesPresentationAndPreventsLaunch() async throws {
    let (config, request) = makeConfigAndRequest()
    let display = MockDisplaySync(delayApply: true)
    let provider = MockGuestProviderForShell(configuration: config)
    let hooks = MockPresentationHooks()
    let session = GuestSurfaceSession(
      provider: provider, displaySync: display,
      configuration: GuestSurfaceSessionConfiguration(
        hostDisplay: HostDisplayDescriptor(
          logicalWidth: 1440, logicalHeight: 900, backingScaleFactor: 2, maxRefreshRateHz: 60)),
      presentationHooks: hooks)
    let run = Task { try await session.run(request) }
    for _ in 0..<100 {
      if await display.appliedModes.count > 0 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    await session.cancel()
    do {
      _ = try await run.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    let starts = await provider.startCount
    let restores = await display.restoredSnapshots
    let ends = await hooks.endedCount
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(restores.count, 1)
    XCTAssertEqual(ends, 1)
  }

  func testSuspendFailureReportsFailureAfterDisplayAndCursorCleanup() async throws {
    let (config, request) = makeConfigAndRequest()
    let provider = MockGuestProviderForShell(configuration: config, failSuspend: true)
    let hooks = MockPresentationHooks()
    let session = GuestSurfaceSession(
      provider: provider, displaySync: MockDisplaySync(),
      configuration: GuestSurfaceSessionConfiguration(
        hostDisplay: HostDisplayDescriptor(
          logicalWidth: 1280, logicalHeight: 800, backingScaleFactor: 2, maxRefreshRateHz: 60),
        idlePolicy: .suspendOnExit), presentationHooks: hooks)
    let result = try await session.run(request)
    XCTAssertTrue(result.displayRestored)
    XCTAssertTrue(result.cursorReleaseVerified)
    XCTAssertFalse(result.guestSuspendedOnExit)
    let state = await session.state
    let failure = await session.lastCleanupFailure
    XCTAssertEqual(state, .failed)
    XCTAssertEqual(failure, "guest_suspend_failed")
  }

}

extension GuestSurfaceSessionTests {
  func testLiveWindowResizeRestoresOriginalBaselineAfterExit() async throws {
    let (config, request) = makeConfigAndRequest()
    let gate = GuestSurfaceExitGate()
    let display = MockDisplaySync()
    let session = makeFollowingSession(config, gate: gate, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let size = CGSize(width: 1600, height: 900)
    let updated = try await session.synchronizeWindowPixelSize(size)
    XCTAssertEqual(updated?.width, 1600)
    XCTAssertEqual(updated?.height, 900)
    await gate.complete()
    let result = try await run.value
    XCTAssertTrue(result.displayRestored)
    let restores = await display.restoredSnapshots
    XCTAssertEqual(restores.count, 1)
    XCTAssertEqual(restores[0].previousMode.width, 1280)
    XCTAssertEqual(restores[0].previousMode.height, 720)
    let afterExit = try await session.synchronizeWindowPixelSize(CGSize(width: 1920, height: 1080))
    XCTAssertNil(afterExit)
  }

  func testExitDuringLiveResizeCancelsUpdateBeforeRestoringOriginalBaseline() async throws {
    let (config, request) = makeConfigAndRequest()
    let gate = GuestSurfaceExitGate()
    let display = MockDisplaySync(delayApply: true)
    let session = makeFollowingSession(config, gate: gate, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let resize = Task { try await session.synchronizeWindowPixelSize(CGSize(width: 1600, height: 900)) }
    for _ in 0..<200 {
      if await display.appliedModes.count == 2 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let applied = await display.appliedModes
    XCTAssertEqual(applied.count, 2)
    await gate.complete()
    let result = try await run.value
    do {
      _ = try await resize.value
      XCTFail("Expected resize cancellation")
    } catch is CancellationError {}
    XCTAssertTrue(result.displayRestored)
    let restores = await display.restoredSnapshots
    XCTAssertEqual(restores.count, 1)
    XCTAssertEqual(restores[0].previousMode.width, 1280)
    XCTAssertEqual(restores[0].previousMode.height, 720)
  }

  func testConcurrentLiveResizesApplyTheLatestPendingSizeWithoutOverlappingOperations() async throws {
    let (config, request) = makeConfigAndRequest()
    let exit = GuestSurfaceExitGate()
    let display = ControlledResizeDisplaySync()
    let session = makeFollowingSession(config, gate: exit, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let firstUpdate = try await session.enqueueWindowPixelSize(CGSize(width: 1600, height: 900))
    let first = try XCTUnwrap(firstUpdate)
    await display.waitForBlockedResize()
    let middleUpdate = try await session.enqueueWindowPixelSize(CGSize(width: 1760, height: 990))
    let middle = try XCTUnwrap(middleUpdate)
    let latestUpdate = try await session.enqueueWindowPixelSize(CGSize(width: 1920, height: 1080))
    let latest = try XCTUnwrap(latestUpdate)
    await display.releaseBlockedResize()
    let firstResult = try await first.value
    let middleResult = try await middle.value
    let latestResult = try await latest.value
    XCTAssertEqual(firstResult?.width, 1920)
    XCTAssertEqual(middleResult, latestResult)
    XCTAssertEqual(latestResult?.height, 1080)
    let modes = await display.appliedModes
    let maximumConcurrentApplies = await display.maximumConcurrentApplies
    XCTAssertEqual(modes.map(\.width), [2560, 1600, 1920])
    XCTAssertEqual(maximumConcurrentApplies, 1)
    await exit.complete()
    let result = try await run.value
    XCTAssertTrue(result.displayRestored)
    let restoredMode = await display.currentMode
    XCTAssertEqual(restoredMode, GuestDisplayMode(width: 1280, height: 720, refreshRateHz: 60))
  }

  func testRepeatedPendingSizeDoesNotReapplyTheSameDisplayMode() async throws {
    let (config, request) = makeConfigAndRequest()
    let exit = GuestSurfaceExitGate()
    let display = ControlledResizeDisplaySync()
    let session = makeFollowingSession(config, gate: exit, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let first = try await session.enqueueWindowPixelSize(CGSize(width: 1600, height: 900))
    await display.waitForBlockedResize()
    let duplicate = try await session.enqueueWindowPixelSize(CGSize(width: 1600, height: 900))
    await display.releaseBlockedResize()
    _ = try await first?.value
    _ = try await duplicate?.value
    let modes = await display.appliedModes
    XCTAssertEqual(modes.map(\.width), [2560, 1600])
    await exit.complete()
    _ = try await run.value
  }

  func testCancellingObsoleteResizeWaiterDoesNotDiscardLatestPendingSize() async throws {
    let (config, request) = makeConfigAndRequest()
    let exit = GuestSurfaceExitGate()
    let display = ControlledResizeDisplaySync()
    let session = makeFollowingSession(config, gate: exit, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let obsolete = Task {
      try await session.synchronizeWindowPixelSize(CGSize(width: 1600, height: 900))
    }
    await display.waitForBlockedResize()
    let latestUpdate = try await session.enqueueWindowPixelSize(CGSize(width: 1920, height: 1080))
    let latest = try XCTUnwrap(latestUpdate)
    obsolete.cancel()
    await display.releaseBlockedResize()
    do {
      _ = try await obsolete.value
      XCTFail("Expected obsolete waiter cancellation")
    } catch is CancellationError {}
    let applied = try await latest.value
    XCTAssertEqual(applied?.width, 1920)
    let modes = await display.appliedModes
    XCTAssertEqual(modes.map(\.width), [2560, 1600, 1920])
    await exit.complete()
    _ = try await run.value
  }

  func testSupersededResizeFailureStillAppliesLatestPendingSize() async throws {
    let (config, request) = makeConfigAndRequest()
    let exit = GuestSurfaceExitGate()
    let display = ControlledResizeDisplaySync(failFirstResize: true)
    let session = makeFollowingSession(config, gate: exit, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let first = try await session.enqueueWindowPixelSize(CGSize(width: 1600, height: 900))
    await display.waitForBlockedResize()
    let latestUpdate = try await session.enqueueWindowPixelSize(CGSize(width: 1920, height: 1080))
    let latest = try XCTUnwrap(latestUpdate)
    await display.releaseBlockedResize()
    _ = try await first?.value
    let applied = try await latest.value
    XCTAssertEqual(applied?.width, 1920)
    await exit.complete()
    let result = try await run.value
    XCTAssertTrue(result.displayRestored)
  }

  func testExitDiscardsPendingResizeAndWaitsForInflightApplyBeforeRestoringBaseline() async throws {
    let (config, request) = makeConfigAndRequest()
    let exit = GuestSurfaceExitGate()
    let display = ControlledResizeDisplaySync()
    let session = makeFollowingSession(config, gate: exit, display: display)
    let run = Task { try await session.run(request) }
    try await waitUntilRunning(session)
    let first = try await session.enqueueWindowPixelSize(CGSize(width: 1600, height: 900))
    await display.waitForBlockedResize()
    let latest = try await session.enqueueWindowPixelSize(CGSize(width: 1920, height: 1080))
    await exit.complete()
    for _ in 0..<200 {
      if await session.state == .tearingDown { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let beforeRelease = await display.restoredSnapshots
    XCTAssertTrue(beforeRelease.isEmpty)
    await display.releaseBlockedResize()
    let result = try await run.value
    do {
      _ = try await first?.value
      XCTFail("Expected inflight resize cancellation")
    } catch is CancellationError {}
    do {
      _ = try await latest?.value
      XCTFail("Expected pending resize cancellation")
    } catch is CancellationError {}
    let modes = await display.appliedModes
    let restores = await display.restoredSnapshots
    let current = await display.currentMode
    XCTAssertEqual(modes.map(\.width), [2560, 1600])
    XCTAssertEqual(restores.count, 1)
    XCTAssertEqual(current, GuestDisplayMode(width: 1280, height: 720, refreshRateHz: 60))
    XCTAssertTrue(result.displayRestored)
  }

  private func makeFollowingSession(
    _ config: RuntimeGuestConfiguration, gate: GuestSurfaceExitGate, display: any GuestDisplaySynchronizing
  ) -> GuestSurfaceSession {
    GuestSurfaceSession(
      provider: MockGuestProviderForShell(configuration: config, exitGate: gate), displaySync: display,
      configuration: GuestSurfaceSessionConfiguration(
        resolutionPreset: .followWindow,
        hostDisplay: HostDisplayDescriptor(
          logicalWidth: 1280, logicalHeight: 800, backingScaleFactor: 2, maxRefreshRateHz: 60)))
  }

  private func waitUntilRunning(_ session: GuestSurfaceSession) async throws {
    for _ in 0..<200 {
      if await session.state == .running { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    await session.cancel()
    XCTFail("Session did not reach running state")
  }

}

actor FakeDisplaySyncUTMTransport: UTMGuestTransport {
  private(set) var executedExecutables: [String] = []
  private let responsePayload: Data
  private var requestID = ""

  init(responsePayload: Data) {
    self.responsePayload = responsePayload
  }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    UTMVMSnapshot(
      identifier: identifier, backend: "qemu", status: .started, architecture: "aarch64")
  }
  func start(_ identifier: String) async throws {}
  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {}
  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    if arguments.first == "launch", arguments.count == 3 { requestID = arguments[1] }
    return 10
  }
  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    UTMProcessResult(exitCode: 0, signal: 0)
  }
  func terminate(_ identifier: String, pid: Int32) async throws {}
  func stop(_ identifier: String) async throws {}
  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    executedExecutables.append(executable)
    let response: [String: Any] = [
      "schemaVersion": 1, "requestID": requestID, "controllerPID": 10, "targetPID": 11,
      "targetCreationTime": "100", "sessionID": 1, "state": "exited", "rootExited": true,
      "rootExitCode": 0, "activeProcessCount": 0, "cancelled": false, "exitCode": 0,
      "stdoutBase64": responsePayload.base64EncodedString(), "stderrBase64": "",
      "stdoutTruncated": false, "stderrTruncated": false
    ]
    return try JSONSerialization.data(withJSONObject: response)
  }
}

private actor ControlledResizeDisplaySync: GuestDisplaySynchronizing {
  private(set) var appliedModes: [GuestDisplayMode] = []
  private(set) var restoredSnapshots: [GuestDisplaySyncSnapshot] = []
  private(set) var currentMode = GuestDisplayMode(width: 1280, height: 720, refreshRateHz: 60)
  private(set) var maximumConcurrentApplies = 0
  private var concurrentApplies = 0
  private var blockedResize: CheckedContinuation<Void, Never>?
  private var resizeStarted: CheckedContinuation<Void, Never>?
  private let failFirstResize: Bool

  init(failFirstResize: Bool = false) {
    self.failFirstResize = failFirstResize
  }

  func queryGuestDisplayMode(configuration: RuntimeGuestConfiguration) async throws -> GuestDisplayMode {
    currentMode
  }

  func applyGuestDisplayMode(
    _ targetMode: GuestDisplayMode, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    concurrentApplies += 1
    maximumConcurrentApplies = max(maximumConcurrentApplies, concurrentApplies)
    defer { concurrentApplies -= 1 }
    let previous = currentMode
    appliedModes.append(targetMode)
    let isFirstResize = appliedModes.count == 2
    if isFirstResize {
      await withCheckedContinuation { continuation in
        blockedResize = continuation
        resizeStarted?.resume()
        resizeStarted = nil
      }
    }
    // Deliberately finish even after cancellation: teardown must await an uncooperative driver.
    currentMode = targetMode
    if isFirstResize, failFirstResize {
      throw GuestDisplaySyncError.changeDisplaySettingsFailed(-2)
    }
    return GuestDisplaySyncSnapshot(previousMode: previous, appliedMode: targetMode)
  }

  func restoreGuestDisplayMode(
    _ snapshot: GuestDisplaySyncSnapshot, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplayMode {
    restoredSnapshots.append(snapshot)
    currentMode = snapshot.previousMode
    return currentMode
  }

  func waitForBlockedResize() async {
    if blockedResize != nil { return }
    await withCheckedContinuation { resizeStarted = $0 }
  }

  func releaseBlockedResize() {
    blockedResize?.resume()
    blockedResize = nil
  }
}
// swiftlint:enable file_length
