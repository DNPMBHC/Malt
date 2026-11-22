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

private actor FakeUTMTransport: UTMGuestTransport {
  private(set) var currentStatus: UTMVMStatus
  private let architecture: String
  private let backend: String
  private let programResult: UTMProcessResult?
  private let probeResult: UTMProcessResult?
  private let crashAfterProgramStarts: Bool
  private let failTerminate: Bool
  private let fileVisible: Bool
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var terminateCount = 0
  private(set) var pushedPath: String?
  private(set) var verifiedPath: String?
  struct ProgramLaunch: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
  }
  private(set) var programLaunch: ProgramLaunch?
  private var programStarted = false
  private var programTerminated = false

  init(
    architecture: String = "x86_64", backend: String = "qemu", status: UTMVMStatus = .started,
    programResult: UTMProcessResult? = .init(exitCode: 0, signal: 0),
    probeResult: UTMProcessResult? = .init(exitCode: 0, signal: 0),
    crashAfterProgramStarts: Bool = false, failTerminate: Bool = false,
    fileVisible: Bool = true
  ) {
    self.architecture = architecture
    self.backend = backend
    currentStatus = status
    self.programResult = programResult
    self.probeResult = probeResult
    self.crashAfterProgramStarts = crashAfterProgramStarts
    self.failTerminate = failTerminate
    self.fileVisible = fileVisible
  }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    if crashAfterProgramStarts && programStarted { currentStatus = .stopped }
    return UTMVMSnapshot(
      identifier: identifier, backend: backend, status: currentStatus, architecture: architecture)
  }
  func start(_ identifier: String) async throws {
    startCount += 1
    currentStatus = .started
  }
  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {
    pushedPath = guestPath
  }
  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    if executable == "cmd.exe" { return 10 }
    if executable.hasSuffix("attrib.exe") {
      verifiedPath = arguments.last
      return 12
    }
    programStarted = true
    programLaunch = .init(executable: executable, arguments: arguments, environment: environment)
    return 11
  }
  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    if pid == 10 { return probeResult }
    if pid == 12 { return .init(exitCode: fileVisible ? 0 : 2, signal: 0) }
    if programTerminated { return .init(exitCode: 1, signal: 9) }
    return programResult
  }
  func terminate(_ identifier: String, pid: Int32) async throws {
    if failTerminate { throw UTMGuestError.automationFailed }
    terminateCount += 1
    programTerminated = true
  }
  func stop(_ identifier: String) async throws {
    stopCount += 1
    currentStatus = .stopped
  }
}
