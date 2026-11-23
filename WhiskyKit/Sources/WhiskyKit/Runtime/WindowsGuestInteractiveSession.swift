// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct WindowsGuestInteractiveLaunchRequest: Sendable {
  let helperGuestPath: String
  let executable: String
  let arguments: [String]
  let environment: [String: String]
}

struct WindowsGuestInteractiveTiming: Sendable {
  let deadline: ContinuousClock.Instant
  let pollInterval: Duration
}

private struct InteractiveControlRequest: Sendable {
  let helperGuestPath: String
  let operation: String
  let requestID: String
}

extension UTMGuestTransport {
  func executeInteractive(
    _ identifier: String, request: WindowsGuestInteractiveLaunchRequest,
    timing: WindowsGuestInteractiveTiming
  ) async throws -> WindowsGuestInteractiveProcessHandle {
    let effectiveDeadline = min(timing.deadline, UTMGuestOperationDeadline.value ?? timing.deadline)
    let effectiveTiming = WindowsGuestInteractiveTiming(
      deadline: effectiveDeadline, pollInterval: timing.pollInterval)
    return try await UTMGuestOperationDeadline.$value.withValue(effectiveDeadline) {
      try await executeInteractiveOperation(identifier, request: request, timing: effectiveTiming)
    }
  }

  private func executeInteractiveOperation(
    _ identifier: String, request: WindowsGuestInteractiveLaunchRequest,
    timing: WindowsGuestInteractiveTiming
  ) async throws -> WindowsGuestInteractiveProcessHandle {
    let requestID = UUID().uuidString.lowercased()
    let payload = try WindowsGuestInteractiveManifest.encode(
      executable: request.executable, arguments: request.arguments,
      environment: request.environment)
    var controllerPID: Int32 = 0
    do {
      controllerPID = try await execute(
        identifier, executable: request.helperGuestPath,
        arguments: ["launch", requestID, payload], environment: [:])
      guard controllerPID > 0 else { throw WindowsGuestInteractiveError.invalidResponse }
      let statusControl = InteractiveControlRequest(
        helperGuestPath: request.helperGuestPath, operation: "status", requestID: requestID)
      while ContinuousClock.now < timing.deadline {
        try Task.checkCancellation()
        guard try await inspect(identifier).status == .started else {
          throw UTMGuestError.vmStopped
        }
        var response = try await interactiveResponse(
          identifier, control: statusControl, timing: timing)
        if response.state == .failed, response.error == "controllerExited" {
          response = try await interactiveResponse(
            identifier, control: statusControl, timing: timing)
        }
        if response.state != .starting {
          let snapshot = try response.snapshot()
          guard snapshot.controllerPID == controllerPID else {
            throw WindowsGuestInteractiveError.identityMismatch
          }
          return WindowsGuestInteractiveProcessHandle(
            requestID: requestID, controllerPID: controllerPID, targetPID: snapshot.targetPID,
            targetCreationTime: snapshot.targetCreationTime, sessionID: snapshot.sessionID,
            helperGuestPath: request.helperGuestPath)
        }
        try await Task.sleep(for: timing.pollInterval)
      }
      throw WindowsGuestInteractiveError.timedOut
    } catch {
      try await reclaimFailedLaunch(
        identifier, helperGuestPath: request.helperGuestPath, requestID: requestID,
        pollInterval: timing.pollInterval)
      throw error
    }
  }

  private func reclaimFailedLaunch(
    _ identifier: String, helperGuestPath: String, requestID: String, pollInterval: Duration
  ) async throws {
    let cleanup = Task {
      let cleanupDeadline = ContinuousClock.now + .seconds(15)
      let cleanupTiming = WindowsGuestInteractiveTiming(
        deadline: cleanupDeadline, pollInterval: pollInterval)
      try await UTMGuestOperationDeadline.$value.withValue(cleanupDeadline) {
        try await reclaimInteractiveRequest(
          identifier, helperGuestPath: helperGuestPath, requestID: requestID,
          handle: nil, timing: cleanupTiming)
      }
    }
    do { try await cleanup.value } catch {
      throw WindowsGuestInteractiveError.cancellationFailed
    }
  }

