// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum WindowsGuestComputeOperation: UInt32, Codable, Sendable {
  case affine = 1
  case reject = 2
}

public enum WindowsGuestComputeStatus: UInt32, Codable, Sendable {
  case succeeded = 1
  case timedOut = 2
  case cancelled = 3
  case failed = 4
}

public enum WindowsGuestComputeFailureCode: UInt32, Codable, Sendable, Error {
  case unsupportedOperation = 1
  case invalidRequest = 2
  case arithmeticOverflow = 3
  case deadlineExceeded = 4
  case cancelled = 5
  case transportFailure = 6
  case authenticationFailed = 7
  case internalFailure = 8
}

/// This protocol delegates an explicit operation requested by a guest-owned process.
/// It does not migrate PE execution or guest CPU/GPU instructions to the host.
public struct WindowsGuestComputeRequest: Codable, Equatable, Sendable {
  public let requestID: UInt64
  public let nonce: String
  public let operation: WindowsGuestComputeOperation
  public let deadlineMilliseconds: UInt32
  public let values: [Int32]
  public let scale: Int64
  public let bias: Int64

  public init(
    requestID: UInt64, nonce: String, operation: WindowsGuestComputeOperation = .affine,
    deadlineMilliseconds: UInt32 = 5_000, values: [Int32], scale: Int64 = 3, bias: Int64 = -7
  ) {
    self.requestID = requestID
    self.nonce = nonce
    self.operation = operation
    self.deadlineMilliseconds = deadlineMilliseconds
    self.values = values
    self.scale = scale
    self.bias = bias
  }
}

public struct WindowsGuestComputeResponse: Codable, Equatable, Sendable {
  public let requestID: UInt64
  public let nonce: String
  public let status: WindowsGuestComputeStatus
  public let errorCode: WindowsGuestComputeFailureCode?
  public let values: [Int64]
  public let checksum: UInt64

  public init(
    requestID: UInt64, nonce: String, status: WindowsGuestComputeStatus,
    errorCode: WindowsGuestComputeFailureCode? = nil, values: [Int64] = []
  ) {
    self.requestID = requestID
    self.nonce = nonce
    self.status = status
    self.errorCode = errorCode
    self.values = values
    checksum = WindowsGuestComputeWire.checksum(values)
  }
}

public struct WindowsGuestComputeEndpoint: Codable, Equatable, Sendable {
  public let host: String
  public let port: UInt16
  public let nonce: String
}

/// Evidence traces omit the transient authentication nonce and network endpoint.
public struct WindowsGuestComputeTrace: Codable, Equatable, Sendable {
  public struct Request: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let operation: WindowsGuestComputeOperation
    public let deadlineMilliseconds: UInt32
    public let values: [Int32]
    public let scale: Int64
    public let bias: Int64
  }
  public struct Response: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let status: WindowsGuestComputeStatus
    public let errorCode: WindowsGuestComputeFailureCode?
    public let values: [Int64]
    public let checksum: UInt64
  }
  public let events: [String]
  public let request: Request?
  public let response: Response?
  public let hasActiveConnection: Bool
  public let hasActiveComputation: Bool

  init(
    events: [String], request: WindowsGuestComputeRequest?, response: WindowsGuestComputeResponse?,
    hasActiveConnection: Bool, hasActiveComputation: Bool
  ) {
    self.events = events
    self.request = request.map {
      Request(
        requestID: $0.requestID, operation: $0.operation,
        deadlineMilliseconds: $0.deadlineMilliseconds, values: $0.values,
        scale: $0.scale, bias: $0.bias)
    }
    self.response = response.map {
      Response(
        requestID: $0.requestID, status: $0.status, errorCode: $0.errorCode,
        values: $0.values, checksum: $0.checksum)
    }
    self.hasActiveConnection = hasActiveConnection
    self.hasActiveComputation = hasActiveComputation
  }
}

public typealias WindowsGuestComputeHandler =
  @Sendable (WindowsGuestComputeRequest) async throws -> [Int64]

public enum WindowsGuestComputeServiceError: Error, Sendable, Equatable {
  case invalidBindAddress
  case alreadyStarted
  case notStarted
  case listenerFailed
  case frameTooLarge
  case invalidFrame
  case connectionClosed
}

/// The four-byte network-order length prefix and all integer fields are big endian.
/// A 64-character hexadecimal nonce binds every frame to a single service lifetime.
public enum WindowsGuestComputeWire {
  public static let maximumFrameBytes = 65_536
  public static let maximumValues = 4_096

  public static func encode(_ request: WindowsGuestComputeRequest) throws -> Data {
    guard request.values.count <= UInt32(maximumValues), validNonce(request.nonce),
      request.deadlineMilliseconds > 0
    else {
      throw WindowsGuestComputeFailureCode.invalidRequest
    }
    var bytes = Data()
    append(UInt32(1), to: &bytes)
    append(UInt32(1), to: &bytes)
    append(request.requestID, to: &bytes)
    bytes.append(contentsOf: request.nonce.utf8)
    append(request.operation.rawValue, to: &bytes)
    append(request.deadlineMilliseconds, to: &bytes)
    append(UInt32(request.values.count), to: &bytes)
    append(UInt64(bitPattern: request.scale), to: &bytes)
    append(UInt64(bitPattern: request.bias), to: &bytes)
    for value in request.values { append(UInt32(bitPattern: value), to: &bytes) }
    return try frame(bytes)
  }

