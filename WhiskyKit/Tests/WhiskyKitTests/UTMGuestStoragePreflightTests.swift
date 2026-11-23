// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class UTMGuestStoragePreflightTests: XCTestCase, @unchecked Sendable {
  func testMissingTargetIsCreatableAndMapsToGuestDirectory() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("staging/next", isDirectory: true)
    let config = makeConfiguration(root: root)
    let result = UTMGuestStoragePreflightChecker(minimumFreeBytes: 0).check(
      targetDirectory: target, installerBytes: 0, configuration: config
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertEqual(result.hostTargetState, .creatable)
    XCTAssertEqual(result.storage.state, .ready)
    XCTAssertEqual(result.storage.targetDirectory, target)
    XCTAssertEqual(result.guestTargetDirectory, "C:\\guest folder\\staging\\next")
    XCTAssertTrue(result.canStartGuest)
    XCTAssertFalse(result.canExecuteGuestFile)
  }

  func testInsufficientSpaceIsReportedBeforeGuestStart() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = makeConfiguration(root: root)
    let result = UTMGuestStoragePreflightChecker(minimumFreeBytes: .max).check(
      targetDirectory: root, installerBytes: 0, configuration: config
    )

    XCTAssertEqual(result.storage.state, .insufficientSpace)
    XCTAssertFalse(result.canStartGuest)
  }

  func testTargetOutsideConfiguredMappingIsUnavailable() throws {
    let root = try makeDirectory()
    let outside = try makeDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let result = UTMGuestStoragePreflightChecker(minimumFreeBytes: 0).check(
      targetDirectory: outside, installerBytes: 0, configuration: makeConfiguration(root: root)
    )

    XCTAssertEqual(result.storage.guestMapping, .unavailable)
    XCTAssertEqual(result.storage.state, .mappingUnavailable)
    XCTAssertFalse(result.canStartGuest)
  }

  func testFileVisibilityPromotesConfiguredMappingToVerified() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = UTMGuestStoragePreflightChecker(minimumFreeBytes: 0).check(
      targetDirectory: root, installerBytes: 0, configuration: makeConfiguration(root: root)
    )

    let verified = configured.recordingGuestFileVisibility(.visible)
    XCTAssertEqual(verified.storage.guestMapping, .verified)
    XCTAssertEqual(verified.guestFileVisibility, .visible)
    XCTAssertTrue(verified.canExecuteGuestFile)
  }

  func testExistingFileCannotBeUsedAsWritableDirectoryTarget() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("target-file")
    try Data([0x01]).write(to: file)
    let result = UTMGuestStoragePreflightChecker(minimumFreeBytes: 0).check(
      targetDirectory: file, installerBytes: 0, configuration: makeConfiguration(root: root)
    )

    XCTAssertEqual(result.hostTargetState, .notWritable)
    XCTAssertFalse(result.canStartGuest)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeConfiguration(root: URL) -> RuntimeGuestConfiguration {
    RuntimeGuestConfiguration(
      identifier: "test-vm", architecture: "x86_64",
      fileMappings: [.init(hostDirectory: root, guestDirectory: "C:\\guest folder")]
    )
  }

  func testPushRetriesAfterCreatingMissingGuestParentDirectory() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let app = nested.appendingPathComponent("tool.exe")
    try Data([0x4d, 0x5a]).write(to: app)
    let config = makeConfiguration(root: root)
    let transport = ParentCreatingFakeTransport()
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let request = RuntimeLaunchRequest(
      executableURL: app, bottle: nil, backend: .windowsGuest, guestConfiguration: config)
    let session = try await provider.start(request)
    let exitResult = try await session.wait()

    XCTAssertEqual(exitResult, RuntimeExitResult(status: 0, reason: .exit))
    let createdParent = await transport.createdDirectory
    let pushAttempts = await transport.pushAttempts
    XCTAssertEqual(createdParent, #"C:\guest folder\sub"#)
    XCTAssertEqual(pushAttempts, 2)
  }

  func testUTMProviderConformsToProbeReportingForProbeService() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let probeExe = root.appendingPathComponent("module_a_probe.exe")
    try Data([0x4d, 0x5a]).write(to: probeExe)
    let config = makeConfiguration(root: root)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let transport = ParentCreatingFakeTransport(capturedAt: 1_699_999_980)
    let provider = UTMWindowsGuestProvider(configuration: config, transport: transport)
    let service = WindowsGuestProbeService(provider: provider)

    let assessment = try await service.assess(now: now)
    XCTAssertTrue(assessment.selfProbeVerified)
    XCTAssertFalse(assessment.protectedGameLaunchAuthorized)
    let executedProbe = await transport.probeExecutable
    XCTAssertEqual(executedProbe, #"C:\guest folder\module_a_probe.exe"#)
  }

  func testRealUTMProviderHostAndVMLifecycleWhenConfigured() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let vmID = env["WHISKY_REAL_UTM_VM_ID"],
      let sharedPath = env["WHISKY_REAL_UTM_SHARED_DIR"]
    else {
      throw XCTSkip("Real Guest VM and shared directory configuration is required.")
    }
    let sharedURL = URL(fileURLWithPath: sharedPath, isDirectory: true)
    let exeURL = sharedURL.appendingPathComponent("whisky_a2_test.exe")
    XCTAssertTrue(FileManager.default.isReadableFile(atPath: exeURL.path))

    let mapping = RuntimeGuestConfiguration.FileMapping(
      hostDirectory: sharedURL, guestDirectory: #"C:\whisky-guest-share"#)
    let mismatchConfig = RuntimeGuestConfiguration(
      identifier: vmID, architecture: "x86_64", fileMappings: [mapping], startupTimeoutSeconds: 30)
    let mismatchProvider = UTMWindowsGuestProvider(
      configuration: mismatchConfig, executionMode: .background)
    XCTAssertEqual(mismatchProvider.availability, .ready)
    let preflight = mismatchProvider.preflightStorage(
      targetDirectory: sharedURL, installerURL: exeURL)
    XCTAssertEqual(preflight.hostTargetState, .writable)
    XCTAssertEqual(preflight.storage.state, .ready)
    XCTAssertEqual(preflight.storage.guestMapping, .configured)
    do {
      _ = try await mismatchProvider.start(
        RuntimeLaunchRequest(
          executableURL: exeURL, bottle: nil, backend: .windowsGuest,
          guestConfiguration: mismatchConfig))
      XCTFail("Expected architectureMismatch against real aarch64 UTM VM")
    } catch let error as UTMGuestError {
      XCTAssertEqual(error, .architectureMismatch)
    }

    let armConfig = RuntimeGuestConfiguration(
      identifier: vmID, architecture: "aarch64", fileMappings: [mapping], startupTimeoutSeconds: 60)
    let realProvider = UTMWindowsGuestProvider(configuration: armConfig, executionMode: .background)
    try await verifyRealGuestExecutionAndCancellation(
      provider: realProvider, exeURL: exeURL, config: armConfig)
    let assessment = try await WindowsGuestProbeService(provider: realProvider).assess()
    XCTAssertEqual(assessment.report.schemaVersion, 2)
    XCTAssertEqual(assessment.report.guest.kernelArchitecture, .arm64)
    XCTAssertEqual(assessment.report.guest.windowsBuild, 26100)
    XCTAssertFalse(assessment.protectedGameLaunchAuthorized)
  }

  private func verifyRealGuestExecutionAndCancellation(
    provider: UTMWindowsGuestProvider, exeURL: URL, config: RuntimeGuestConfiguration
  ) async throws {
    let zeroSession = try await provider.start(
      RuntimeLaunchRequest(
        executableURL: exeURL, bottle: nil,
        arguments: ["--exit-code", "0", "--echo", "two words", "literal \"quote\""],
        environment: ["WHISKY_E2E_ENV": "verified_from_host"],
        backend: .windowsGuest, guestConfiguration: config))
    let verified = await provider.latestStoragePreflight()
    XCTAssertEqual(verified?.guestFileVisibility, .visible)
    XCTAssertEqual(verified?.storage.guestMapping, .verified)
    XCTAssertEqual(verified?.canExecuteGuestFile, true)
    let zeroResult = try await zeroSession.wait()
    XCTAssertEqual(zeroResult, RuntimeExitResult(status: 0, reason: .exit))

    let nonZeroSession = try await provider.start(
      RuntimeLaunchRequest(
        executableURL: exeURL, bottle: nil, arguments: ["--exit-code", "42"],
        backend: .windowsGuest, guestConfiguration: config))
    let nonZeroResult = try await nonZeroSession.wait()
    XCTAssertEqual(nonZeroResult, RuntimeExitResult(status: 42, reason: .exit))

    let sleepSession = try await provider.start(
      RuntimeLaunchRequest(
        executableURL: exeURL, bottle: nil, arguments: ["--sleep-ms", "30000"],
        backend: .windowsGuest, guestConfiguration: config))
    await sleepSession.cancel()
    await sleepSession.cancel()
    let cancelResult = try await sleepSession.wait()
    XCTAssertNotEqual(cancelResult.status, 0)
  }
}

