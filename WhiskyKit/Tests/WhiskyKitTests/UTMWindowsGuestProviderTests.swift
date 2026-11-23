// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class UTMWindowsGuestProviderTests: XCTestCase, @unchecked Sendable {
  func testUnconfiguredAndUnavailableStatesAreExplicit() {
    let noConfig = UTMWindowsGuestProvider(configuration: nil, transport: FakeUTMTransport())
    XCTAssertEqual(noConfig.availability, .unconfigured)

    let config = makeConfiguration(directory: FileManager.default.temporaryDirectory)
    let missingUTM = UTMWindowsGuestProvider(
      configuration: config, transport: FakeUTMTransport(), installed: false)
    if case .unavailable = missingUTM.availability {
    } else {
      XCTFail("Expected unavailable UTM state")
    }
  }

  func testConfigurationRejectsInvalidTimeoutAndGuestPathTraversal() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let invalidTimeout = RuntimeGuestConfiguration(
      identifier: "test-vm", architecture: "x86_64",
      fileMappings: [.init(hostDirectory: directory, guestDirectory: "C:\\guest")],
      startupTimeoutSeconds: .infinity)
    let invalidPath = RuntimeGuestConfiguration(
      identifier: "test-vm", architecture: "x86_64",
      fileMappings: [.init(hostDirectory: directory, guestDirectory: "C:\\..\\outside")])
    let providerA = UTMWindowsGuestProvider(
      configuration: invalidTimeout, transport: FakeUTMTransport())
    let providerB = UTMWindowsGuestProvider(
      configuration: invalidPath, transport: FakeUTMTransport())
    XCTAssertFalse(providerA.availability.isReady)
    XCTAssertFalse(providerB.availability.isReady)
  }

  func testArchitectureMismatchIsReportedBeforeVMStart() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory, architecture: "x86_64")
    let transport = FakeUTMTransport(architecture: "aarch64", status: .stopped)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)

    do {
      _ = try await provider.start(makeRequest(directory: directory, config: config))
      XCTFail("Expected architecture mismatch")
    } catch let error as UTMGuestError {
      XCTAssertEqual(error, .architectureMismatch)
    }
    let starts = await transport.startCount
    XCTAssertEqual(starts, 0)
  }

  func testUnsupportedVMBackendIsReportedBeforeArchitectureValidation() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(architecture: "unknown", backend: "apple")
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)

    do {
      _ = try await provider.start(makeRequest(directory: directory, config: config))
      XCTFail("Expected unsupported VM backend")
    } catch let error as UTMGuestError {
      XCTAssertEqual(error, .unsupportedBackend)
    }
  }

  func testMappedProgramPreservesArgumentAndEnvironmentBoundariesAndFullExitCode() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(
      status: .stopped, programResult: .init(exitCode: 301, signal: 0))
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let arguments = ["--title", "two words", "literal \"quote\"", "", "$(not a shell expression)"]
    let environment = ["TEST_VALUE": "spaces and 'quotes'", "EMPTY": ""]
    let session = try await provider.start(
      makeRequest(
        directory: directory, config: config,
        arguments: arguments, environment: environment))
    let result = try await session.wait()

    XCTAssertEqual(result, RuntimeExitResult(status: 301, reason: .exit))
    let launch = await transport.programLaunch
    let startCount = await transport.startCount
    XCTAssertEqual(launch?.executable, "C:\\guest folder\\sample app.exe")
    XCTAssertEqual(launch?.arguments, arguments)
    XCTAssertEqual(launch?.environment, environment)
    XCTAssertEqual(startCount, 1)
    let pushedPath = await transport.pushedPath
    XCTAssertEqual(pushedPath, "C:\\guest folder\\sample app.exe")
    let verifiedPath = await transport.verifiedPath
    XCTAssertEqual(verifiedPath, "C:\\guest folder\\sample app.exe")
    let storage = await provider.latestStoragePreflight()
    XCTAssertEqual(storage?.guestFileVisibility, .visible)
    XCTAssertEqual(storage?.storage.guestMapping, .verified)
    XCTAssertTrue(storage?.canExecuteGuestFile == true)
  }

  func testCancellationIsIdempotentAndWaitReportsGuestTermination() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(programResult: nil)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let session = try await provider.start(makeRequest(directory: directory, config: config))

    await session.cancel()
    await session.cancel()
    let result = try await session.wait()
    XCTAssertEqual(result.reason, .signal)
    XCTAssertEqual(result.status, 9)
    let terminateCount = await transport.terminateCount
    XCTAssertEqual(terminateCount, 1)
  }

  func testCancellationFailureIsReturnedByWait() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(programResult: nil, failTerminate: true)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let session = try await provider.start(makeRequest(directory: directory, config: config))

    await session.cancel()
    do {
      _ = try await session.wait()
      XCTFail("Expected cancellation failure")
    } catch let error as UTMGuestError {
      XCTAssertEqual(error, .cancelFailed)
    }
  }

  func testVMCrashIsReportedWhileWaitingForProgram() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(programResult: nil, crashAfterProgramStarts: true)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let session = try await provider.start(makeRequest(directory: directory, config: config))

    do {
      _ = try await session.wait()
      XCTFail("Expected VM crash")
    } catch let error as UTMGuestError {
      XCTAssertEqual(error, .vmStopped)
    }
  }

  func testGuestAgentReadinessTimeoutIsReported() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = RuntimeGuestConfiguration(
      identifier: "test-vm", architecture: "x86_64",
      fileMappings: [.init(hostDirectory: directory, guestDirectory: "C:\\guest folder")],
      startupTimeoutSeconds: 1)
    let transport = FakeUTMTransport(probeResult: nil)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)

    do {
      _ = try await provider.start(makeRequest(directory: directory, config: config))
      XCTFail("Expected guest-agent readiness timeout")
    } catch RuntimeLaunchError.issue(let issue) {
      XCTAssertEqual(issue, .guestTimeout)
    }
    let launch = await transport.programLaunch
    XCTAssertNil(launch)
  }

  func testPushedFileMustBeVisibleBeforeProgramExecution() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(status: .stopped, fileVisible: false)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)

    do {
      _ = try await provider.start(makeRequest(directory: directory, config: config))
      XCTFail("Expected guest file visibility failure")
    } catch let error as UTMGuestError {
      XCTAssertEqual(error, .guestFileNotVisible)
    }
    let launch = await transport.programLaunch
    let stopCount = await transport.stopCount
    let storage = await provider.latestStoragePreflight()
    XCTAssertNil(launch)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(storage?.guestFileVisibility, .notVisible)
    XCTAssertEqual(storage?.storage.guestMapping, .unavailable)
  }
}