  func interactiveSnapshot(
    _ identifier: String, handle: WindowsGuestInteractiveProcessHandle,
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> WindowsGuestInteractiveProcessSnapshot {
    let timing = WindowsGuestInteractiveTiming(deadline: deadline, pollInterval: pollInterval)
    let control = InteractiveControlRequest(
      helperGuestPath: handle.helperGuestPath, operation: "status", requestID: handle.requestID)
    var response = try await interactiveResponse(identifier, control: control, timing: timing)
    if response.state == .failed, response.error == "controllerExited" {
      response = try await interactiveResponse(identifier, control: control, timing: timing)
    }
    return try response.snapshot(matching: handle)
  }

  func cancelInteractive(
    _ identifier: String, handle: WindowsGuestInteractiveProcessHandle,
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws {
    let timing = WindowsGuestInteractiveTiming(deadline: deadline, pollInterval: pollInterval)
    try await reclaimInteractiveRequest(
      identifier, helperGuestPath: handle.helperGuestPath, requestID: handle.requestID,
      handle: handle, timing: timing)
  }

  private func reclaimInteractiveRequest(
    _ identifier: String, helperGuestPath: String, requestID: String,
    handle: WindowsGuestInteractiveProcessHandle?, timing: WindowsGuestInteractiveTiming
  ) async throws {
    let gracefulDeadline = min(timing.deadline, .now + .seconds(5))
    let gracefulTiming = WindowsGuestInteractiveTiming(
      deadline: gracefulDeadline, pollInterval: timing.pollInterval)
    let cancelControl = InteractiveControlRequest(
      helperGuestPath: helperGuestPath, operation: "cancel", requestID: requestID)
    do {
      while ContinuousClock.now < gracefulDeadline {
        let response = try await interactiveResponse(
          identifier, control: cancelControl, timing: gracefulTiming)
        if try cleanupConfirmed(response, matching: handle) { return }
        let errorCode = response.error ?? ""
        let retryable = ["requestMissing", "requestNotReady"].contains(errorCode)
        if response.state == .failed, !retryable { break }
        try await Task.sleep(for: timing.pollInterval)
      }
    } catch {
      // Recovery authenticates the UUID and native process handles independently of QGA results.
    }
    let forceControl = InteractiveControlRequest(
      helperGuestPath: helperGuestPath, operation: "force-cancel", requestID: requestID)
    let response = try await interactiveResponse(
      identifier, control: forceControl, timing: timing)
    guard try cleanupConfirmed(response, matching: handle) else {
      throw WindowsGuestInteractiveError.cancellationFailed
    }
  }

  private func cleanupConfirmed(
    _ response: WindowsGuestInteractiveResponse,
    matching handle: WindowsGuestInteractiveProcessHandle?
  ) throws -> Bool {
    if response.state == .exited {
      let snapshot = try response.snapshot(matching: handle)
      return snapshot.rootExited && snapshot.activeProcessCount == 0
    }
    return handle == nil && response.state == .failed && response.error == "launchCancelled"
      && response.cancelled && response.launchSuppressed == true && response.targetPID == 0
  }

  private func interactiveResponse(
    _ identifier: String, control: InteractiveControlRequest,
    timing: WindowsGuestInteractiveTiming
  ) async throws -> WindowsGuestInteractiveResponse {
    let effectiveDeadline = min(timing.deadline, UTMGuestOperationDeadline.value ?? timing.deadline)
    let args = [control.operation, control.requestID]
    let data = try await UTMGuestOperationDeadline.$value.withValue(effectiveDeadline) {
      if let automation = self as? UTMAppleScriptTransport {
        return try await automation.collectOutput(
          identifier, executable: control.helperGuestPath, arguments: args,
          until: effectiveDeadline, pollInterval: timing.pollInterval,
          expectedRequestID: control.requestID)
      }
      return try await collectOutput(
        identifier, executable: control.helperGuestPath, arguments: args,
        until: effectiveDeadline, pollInterval: timing.pollInterval)
    }
    return try WindowsGuestInteractiveResponse.decode(data, requestID: control.requestID)
  }
}

/// A desktop process session whose identity and output belong to the real target.
public actor WindowsGuestInteractiveSession {
  public nonisolated let handle: WindowsGuestInteractiveProcessHandle
  private let transport: any UTMGuestTransport
  private let vmID: String
  private let interval: Duration
  private var lastSnapshot: WindowsGuestInteractiveProcessSnapshot?
  private var terminalResult: RuntimeExitResult?
  private var cancellationTask: Task<Bool, Never>?
  private var cancellationGeneration = 0
  private var cancellationConfirmed = false
  private var cancellationFailure = false

  init(
    transport: any UTMGuestTransport, vmID: String,
    handle: WindowsGuestInteractiveProcessHandle, interval: Duration
  ) {
    self.transport = transport
    self.vmID = vmID
    self.handle = handle
    self.interval = interval
  }

  public func latestSnapshot() async throws -> WindowsGuestInteractiveProcessSnapshot {
    if let lastSnapshot, lastSnapshot.state == .exited { return lastSnapshot }
    let localDeadline = ContinuousClock.now + .seconds(10)
    let deadline = min(localDeadline, UTMGuestOperationDeadline.value ?? localDeadline)
    let value = try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      guard try await transport.inspect(vmID).status == .started else {
        throw UTMGuestError.vmStopped
      }
      return try await transport.interactiveSnapshot(
        vmID, handle: handle, until: deadline, pollInterval: interval)
    }
    // Another reentrant snapshot may have committed the terminal state while this one waited.
    if let lastSnapshot, lastSnapshot.state == .exited { return lastSnapshot }
    lastSnapshot = value
    return value
  }

  public func wait() async throws -> RuntimeExitResult {
    if let terminalResult { return terminalResult }
    do {
      while true {
        try Task.checkCancellation()
        let snapshot = try await latestSnapshot()
        if let status = snapshot.exitCode, snapshot.state == .exited {
          // Preserve the root's actual exit separately; a cancelled tree cannot report success.
          let result = RuntimeExitResult(status: snapshot.cancelled ? 1223 : status, reason: .exit)
          terminalResult = result
          return result
        }
        if cancellationFailure { throw WindowsGuestInteractiveError.cancellationFailed }
        try await Task.sleep(for: interval)
      }
    } catch is CancellationError {
      await cancel()
      throw CancellationError()
    }
  }

  public func cancel() async {
    guard !cancellationConfirmed, terminalResult == nil, lastSnapshot?.state != .exited else {
      return
    }
    let task: Task<Bool, Never>
    let generation: Int
    if let current = cancellationTask {
      task = current
      generation = cancellationGeneration
    } else {
      cancellationGeneration += 1
      generation = cancellationGeneration
      cancellationFailure = false
      let deadline = ContinuousClock.now + .seconds(15)
      task = Task {
        do {
          try await UTMGuestOperationDeadline.$value.withValue(deadline) {
            try await self.transport.cancelInteractive(
              self.vmID, handle: self.handle, until: deadline, pollInterval: self.interval)
          }
          return true
        } catch { return false }
      }
      cancellationTask = task
    }
    let confirmed = await task.value
    if generation == cancellationGeneration {
      cancellationTask = nil
      cancellationConfirmed = confirmed
      cancellationFailure = !confirmed
    }
  }

  public nonisolated func asRuntimeSession() -> RuntimeSession {
    RuntimeSession(wait: { try await self.wait() }, cancel: { await self.cancel() })
  }
}
