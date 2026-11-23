// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest

@testable import WhiskyKit

final class UTMComputeTests: XCTestCase {
  func testWirePreservesSignedBoundaryValuesAndCorrelation() throws {
    let request = WindowsGuestComputeRequest(
      requestID: UInt64.max, nonce: String(repeating: "a", count: 64),
      values: [Int32.min, -1, 0, 1, Int32.max], scale: Int64.min, bias: Int64.max)
    let frame = try WindowsGuestComputeWire.encode(request)
    XCTAssertEqual(try WindowsGuestComputeWire.payloadLength(frame.prefix(4)), frame.count - 4)
    XCTAssertEqual(try WindowsGuestComputeWire.decodeRequest(frame.dropFirst(4)), request)
    let response = WindowsGuestComputeResponse(
      requestID: request.requestID, nonce: request.nonce, status: .succeeded,
      values: [Int64.min, 0, Int64.max])
    XCTAssertEqual(
      try WindowsGuestComputeWire.decodeResponse(
        WindowsGuestComputeWire.encode(response).dropFirst(4)),
      response)
  }

  func testWireRejectsOversizedMalformedAndCorruptFrames() throws {
    XCTAssertThrowsError(try WindowsGuestComputeWire.payloadLength(Data([0, 1, 0, 1])))
    XCTAssertThrowsError(try WindowsGuestComputeWire.decodeRequest(Data([0, 0, 0, 1])))
    let invalid = WindowsGuestComputeRequest(requestID: 1, nonce: "invalid", values: [1])
    XCTAssertThrowsError(try WindowsGuestComputeWire.encode(invalid))
    let oversized = WindowsGuestComputeRequest(
      requestID: 1, nonce: String(repeating: "a", count: 64),
      values: Array(repeating: 1, count: WindowsGuestComputeWire.maximumValues + 1))
    XCTAssertThrowsError(try WindowsGuestComputeWire.encode(oversized))
    let response = WindowsGuestComputeResponse(
      requestID: 1, nonce: String(repeating: "a", count: 64), status: .succeeded, values: [42])
    var bytes = try WindowsGuestComputeWire.encode(response).dropFirst(4)
    bytes[bytes.index(before: bytes.endIndex)] ^= 1
    XCTAssertThrowsError(try WindowsGuestComputeWire.decodeResponse(Data(bytes)))
  }

  func testCheckedAffineRejectsOverflow() throws {
    let request = WindowsGuestComputeRequest(
      requestID: 1, nonce: String(repeating: "a", count: 64), values: [Int32.max], scale: Int64.max)
    XCTAssertThrowsError(try WindowsGuestComputeService.evaluate(request)) { error in
      XCTAssertEqual(error as? WindowsGuestComputeFailureCode, .arithmeticOverflow)
    }
  }

