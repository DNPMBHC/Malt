// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct UTMHostProcessResult: Sendable {
  let processIdentifier: Int32
  let standardOutput: Data
  let standardError: Data
  let terminationStatus: Int32
  let terminationReason: Process.TerminationReason
}

enum UTMHostProcessError: Error, Sendable, Equatable {
  case timedOut
  case outputLimitExceeded
  case launchFailed
}

/// Runs one owned host process. Completion follows process reaping, including cancellation.
/// Output pipes are nonblocking and each stream has a fixed memory limit.
enum UTMHostProcessRunner {
  static func run(
    executable: URL, arguments: [String], until deadline: ContinuousClock.Instant,
    maximumOutputBytes: Int = 1024 * 1024
  ) async throws -> UTMHostProcessResult {
    try Task.checkCancellation()
    guard deadline > ContinuousClock.now else { throw UTMHostProcessError.timedOut }
    guard maximumOutputBytes > 0 else { throw UTMHostProcessError.outputLimitExceeded }
    let operation = UTMHostProcessOperation(
      executable: executable, arguments: arguments, deadline: deadline,
      maximumOutputBytes: maximumOutputBytes)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.start(continuation)
      }
    } onCancel: {
      operation.cancel()
    }
  }
}

private final class UTMHostProcessOperation: @unchecked Sendable {
  private let queue = DispatchQueue(label: "demo-app.host-process")
  private let executable: URL
  private let arguments: [String]
  private let deadline: ContinuousClock.Instant
  private let maximumOutputBytes: Int
  private let process = Process()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private var stdoutSource: DispatchSourceRead?
  private var stderrSource: DispatchSourceRead?
  private var timer: DispatchSourceTimer?
  private var continuation: CheckedContinuation<UTMHostProcessResult, any Error>?
  private var standardOutput = Data()
  private var standardError = Data()
  private var failure: (any Error)?
  private var cancellationRequested = false
  private var launched = false
  private var completed = false
  private var finishing = false

  init(
    executable: URL, arguments: [String], deadline: ContinuousClock.Instant,
    maximumOutputBytes: Int
  ) {
    self.executable = executable
    self.arguments = arguments
    self.deadline = deadline
    self.maximumOutputBytes = maximumOutputBytes
  }

  func start(_ continuation: CheckedContinuation<UTMHostProcessResult, any Error>) {
    queue.async {
      self.continuation = continuation
      if self.cancellationRequested {
        self.finishWithoutLaunching(CancellationError())
        return
      }
      guard self.deadline > ContinuousClock.now else {
        self.finishWithoutLaunching(UTMHostProcessError.timedOut)
        return
      }
      self.launch()
    }
  }

  func cancel() {
    queue.async {
      self.cancellationRequested = true
      self.stop(with: CancellationError())
    }
  }

  private func launch() {
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { [weak self] _ in
      guard let self else { return }
      self.queue.async { self.processExited() }
    }
    do {
      try prepareNonblocking(stdoutPipe.fileHandleForReading.fileDescriptor)
      try prepareNonblocking(stderrPipe.fileHandleForReading.fileDescriptor)
      try process.run()
      launched = true
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      stdoutSource = makeSource(for: stdoutPipe, isStandardError: false)
      stderrSource = makeSource(for: stderrPipe, isStandardError: true)
      scheduleDeadline()
      if cancellationRequested { stop(with: CancellationError()) }
    } catch {
      finishWithoutLaunching(UTMHostProcessError.launchFailed)
    }
  }

  private func prepareNonblocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw UTMHostProcessError.launchFailed
    }
  }

  private func makeSource(for pipe: Pipe, isStandardError: Bool) -> DispatchSourceRead {
    let source = DispatchSource.makeReadSource(
      fileDescriptor: pipe.fileHandleForReading.fileDescriptor, queue: queue)
    source.setEventHandler { [weak self] in
      self?.drain(pipe, isStandardError: isStandardError)
    }
    source.setCancelHandler { try? pipe.fileHandleForReading.close() }
    source.resume()
    return source
  }

  private func scheduleDeadline() {
    let components = ContinuousClock.now.duration(to: deadline).components
    let remaining = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + remaining)
    timer.setEventHandler { [weak self] in
      self?.stop(with: UTMHostProcessError.timedOut)
    }
    self.timer = timer
    timer.resume()
  }

  private func drain(_ pipe: Pipe, isStandardError: Bool) {
    guard !completed else { return }
    var bytes = [UInt8](repeating: 0, count: 8192)
    // Yield to deadline/cancellation events even when a child continuously floods its pipe.
    for _ in 0..<64 {
      let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
      if count == 0 { return }
      if count < 0 {
        if errno == EINTR { continue }
        return
      }
      let currentCount = isStandardError ? standardError.count : standardOutput.count
      let accepted = min(count, max(0, maximumOutputBytes - currentCount))
      if isStandardError {
        standardError.append(contentsOf: bytes.prefix(accepted))
      } else {
        standardOutput.append(contentsOf: bytes.prefix(accepted))
      }
      if accepted < count {
        stop(with: UTMHostProcessError.outputLimitExceeded)
        return
      }
    }
  }

  private func stop(with error: any Error) {
    guard !completed, failure == nil else { return }
    guard launched else {
      failure = error
      if continuation != nil { finishWithoutLaunching(error) }
      return
    }
    if !process.isRunning, !finishing, !(error is UTMHostProcessError) {
      processExited()
      return
    }
    let isTimeout = (error as? UTMHostProcessError) == .timedOut
    if !process.isRunning, !finishing, isTimeout {
      processExited()
      return
    }
    failure = error
    // Kill only this invocation's owned process. The termination handler confirms reaping.
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
  }

  private func processExited() {
    guard launched, !completed, !finishing else { return }
    finishing = true
    drain(stdoutPipe, isStandardError: false)
    drain(stderrPipe, isStandardError: true)
    completed = true
    timer?.cancel()
    stdoutSource?.cancel()
    stderrSource?.cancel()
    process.terminationHandler = nil
    let continuation = continuation
    self.continuation = nil
    if let failure {
      continuation?.resume(throwing: failure)
    } else {
      continuation?.resume(
        returning: UTMHostProcessResult(
          processIdentifier: process.processIdentifier, standardOutput: standardOutput,
          standardError: standardError, terminationStatus: process.terminationStatus,
          terminationReason: process.terminationReason))
    }
  }

  private func finishWithoutLaunching(_ error: any Error) {
    guard !completed else { return }
    completed = true
    process.terminationHandler = nil
    try? stdoutPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForWriting.close()
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(throwing: error)
  }
}