  public static func decodeRequest(_ data: Data) throws -> WindowsGuestComputeRequest {
    var reader = Reader(data)
    guard try reader.uint32() == 1, try reader.uint32() == 1 else {
      throw WindowsGuestComputeServiceError.invalidFrame
    }
    let identifier = try reader.uint64()
    let nonce = try reader.nonce()
    guard let operation = WindowsGuestComputeOperation(rawValue: try reader.uint32()) else {
      throw WindowsGuestComputeFailureCode.unsupportedOperation
    }
    let deadline = try reader.uint32()
    let count = try reader.uint32()
    guard count <= UInt32(maximumValues), deadline > 0 else {
      throw WindowsGuestComputeFailureCode.invalidRequest
    }
    let scale = Int64(bitPattern: try reader.uint64())
    let bias = Int64(bitPattern: try reader.uint64())
    var values: [Int32] = []
    for _ in 0..<count { values.append(Int32(bitPattern: try reader.uint32())) }
    try reader.requireEnd()
    return WindowsGuestComputeRequest(
      requestID: identifier, nonce: nonce, operation: operation,
      deadlineMilliseconds: deadline, values: values, scale: scale, bias: bias)
  }

  public static func encode(_ response: WindowsGuestComputeResponse) throws -> Data {
    guard response.values.count <= UInt32(maximumValues), validNonce(response.nonce) else {
      throw WindowsGuestComputeServiceError.invalidFrame
    }
    var bytes = Data()
    append(UInt32(1), to: &bytes)
    append(UInt32(2), to: &bytes)
    append(response.requestID, to: &bytes)
    bytes.append(contentsOf: response.nonce.utf8)
    append(response.status.rawValue, to: &bytes)
    append(response.errorCode?.rawValue ?? 0, to: &bytes)
    append(UInt32(response.values.count), to: &bytes)
    append(response.checksum, to: &bytes)
    for value in response.values { append(UInt64(bitPattern: value), to: &bytes) }
    return try frame(bytes)
  }

  public static func decodeResponse(_ data: Data) throws -> WindowsGuestComputeResponse {
    var reader = Reader(data)
    guard try reader.uint32() == 1, try reader.uint32() == 2 else {
      throw WindowsGuestComputeServiceError.invalidFrame
    }
    let identifier = try reader.uint64()
    let nonce = try reader.nonce()
    guard let status = WindowsGuestComputeStatus(rawValue: try reader.uint32()) else {
      throw WindowsGuestComputeServiceError.invalidFrame
    }
    let errorValue = try reader.uint32()
    let errorCode = WindowsGuestComputeFailureCode(rawValue: errorValue)
    guard errorValue == 0 || errorCode != nil else {
      throw WindowsGuestComputeServiceError.invalidFrame
    }
    let count = try reader.uint32()
    guard count <= UInt32(maximumValues) else {
      throw WindowsGuestComputeServiceError.frameTooLarge
    }
    let expectedChecksum = try reader.uint64()
    var values: [Int64] = []
    for _ in 0..<count { values.append(Int64(bitPattern: try reader.uint64())) }
    try reader.requireEnd()
    let response = WindowsGuestComputeResponse(
      requestID: identifier, nonce: nonce, status: status, errorCode: errorCode, values: values)
    guard response.checksum == expectedChecksum,
      (status == .succeeded && errorCode == nil) || (status != .succeeded && errorCode != nil)
    else { throw WindowsGuestComputeServiceError.invalidFrame }
    return response
  }

  public static func payloadLength(_ prefix: Data) throws -> Int {
    var reader = Reader(prefix)
    let length = try reader.uint32()
    try reader.requireEnd()
    guard length > 0, length <= UInt32(maximumFrameBytes) else {
      throw WindowsGuestComputeServiceError.frameTooLarge
    }
    return Int(length)
  }

  public static func checksum(_ values: [Int64]) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for value in values {
      let bits = UInt64(bitPattern: value)
      for shift in stride(from: 56, through: 0, by: -8) {
        hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: bits >> shift))) &* 1_099_511_628_211
      }
    }
    return hash
  }

  static func validNonce(_ nonce: String) -> Bool {
    nonce.utf8.count == 64
      && nonce.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  private static func frame(_ payload: Data) throws -> Data {
    guard payload.count <= maximumFrameBytes else {
      throw WindowsGuestComputeServiceError.frameTooLarge
    }
    var bytes = Data()
    append(UInt32(payload.count), to: &bytes)
    bytes.append(payload)
    return bytes
  }

  private static func append(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 24, through: 0, by: -8) {
      data.append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }

  private static func append(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }

  private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func uint32() throws -> UInt32 {
      var value: UInt32 = 0
      for byte in try take(4) { value = (value << 8) | UInt32(byte) }
      return value
    }
    mutating func uint64() throws -> UInt64 {
      var value: UInt64 = 0
      for byte in try take(8) { value = (value << 8) | UInt64(byte) }
      return value
    }
    mutating func nonce() throws -> String {
      guard let value = String(bytes: try take(64), encoding: .utf8),
        WindowsGuestComputeWire.validNonce(value)
      else {
        throw WindowsGuestComputeServiceError.invalidFrame
      }
      return value
    }
    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
      guard count <= bytes.count - offset else {
        throw WindowsGuestComputeServiceError.invalidFrame
      }
      defer { offset += count }
      return bytes[offset..<(offset + count)]
    }
    func requireEnd() throws {
      guard offset == bytes.count else { throw WindowsGuestComputeServiceError.invalidFrame }
    }
  }
}