  func testLoopbackComputesAndHandlesFragmentedFrames() async throws {
    let service = WindowsGuestComputeService(bindAddress: "127.0.0.1")
    let endpoint = try await service.start()
    let request = Self.request(endpoint)
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(request, fragmented: true) }
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(response, peerResponse)
    XCTAssertEqual(response.status, .succeeded)
    XCTAssertEqual(response.values, try WindowsGuestComputeService.evaluate(request))
    let trace = await service.snapshot()
    XCTAssertFalse(trace.hasActiveConnection)
    XCTAssertFalse(trace.hasActiveComputation)
  }

  func testLoopbackPropagatesHostFailure() async throws {
    let service = WindowsGuestComputeService(bindAddress: "127.0.0.1")
    let endpoint = try await service.start()
    let request = WindowsGuestComputeRequest(
      requestID: 2, nonce: endpoint.nonce, operation: .reject, values: [1])
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(request) }
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(peerResponse, response)
    XCTAssertEqual(response.status, .failed)
    XCTAssertEqual(response.errorCode, .unsupportedOperation)
    XCTAssertTrue(response.values.isEmpty)
  }

  func testLoopbackTimeoutCancelsHostComputationAndReturnsTypedError() async throws {
    let service = WindowsGuestComputeService(
      bindAddress: "127.0.0.1", requestTimeout: .milliseconds(40),
      handler: { value in
        try await Task.sleep(for: .seconds(30))
        return try WindowsGuestComputeService.evaluate(value)
      })
    let endpoint = try await service.start()
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(Self.request(endpoint)) }
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(peerResponse, response)
    XCTAssertEqual(response.status, .timedOut)
    XCTAssertEqual(response.errorCode, .deadlineExceeded)
    let trace = await service.snapshot()
    XCTAssertFalse(trace.hasActiveComputation)
  }

  func testLoopbackCancelIsTerminalAndCancelsGuestExactlyOnce() async throws {
    let guest = UTMComputeCancellationCounter()
    let service = WindowsGuestComputeService(
      bindAddress: "127.0.0.1", cancelGuest: { await guest.increment() },
      handler: { value in
        try await Task.sleep(for: .seconds(30))
        return try WindowsGuestComputeService.evaluate(value)
      })
    let endpoint = try await service.start()
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(Self.request(endpoint)) }
    try await Self.waitForRequest(service)
    await service.cancel()
    await service.cancel()
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(peerResponse, response)
    XCTAssertEqual(response.status, .cancelled)
    let count = await guest.value()
    XCTAssertEqual(count, 1)
    let trace = await service.snapshot()
    XCTAssertFalse(trace.hasActiveConnection)
    XCTAssertFalse(trace.hasActiveComputation)
  }

  func testUnauthenticatedPeerCannotSubmitComputation() async throws {
    let service = WindowsGuestComputeService(bindAddress: "127.0.0.1")
    let endpoint = try await service.start()
    let client = UTMComputeClient(endpoint)
    let rejected = try await client.exchange(
      WindowsGuestComputeRequest(
        requestID: 1, nonce: String(repeating: "0", count: 64), values: [1]))
    XCTAssertEqual(rejected.status, .failed)
    XCTAssertEqual(rejected.errorCode, .authenticationFailed)
    let deadline = ContinuousClock.now + .seconds(2)
    while await service.snapshot().hasActiveConnection && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let valid = UTMComputeClient(endpoint)
    let operation = Task { try await valid.exchange(Self.request(endpoint)) }
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(peerResponse, response)
    XCTAssertEqual(response.status, .succeeded)
  }

  func testPeerDisconnectPropagatesFailureAndCleansHostWork() async throws {
    let service = WindowsGuestComputeService(
      bindAddress: "127.0.0.1",
      handler: { value in
        try await Task.sleep(for: .seconds(30))
        return try WindowsGuestComputeService.evaluate(value)
      })
    let endpoint = try await service.start()
    let client = UTMComputeClient(endpoint)
    try await client.submit(Self.request(endpoint))
    try await Self.waitForRequest(service)
    client.cancel()
    let response = try await service.wait()
    XCTAssertEqual(response.status, .failed)
    XCTAssertEqual(response.errorCode, .transportFailure)
    let trace = await service.snapshot()
    XCTAssertFalse(trace.hasActiveComputation)
  }

  func testUnconnectedSessionTimeoutTerminatesGuestAndClosesListener() async throws {
    let guest = UTMComputeCancellationCounter()
    let service = WindowsGuestComputeService(
      bindAddress: "127.0.0.1", sessionTimeout: .milliseconds(30),
      cancelGuest: { await guest.increment() })
    _ = try await service.start()
    let response = try await service.wait()
    XCTAssertEqual(response.status, .timedOut)
    let count = await guest.value()
    XCTAssertEqual(count, 1)
  }

}

extension UTMComputeTests {
  func testMalformedUnauthenticatedFrameDoesNotTerminateGuest() async throws {
    let guest = UTMComputeCancellationCounter()
    let service = WindowsGuestComputeService(
      bindAddress: "127.0.0.1", cancelGuest: { await guest.increment() })
    let endpoint = try await service.start()
    let malformed = UTMComputeClient(endpoint)
    try await malformed.submitRaw(Data([0, 1, 0, 1]))
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await service.snapshot().events.contains("request.frameRejected")) {
      guard ContinuousClock.now < deadline else {
        throw WindowsGuestComputeServiceError.connectionClosed
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    malformed.cancel()
    let count = await guest.value()
    XCTAssertEqual(count, 0)
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(Self.request(endpoint)) }
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(peerResponse, response)
    XCTAssertEqual(response.status, .succeeded)
  }

