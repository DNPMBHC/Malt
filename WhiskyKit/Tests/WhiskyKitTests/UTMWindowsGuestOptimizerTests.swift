// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

private actor FakeOptimizerUTMTransport: UTMGuestTransport {
  private(set) var currentStatus: UTMVMStatus
  private let architecture: String
  private(set) var pushedPaths: [String] = []
  private(set) var executedExecutable: String?
  private(set) var executedArguments: [String] = []
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private let outputPayload: Data
  private let failCollectOutput: Bool

  init(
    architecture: String = "aarch64",
    status: UTMVMStatus = .started,
    outputPayload: Data = Data(),
    failCollectOutput: Bool = false
  ) {
    self.architecture = architecture
    self.currentStatus = status
    self.outputPayload = outputPayload
    self.failCollectOutput = failCollectOutput
  }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    UTMVMSnapshot(
      identifier: identifier, backend: "qemu", status: currentStatus, architecture: architecture
    )
  }

  func start(_ identifier: String) async throws {
    startCount += 1
    currentStatus = .started
  }

  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {
    pushedPaths.append(guestPath)
  }

  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    executable == "cmd.exe" ? 10 : 11
  }

  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    UTMProcessResult(exitCode: 0, signal: 0)
  }

  func terminate(_ identifier: String, pid: Int32) async throws {}

  func stop(_ identifier: String) async throws {
    stopCount += 1
    currentStatus = .stopped
  }

  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    executedExecutable = executable
    executedArguments = arguments
    if failCollectOutput { throw UTMGuestError.automationFailed }
    return outputPayload
  }
}