extension UTMWindowsGuestProviderTests {
  func testCancelledVMStartRollsBackInIndependentScope() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(status: .stopped, cancelDuringStart: true)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let task = Task {
      try await UTMGuestOperationDeadline.$value.withValue(.now + .seconds(1)) {
        try await provider.start(makeRequest(directory: directory, config: config))
      }
    }
    while await transport.startCount == 0 { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Launch cancellation must propagate after cleanup.")
    } catch is CancellationError {}
    let status = await transport.currentStatus
    let stopCount = await transport.stopCount
    let cleanupCancelled = await transport.cleanupWasCancelled
    let remaining = await transport.cleanupHadFreshDeadline
    XCTAssertEqual(status, .stopped)
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(cleanupCancelled)
    XCTAssertTrue(remaining)
  }

  func testBothLaunchModesHonorEarlierParentDeadline() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data([0x4d, 0x5a]).write(to: directory.appendingPathComponent("desktop-helper.exe"))
    let config = makeConfiguration(directory: directory)
    for mode in [WindowsGuestExecutionMode.background, .interactiveDesktop] {
      let transport = FakeUTMTransport(rejectInspection: true)
      let provider = UTMWindowsGuestProvider(
        configuration: config, transport: transport, executionMode: mode)
      let deadline = ContinuousClock.now + .seconds(1)
      do {
        _ = try await UTMGuestOperationDeadline.$value.withValue(deadline) {
          try await provider.start(makeRequest(directory: directory, config: config))
        }
        XCTFail("The isolated transport rejects inspection.")
      } catch let error as UTMGuestError {
        XCTAssertEqual(error, .automationFailed)
      }
      let observed = await transport.observedDeadline
      XCTAssertEqual(observed, deadline)
    }
  }

  func testStopRequestsVMShutdownAndWaitsForStoppedStatus() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(status: .started)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    try await provider.stop()
    let status = await transport.currentStatus
    XCTAssertEqual(status, .stopped)
  }

  func testStopIsIdempotentWhenGuestAlreadyStopped() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(status: .stopped)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)

    try await provider.stop()
    let stopCount = await transport.stopCount
    XCTAssertEqual(stopCount, 0)
  }

  func testStopUsesGuestConfigurationFromLaunchRequest() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = makeConfiguration(directory: directory)
    let transport = FakeUTMTransport(status: .stopped)
    let provider = UTMWindowsGuestProvider(configuration: nil, transport: transport)
    _ = try await provider.start(makeRequest(directory: directory, config: config))

    try await provider.stop()
    let status = await transport.currentStatus
    XCTAssertEqual(status, .stopped)
  }

  func testRequestConfigurationCanStopGuestAfterReadinessFailure() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = RuntimeGuestConfiguration(
      identifier: "test-vm", architecture: "x86_64",
      fileMappings: [.init(hostDirectory: directory, guestDirectory: "C:\\guest folder")],
      startupTimeoutSeconds: 1)
    let transport = FakeUTMTransport(status: .started, probeResult: nil)
    let provider = UTMWindowsGuestProvider(configuration: nil, transport: transport)

    do {
      _ = try await provider.start(makeRequest(directory: directory, config: config))
      XCTFail("Expected guest-agent readiness timeout")
    } catch RuntimeLaunchError.issue(let issue) {
      XCTAssertEqual(issue, .guestTimeout)
    }
    try await provider.stop()
    let status = await transport.currentStatus
    XCTAssertEqual(status, .stopped)
  }

  func testWindowsStatusCodeParserPreservesHighBitExceptionCode() throws {
    let code = try UTMGuestResultParser.windowsStatusCode("3221225477")
    XCTAssertEqual(code, Int32(bitPattern: 0xC000_0005))
  }

  func testFileOutsideMappingAndUnsupportedLauncherAreRejected() async throws {
    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: otherDirectory) }
    let outside = otherDirectory.appendingPathComponent("other.exe")
    try Data([0]).write(to: outside)
    let bat = directory.appendingPathComponent("run.cmd")
    try Data([0]).write(to: bat)
    let config = makeConfiguration(directory: directory)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: FakeUTMTransport())

    for file in [outside, bat] {
      do {
        _ = try await provider.start(
          RuntimeLaunchRequest(
            executableURL: file, bottle: nil,
            guestConfiguration: config))
        XCTFail("Expected launch rejection")
      } catch let error as UTMGuestError {
        if file == outside {
          XCTAssertEqual(error, .fileMappingUnavailable)
        } else {
          XCTAssertEqual(error, .unsupportedExecutable)
        }
      }
    }
  }

  private func makeFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([0x4d, 0x5a]).write(to: directory.appendingPathComponent("sample app.exe"))
    return directory
  }

  private func makeConfiguration(
    directory: URL, architecture: String = "x86_64"
  ) -> RuntimeGuestConfiguration {
    RuntimeGuestConfiguration(
      identifier: "test-vm", architecture: architecture,
      fileMappings: [.init(hostDirectory: directory, guestDirectory: "C:\\guest folder")],
      startupTimeoutSeconds: 2)
  }

  private func makeRequest(
    directory: URL, config: RuntimeGuestConfiguration,
    arguments: [String] = [], environment: [String: String] = [:]
  ) -> RuntimeLaunchRequest {
    RuntimeLaunchRequest(
      executableURL: directory.appendingPathComponent("sample app.exe"), bottle: nil,
      arguments: arguments, environment: environment, backend: .windowsGuest,
      guestConfiguration: config)
  }
}