  func testNoncooperativeHandlerCannotHangTimeoutOrOverwriteTerminalResponse() async throws {
    let gate = UTMComputeGate()
    let service = WindowsGuestComputeService(
      bindAddress: "127.0.0.1", requestTimeout: .milliseconds(20),
      handler: { _ in
        await gate.wait()
        return [42]
      })
    let endpoint = try await service.start()
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(Self.request(endpoint)) }
    let started = ContinuousClock.now
    let response = try await service.wait()
    let peerResponse = try await operation.value
    XCTAssertEqual(response, peerResponse)
    XCTAssertEqual(response.status, .timedOut)
    XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    let pending = await service.snapshot()
    XCTAssertTrue(pending.hasActiveComputation)
    XCTAssertTrue(pending.events.contains("computation.cancellationUnconfirmed"))
    await gate.release()
    let deadline = ContinuousClock.now + .seconds(2)
    while await service.snapshot().hasActiveComputation && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let finalTrace = await service.snapshot()
    XCTAssertFalse(finalTrace.hasActiveComputation)
    let finalResponse = try await service.wait()
    XCTAssertEqual(finalResponse, response)
  }

  func testTraceContainsNoAuthenticationNonceOrEndpoint() async throws {
    let service = WindowsGuestComputeService(bindAddress: "127.0.0.1")
    let endpoint = try await service.start()
    let client = UTMComputeClient(endpoint)
    let operation = Task { try await client.exchange(Self.request(endpoint)) }
    _ = try await service.wait()
    _ = try await operation.value
    let trace = await service.snapshot()
    let json = try XCTUnwrap(String(bytes: try JSONEncoder().encode(trace), encoding: .utf8))
    XCTAssertFalse(json.contains(endpoint.nonce))
    XCTAssertFalse(json.contains(endpoint.host))
    XCTAssertFalse(json.contains("\"nonce\""))
  }

  private static func request(
    _ endpoint: WindowsGuestComputeEndpoint
  ) -> WindowsGuestComputeRequest {
    WindowsGuestComputeRequest(
      requestID: 1, nonce: endpoint.nonce, values: [0, 1, -1, Int32.min, Int32.max])
  }

  private static func waitForRequest(_ service: WindowsGuestComputeService) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await service.snapshot().request == nil {
      guard ContinuousClock.now < deadline else {
        throw WindowsGuestComputeServiceError.connectionClosed
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor UTMComputeCancellationCounter {
  private var count = 0
  func increment() { count += 1 }
  func value() -> Int { count }
}

private final class UTMComputeClient: @unchecked Sendable {
  private let connection: NWConnection
  init(_ endpoint: WindowsGuestComputeEndpoint) {
    guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
      preconditionFailure("Expected valid NWEndpoint.Port")
    }
    connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
    connection.start(queue: DispatchQueue(label: "module-b.compute.test-client"))
  }
  func cancel() { connection.cancel() }
  func submitRaw(_ data: Data) async throws { try await send(data) }
  func submit(_ request: WindowsGuestComputeRequest, fragmented: Bool = false) async throws {
    let frame = try WindowsGuestComputeWire.encode(request)
    if fragmented {
      for byte in frame { try await send(Data([byte])) }
    } else {
      try await send(frame)
    }
  }
  func exchange(
    _ request: WindowsGuestComputeRequest, fragmented: Bool = false
  ) async throws -> WindowsGuestComputeResponse {
    defer { connection.cancel() }
    try await submit(request, fragmented: fragmented)
    let length = try WindowsGuestComputeWire.payloadLength(try await read(count: 4))
    return try WindowsGuestComputeWire.decodeResponse(try await read(count: length))
  }
  private func send(_ data: Data) async throws {
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
  private func read(count: Int) async throws -> Data {
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
}

private actor UTMComputeGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
