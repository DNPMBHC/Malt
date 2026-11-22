// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

actor UTMGuestSession {
  let transport: any UTMGuestTransport
  let vmID: String
  let pid: Int32
  let interval: Duration
  var finalResult: RuntimeExitResult?
  var cancelled = false
  var terminationFailure: UTMGuestError?
  init(transport: any UTMGuestTransport, vmID: String, pid: Int32, interval: Duration) {
    self.transport = transport
    self.vmID = vmID
    self.pid = pid
    self.interval = interval
  }
  func wait() async throws -> RuntimeExitResult {
    if let finalResult { return finalResult }
    do {
      while true {
        try Task.checkCancellation()
        guard try await transport.inspect(vmID).status == .started else {
          throw UTMGuestError.vmStopped
        }
        if let result = try await transport.result(vmID, pid: pid) {
          let value = RuntimeExitResult(
            status: result.signal == 0 ? result.exitCode : result.signal,
            reason: result.signal == 0 ? .exit : .signal)
          finalResult = value
          return value
        }
        if let terminationFailure { throw terminationFailure }
        try await Task.sleep(for: interval)
      }
    } catch is CancellationError {
      await cancel()
      throw CancellationError()
    }
  }
  func cancel() async {
    guard !cancelled, finalResult == nil else { return }
    cancelled = true
    do {
      try await transport.terminate(vmID, pid: pid)
    } catch {
      terminationFailure = .cancelFailed
    }
  }
}
actor UTMActiveGuest {
  private var identifier: String?

  func set(_ value: String) { identifier = value }
  func get() -> String? { identifier }
  func clear(ifMatching value: String) {
    if identifier == value { identifier = nil }
  }
}