private enum OptimizerTestFixtures {
  static func officialProfileURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(
        "Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
      )
  }

  static func makeGuestConfiguration(directory: URL) -> RuntimeGuestConfiguration {
    RuntimeGuestConfiguration(
      identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      architecture: "arm64",
      fileMappings: [.init(hostDirectory: directory, guestDirectory: #"C:\whisky-guest-share"#)],
      startupTimeoutSeconds: 30
    )
  }

  static func makeReportJSON(
    action: String,
    profileSHA256: String,
    allowlistGuardPassed: Bool = true,
    securityInvariantsPassed: Bool = true,
    rollbackConsistent: Bool? = nil,
    mismatchCount: Int? = nil
  ) throws -> Data {
    var object: [String: Any] = [
      "schema_version": 1,
      "owner": "@DNPMBHC",
      "action": action,
      "captured_at_utc": "2026-11-23T01:00:00Z",
      "profile_id": "anticheat-minimal-win11-arm64",
      "profile_sha256": profileSHA256,
      "script_sha256": String(repeating: "b", count: 64),
      "whitelist_guard_passed": allowlistGuardPassed,
      "security_invariants_passed": securityInvariantsPassed,
      "security_invariants": [
        "secure_boot_enabled": true,
        "tpm_present": true,
        "tpm_enabled": true,
        "bcd_safe": true,
        "prism_files_verified": true,
        "prism_signatures_valid": true,
        "qga_service_running": true
      ],
      "metrics_after": [
        "process_count": 92,
        "running_service_count": 64,
        "system_drive_total_bytes": 68_719_476_736,
        "system_drive_used_bytes": 24_000_000_000,
        "system_drive_free_bytes": 44_719_476_736
      ]
    ]
    if let rollbackConsistent { object["rollback_consistent"] = rollbackConsistent }
    if let mismatchCount { object["mismatch_count"] = mismatchCount }
    return try JSONSerialization.data(withJSONObject: object)
  }
}

final class UTMWindowsGuestOptimizerProfileTests: XCTestCase {
  func testOfficialProfilePassesStrictAllowlistValidation() throws {
    let data = try Data(contentsOf: OptimizerTestFixtures.officialProfileURL())
    let profile = try JSONDecoder().decode(WindowsGuestOptimizerProfile.self, from: data)
    XCTAssertNoThrow(try WindowsGuestOptimizerProfileValidator.validate(profile))
    XCTAssertEqual(profile.profileID, "anticheat-minimal-win11-arm64")
    XCTAssertEqual(profile.owner, "@DNPMBHC")
  }

  func testProtectedServiceInPruningTargetsIsRejectedBeforeGuestExecution() throws {
    let baseData = try Data(contentsOf: OptimizerTestFixtures.officialProfileURL())
    let base = try JSONDecoder().decode(WindowsGuestOptimizerProfile.self, from: baseData)

    for forbidden in ["CryptSvc", "TBS", "QEMU-GA", "vgc", "ACE-BASE"] {
      let mutated = WindowsGuestOptimizerProfile(
        schemaVersion: base.schemaVersion,
        profileID: base.profileID,
        owner: base.owner,
        targetOS: base.targetOS,
        compliance: base.compliance,
        protectedAllowlist: base.protectedAllowlist,
        pruningTargets: .init(
          services: base.pruningTargets.services + [
            .init(name: forbidden, targetStartType: "Disabled", stopRunning: true, reason: "test")
          ],
          scheduledTasks: base.pruningTargets.scheduledTasks,
          uwpPackages: base.pruningTargets.uwpPackages,
          registryTweaks: base.pruningTargets.registryTweaks
        )
      )
      XCTAssertThrowsError(try WindowsGuestOptimizerProfileValidator.validate(mutated)) { error in
        XCTAssertEqual(
          error as? WindowsGuestOptimizerValidationError,
          .protectedServiceInPruningTargets(forbidden)
        )
      }
    }
  }

  func testProtectedUWPAndUnsafeRegistryScopeAreRejected() throws {
    let baseData = try Data(contentsOf: OptimizerTestFixtures.officialProfileURL())
    let base = try JSONDecoder().decode(WindowsGuestOptimizerProfile.self, from: baseData)

    let badUWP = WindowsGuestOptimizerProfile(
      schemaVersion: base.schemaVersion,
      profileID: base.profileID,
      owner: base.owner,
      targetOS: base.targetOS,
      compliance: base.compliance,
      protectedAllowlist: base.protectedAllowlist,
      pruningTargets: .init(
        services: base.pruningTargets.services,
        scheduledTasks: base.pruningTargets.scheduledTasks,
        uwpPackages: base.pruningTargets.uwpPackages + ["Microsoft.VCLibs.140.00"],
        registryTweaks: base.pruningTargets.registryTweaks
      )
    )
    XCTAssertThrowsError(try WindowsGuestOptimizerProfileValidator.validate(badUWP)) { error in
      XCTAssertEqual(
        error as? WindowsGuestOptimizerValidationError,
        .protectedUWPPackageInPruningTargets("Microsoft.VCLibs.140.00")
      )
    }

    let badPath = #"HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"#
    let badRegistry = WindowsGuestOptimizerProfile(
      schemaVersion: base.schemaVersion,
      profileID: base.profileID,
      owner: base.owner,
      targetOS: base.targetOS,
      compliance: base.compliance,
      protectedAllowlist: base.protectedAllowlist,
      pruningTargets: .init(
        services: base.pruningTargets.services,
        scheduledTasks: base.pruningTargets.scheduledTasks,
        uwpPackages: base.pruningTargets.uwpPackages,
        registryTweaks: base.pruningTargets.registryTweaks + [
          .init(path: badPath, name: "VBS", kind: "DWord", reason: "forbidden")
        ]
      )
    )
    XCTAssertThrowsError(try WindowsGuestOptimizerProfileValidator.validate(badRegistry)) { error in
      XCTAssertEqual(
        error as? WindowsGuestOptimizerValidationError,
        .unsafeRegistryScope(badPath)
      )
    }
  }
}

final class UTMWindowsGuestOptimizerServiceTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("utm-optimizer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  private func writeDummyScripts() throws -> (apply: URL, rollback: URL) {
    let apply = temporaryDirectory.appendingPathComponent("apply-optimizer.ps1")
    let rollback = temporaryDirectory.appendingPathComponent("rollback-optimizer.ps1")
    try Data("# apply\n".utf8).write(to: apply)
    try Data("# rollback\n".utf8).write(to: rollback)
    return (apply, rollback)
  }

  func testServiceApplyDryRunPushesArtifactsAndVerifiesDigest() async throws {
    let profileURL = OptimizerTestFixtures.officialProfileURL()
    let digest = WindowsGuestOptimizerProfileValidator.sha256Hex(of: try Data(contentsOf: profileURL))
    let payload = try OptimizerTestFixtures.makeReportJSON(action: "dry_run", profileSHA256: digest)
    let transport = FakeOptimizerUTMTransport(outputPayload: payload)
    let provider = UTMWindowsGuestProvider(
      configuration: OptimizerTestFixtures.makeGuestConfiguration(directory: temporaryDirectory),
      transport: transport,
      installed: true,
      pollInterval: .milliseconds(1),
      executionMode: .background
    )
    let scripts = try writeDummyScripts()
    let service = WindowsGuestOptimizerService(
      provider: provider,
      profileURL: profileURL,
      applyScriptURL: scripts.apply,
      rollbackScriptURL: scripts.rollback
    )

    let report = try await service.apply(dryRun: true)
    XCTAssertEqual(report.action, .dryRun)
    XCTAssertEqual(report.profileSHA256, digest)
    XCTAssertTrue(report.securityInvariants.prismSignaturesValid)

    let pushed = await transport.pushedPaths
    let executable = await transport.executedExecutable
    let args = await transport.executedArguments
    XCTAssertEqual(pushed.count, 2)
    XCTAssertEqual(executable, "powershell.exe")
    XCTAssertTrue(args.contains("-DryRun"))
  }

  func testServiceRollbackRejectsInconsistentReport() async throws {
    let profileURL = OptimizerTestFixtures.officialProfileURL()
    let digest = WindowsGuestOptimizerProfileValidator.sha256Hex(of: try Data(contentsOf: profileURL))
    let badPayload = try OptimizerTestFixtures.makeReportJSON(
      action: "rollback",
      profileSHA256: digest,
      rollbackConsistent: false,
      mismatchCount: 2
    )
    let transport = FakeOptimizerUTMTransport(outputPayload: badPayload)
    let provider = UTMWindowsGuestProvider(
      configuration: OptimizerTestFixtures.makeGuestConfiguration(directory: temporaryDirectory),
      transport: transport,
      installed: true,
      pollInterval: .milliseconds(1),
      executionMode: .background
    )
    let scripts = try writeDummyScripts()
    let service = WindowsGuestOptimizerService(
      provider: provider,
      profileURL: profileURL,
      applyScriptURL: scripts.apply,
      rollbackScriptURL: scripts.rollback
    )

    do {
      _ = try await service.rollback()
      XCTFail("Expected rollbackInconsistent error")
    } catch let error as WindowsGuestOptimizerServiceError {
      XCTAssertEqual(error, .rollbackInconsistent(2))
    }
  }

  func testServiceStopsNewlyLaunchedVMWhenExecutionFails() async throws {
    let profileURL = OptimizerTestFixtures.officialProfileURL()
    let failingTransport = FakeOptimizerUTMTransport(status: .stopped, failCollectOutput: true)
    let coldProvider = UTMWindowsGuestProvider(
      configuration: OptimizerTestFixtures.makeGuestConfiguration(directory: temporaryDirectory),
      transport: failingTransport,
      installed: true,
      pollInterval: .milliseconds(1),
      executionMode: .background
    )
    let scripts = try writeDummyScripts()
    let failingService = WindowsGuestOptimizerService(
      provider: coldProvider,
      profileURL: profileURL,
      applyScriptURL: scripts.apply,
      rollbackScriptURL: scripts.rollback
    )

    do {
      _ = try await failingService.apply()
      XCTFail("Expected automation failure")
    } catch {
      let starts = await failingTransport.startCount
      let stops = await failingTransport.stopCount
      XCTAssertEqual(starts, 1)
      XCTAssertEqual(stops, 1)
    }
  }
}