private actor ParentCreatingFakeTransport: UTMGuestTransport {
  private let capturedAt: Int64
  private(set) var pushAttempts = 0
  private(set) var createdDirectory: String?
  private(set) var probeExecutable: String?

  init(capturedAt: Int64 = 1_700_000_000) {
    self.capturedAt = capturedAt
  }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    UTMVMSnapshot(identifier: identifier, backend: "qemu", status: .started, architecture: "x86_64")
  }
  func start(_ identifier: String) async throws {}
  func stop(_ identifier: String) async throws {}
  func terminate(_ identifier: String, pid: Int32) async throws {}

  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {
    pushAttempts += 1
    if pushAttempts == 1 && createdDirectory == nil {
      throw UTMGuestError.automationFailed
    }
  }

  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    if executable.hasSuffix("powershell.exe"), let encoded = environment["DEMO_DIRECTORY_BASE64"] {
      if let data = Data(base64Encoded: encoded) {
        createdDirectory = String(data: data, encoding: .utf8)
        return 20
      }
    }
    if executable == "cmd.exe" { return 10 }
    if executable.hasSuffix("attrib.exe") { return 12 }
    return 11
  }

  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    UTMProcessResult(exitCode: 0, signal: 0)
  }

  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    probeExecutable = executable
    let nonce = arguments.dropFirst().first ?? ""
    let payload = """
      {"schemaVersion":2,"nonce":"\(nonce)","capturedAtUnixSeconds":\(capturedAt),\
      "guest":{"kernelArchitecture":"arm64","processArchitecture":"arm64","windowsBuild":26100,\
      "secureBoot":"enabled","codeIntegrity":"enabled","testSigning":"disabled",\
      "kernelDebugger":"disabled","memoryIntegrity":"enabled"},\
      "driver":{"candidateImageArchitecture":"arm64","loadedProbeArchitecture":"arm64",\
      "candidateImageAuthenticode":"trustedAuthenticode","loadState":"loaded","protocolVersion":2},\
      "observation":{"scope":"selfProbe","requestorPID":4200,"observedPID":4200,\
      "dispatchAttachedContextPID":4200,"requestorMatchesCurrentContext":true,\
      "sameProcessObject":true,"deviceControlSucceeded":true,"failureStage":"none",\
      "win32Error":0,"bytesReturned":32,"notification":{"attempted":true,"createObserved":true,\
      "exitObserved":true,"childCleanupComplete":true,"childPIDMatched":true,"boundChildPID":4204}}}
      """
    return Data(payload.utf8)
  }
}
