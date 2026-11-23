// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import WhiskyKit

actor FakeUTMTransport: UTMGuestTransport {
  private(set) var currentStatus: UTMVMStatus
  private let architecture: String
  private let backend: String
  private let programResult: UTMProcessResult?
  private let probeResult: UTMProcessResult?
  private let crashAfterProgramStarts: Bool
  private let failTerminate: Bool
  private let fileVisible: Bool
  private let cancelDuringStart: Bool
  private let rejectInspection: Bool
  private(set) var observedDeadline: ContinuousClock.Instant?
  private(set) var cleanupWasCancelled = false
  private(set) var cleanupHadFreshDeadline = false
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
    fileVisible: Bool = true, cancelDuringStart: Bool = false, rejectInspection: Bool = false
  ) {
    self.architecture = architecture
    self.backend = backend
    currentStatus = status
    self.programResult = programResult
    self.probeResult = probeResult
    self.crashAfterProgramStarts = crashAfterProgramStarts
    self.failTerminate = failTerminate
    self.fileVisible = fileVisible
    self.cancelDuringStart = cancelDuringStart
    self.rejectInspection = rejectInspection
  }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    observedDeadline = UTMGuestOperationDeadline.value
    if rejectInspection { throw UTMGuestError.automationFailed }
    if crashAfterProgramStarts && programStarted { currentStatus = .stopped }
    return UTMVMSnapshot(
      identifier: identifier, backend: backend, status: currentStatus, architecture: architecture)
  }

  func start(_ identifier: String) async throws {
    startCount += 1
    currentStatus = .started
    if cancelDuringStart { try await Task.sleep(for: .seconds(30)) }
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
    cleanupWasCancelled = Task.isCancelled
    cleanupHadFreshDeadline = (UTMGuestOperationDeadline.value ?? .now) > .now + .seconds(5)
    try Task.checkCancellation()
    currentStatus = .stopped
  }
}
