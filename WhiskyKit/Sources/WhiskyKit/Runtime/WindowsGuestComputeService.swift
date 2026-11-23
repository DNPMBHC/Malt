// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// A bounded, single-request TCP service for explicit guest-to-host computation.
/// Bind to a verified VM-only interface or loopback; no wildcard listener is allowed.
/// An injected handler must respond to task cancellation, as the default handler does.
public actor WindowsGuestComputeService {
  private let bindAddress: String
  private let requestTimeout: Duration
  private let sessionTimeout: Duration
  private let cancelGuest: @Sendable () async -> Void
  private let handler: WindowsGuestComputeHandler
  private let nonce: String
  private let queue = DispatchQueue(label: "module-b.compute.transport")
  private var listener: NWListener?
  private var connection: NWConnection?
  private var readyContinuation: CheckedContinuation<WindowsGuestComputeEndpoint, any Error>?
  private var waiters: [CheckedContinuation<WindowsGuestComputeResponse, any Error>] = []
  private var computation: Task<[Int64], any Error>?
  private var requestDeadlineTask: Task<Void, Never>?
  private var sessionDeadlineTask: Task<Void, Never>?
  private var request: WindowsGuestComputeRequest?
  private var finalResponse: WindowsGuestComputeResponse?
  private var finishing = false
  private var started = false
  private var events: [String] = []

  public init(
    bindAddress: String, requestTimeout: Duration = .seconds(5),
    sessionTimeout: Duration = .seconds(15),
    cancelGuest: @escaping @Sendable () async -> Void = {},
    handler: @escaping WindowsGuestComputeHandler = { try WindowsGuestComputeService.evaluate($0) }
  ) {
    self.bindAddress = bindAddress
    self.requestTimeout = requestTimeout
    self.sessionTimeout = sessionTimeout
    self.cancelGuest = cancelGuest
    self.handler = handler
    nonce = Self.generateNonce()
  }

  public func start() async throws -> WindowsGuestComputeEndpoint {
    guard !started, !finishing, finalResponse == nil else {
      throw WindowsGuestComputeServiceError.alreadyStarted
    }
    guard !bindAddress.isEmpty, !["0.0.0.0", "::", "*"].contains(bindAddress),
      requestTimeout > .zero, sessionTimeout > .zero
    else {
      throw WindowsGuestComputeServiceError.invalidBindAddress
    }
    started = true
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: .any)
    let value: NWListener
    do { value = try NWListener(using: parameters) } catch {
      throw WindowsGuestComputeServiceError.listenerFailed
    }
    listener = value
    sessionDeadlineTask = Task { [sessionTimeout] in
      do {
        try await Task.sleep(for: sessionTimeout)
        await self.finish(
          status: .timedOut, errorCode: .deadlineExceeded, values: [], terminateGuest: true)
      } catch {}
    }
    value.stateUpdateHandler = { [weak self] state in
      Task { await self?.listenerStateChanged(state) }
    }
    value.newConnectionHandler = { [weak self] incoming in
      Task { await self?.accept(incoming) }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        readyContinuation = continuation
        value.start(queue: queue)
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  public func wait() async throws -> WindowsGuestComputeResponse {
    guard started else { throw WindowsGuestComputeServiceError.notStarted }
    if let finalResponse { return finalResponse }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiters.append($0) }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  public func cancel() async {
    await finish(status: .cancelled, errorCode: .cancelled, values: [], terminateGuest: true)
  }

  public func snapshot() -> WindowsGuestComputeTrace {
    WindowsGuestComputeTrace(
      events: events, request: request, response: finalResponse,
      hasActiveConnection: connection != nil, hasActiveComputation: computation != nil)
  }

  public nonisolated static func evaluate(_ request: WindowsGuestComputeRequest) throws -> [Int64] {
    guard request.operation == .affine else {
      throw WindowsGuestComputeFailureCode.unsupportedOperation
    }
    guard request.values.count <= WindowsGuestComputeWire.maximumValues else {
      throw WindowsGuestComputeFailureCode.invalidRequest
    }
    return try request.values.map { value in
      try Task.checkCancellation()
      let product = Int64(value).multipliedReportingOverflow(by: request.scale)
      let result = product.partialValue.addingReportingOverflow(request.bias)
      guard !product.overflow, !result.overflow else {
        throw WindowsGuestComputeFailureCode.arithmeticOverflow
      }
      return result.partialValue
    }
  }

}

extension WindowsGuestComputeService {
  private func listenerStateChanged(_ state: NWListener.State) async {
    switch state {
    case .ready:
      guard !finishing, finalResponse == nil, let port = listener?.port else { return }
      events.append("listener.ready")
      readyContinuation?.resume(
        returning: WindowsGuestComputeEndpoint(host: bindAddress, port: port.rawValue, nonce: nonce)
      )
      readyContinuation = nil
    case .failed:
      await finish(status: .failed, errorCode: .transportFailure, values: [], terminateGuest: true)
    default:
      break
    }
  }

  private func accept(_ incoming: NWConnection) {
    guard !finishing, finalResponse == nil, connection == nil, request == nil else {
      incoming.cancel()
      return
    }
    connection = incoming
    events.append("connection.accepted")
    incoming.start(queue: queue)
    Task {
      do {
        let prefix = try await Self.read(incoming, count: 4)
        let length = try WindowsGuestComputeWire.payloadLength(prefix)
        let body = try await Self.read(incoming, count: length)
        let value = try WindowsGuestComputeWire.decodeRequest(body)
        await self.received(value, from: incoming)
      } catch {
        self.rejectUnauthenticated(incoming)
      }
    }
  }

  private func rejectUnauthenticated(_ incoming: NWConnection) {
    incoming.cancel()
    guard connection === incoming, request == nil else { return }
    connection = nil
    events.append("request.frameRejected")
  }

  private func authenticatedPeerFailed(
    _ incoming: NWConnection, errorCode: WindowsGuestComputeFailureCode
  ) async {
    guard connection === incoming, request != nil else { return }
    await finish(status: .failed, errorCode: errorCode, values: [], terminateGuest: true)
  }

  private func received(_ value: WindowsGuestComputeRequest, from incoming: NWConnection) async {
    guard !finishing, finalResponse == nil, connection === incoming else { return }
    guard value.nonce == nonce else {
      events.append("request.authenticationRejected")
      let rejected = WindowsGuestComputeResponse(
        requestID: value.requestID, nonce: value.nonce, status: .failed,
        errorCode: .authenticationFailed)
      try? await Self.send(WindowsGuestComputeWire.encode(rejected), through: incoming)
      incoming.cancel()
      if connection === incoming { connection = nil }
      return
    }
    request = value
    events.append("request.authenticated")
    Task {
      do {
        _ = try await Self.read(incoming, count: 1)
        await self.authenticatedPeerFailed(incoming, errorCode: .invalidRequest)
      } catch {
        await self.authenticatedPeerFailed(incoming, errorCode: .transportFailure)
      }
    }
    let deadline = min(requestTimeout, .milliseconds(Int64(value.deadlineMilliseconds)))
    requestDeadlineTask = Task {
      do {
        try await Task.sleep(for: deadline)
        await self.finish(
          status: .timedOut, errorCode: .deadlineExceeded, values: [], terminateGuest: false)
      } catch {}
    }
    let operation = Task { [handler] in try await handler(value) }
    computation = operation
    Task {
      do {
        let values = try await operation.value
        await self.computationEnded(values: values, errorCode: nil)
      } catch is CancellationError {
        await self.computationEnded(values: [], errorCode: .cancelled)
      } catch let code as WindowsGuestComputeFailureCode {
        await self.computationEnded(values: [], errorCode: code)
      } catch {
        await self.computationEnded(values: [], errorCode: .internalFailure)
      }
    }
  }

  private func computationEnded(values: [Int64], errorCode: WindowsGuestComputeFailureCode?) async {
    computation = nil
    if finishing || finalResponse != nil {
      events.append("computation.stopped")
      return
    }
    let status: WindowsGuestComputeStatus =
      errorCode == nil ? .succeeded : (errorCode == .cancelled ? .cancelled : .failed)
    await finish(status: status, errorCode: errorCode, values: values, terminateGuest: false)
  }

  private func finish(
    status: WindowsGuestComputeStatus, errorCode: WindowsGuestComputeFailureCode?,
    values: [Int64], terminateGuest: Bool
  ) async {
    guard !finishing, finalResponse == nil else { return }
    finishing = true
    requestDeadlineTask?.cancel()
    sessionDeadlineTask?.cancel()
    requestDeadlineTask = nil
    sessionDeadlineTask = nil
    if status != .succeeded { computation?.cancel() }
    let response = WindowsGuestComputeResponse(
      requestID: request?.requestID ?? 0, nonce: nonce, status: status,
      errorCode: errorCode, values: values)
    events.append("response.\(status)")
    if let connection, request != nil {
      if let frame = try? WindowsGuestComputeWire.encode(response) {
        try? await Self.send(frame, through: connection)
      }
    }
    connection?.cancel()
    connection = nil
    listener?.cancel()
    listener = nil
    if terminateGuest {
      // A deadline task can cancel itself above. Guest cleanup runs in its own task.
      let cleanup = Task { [cancelGuest] in await cancelGuest() }
      await cleanup.value
    }
    let cancellationDeadline = ContinuousClock.now + .milliseconds(200)
    while computation != nil && ContinuousClock.now < cancellationDeadline {
      let pause = Task { try? await Task.sleep(for: .milliseconds(5)) }
      await pause.value
    }
    events.append(computation == nil ? "session.cleaned" : "computation.cancellationUnconfirmed")
    readyContinuation?.resume(throwing: WindowsGuestComputeServiceError.listenerFailed)
    readyContinuation = nil
    finalResponse = response
    for waiter in waiters { waiter.resume(returning: response) }
    waiters.removeAll()
    finishing = false
  }

  private nonisolated static func read(
    _ connection: NWConnection, count: Int
  ) async throws -> Data {
    var result = Data()
    while result.count < count {
      let remaining = count - result.count
      let chunk: Data = try await withCheckedThrowingContinuation { continuation in
        connection.receive(
          minimumIncompleteLength: 1, maximumLength: remaining
        ) { data, _, complete, error in
          if error != nil || (complete && (data?.isEmpty ?? true)) {
            continuation.resume(throwing: WindowsGuestComputeServiceError.connectionClosed)
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: WindowsGuestComputeServiceError.connectionClosed)
          }
        }
      }
      result.append(chunk)
    }
    return result
  }

  private nonisolated static func send(
    _ data: Data, through connection: NWConnection
  ) async throws {
    let sendDeadline = Task {
      do {
        try await Task.sleep(for: .seconds(1))
        connection.cancel()
      } catch {}
    }
    defer { sendDeadline.cancel() }
    let _: Void = try await withCheckedThrowingContinuation { continuation in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if error != nil {
            continuation.resume(throwing: WindowsGuestComputeServiceError.connectionClosed)
          } else {
            continuation.resume()
          }
        })
    }
  }

  private nonisolated static func generateNonce() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
    }
    .joined()
  }
}
