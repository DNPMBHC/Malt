// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum WindowsGuestExecutionMode: String, Sendable {
  case background
  case interactiveDesktop
}

/// Explicit desktop execution requires a separately built and reviewed guest helper.
public struct WindowsGuestInteractiveConfiguration: Sendable, Equatable {
  public let helperURL: URL
  public let guestHelperPath: String

  public init(helperURL: URL, guestHelperPath: String) {
    self.helperURL = helperURL
    self.guestHelperPath = guestHelperPath
  }
}

public struct WindowsGuestInteractiveProcessHandle: Sendable, Equatable {
  public let requestID: String
  public let controllerPID: Int32
  public let targetPID: Int32
  public let targetCreationTime: UInt64
  public let sessionID: UInt32
  public let helperGuestPath: String
}

public enum WindowsGuestInteractiveProcessState: String, Sendable, Decodable {
  case starting, running, exited, failed
}

public struct WindowsGuestInteractiveProcessSnapshot: Sendable, Equatable {
  public let requestID: String
  public let controllerPID: Int32
  public let targetPID: Int32
  public let targetCreationTime: UInt64
  public let sessionID: UInt32
  public let state: WindowsGuestInteractiveProcessState
  public let rootExited: Bool
  public let rootExitCode: Int32?
  public let activeProcessCount: UInt32
  public let cancelled: Bool
  public let exitCode: Int32?
  public let standardOutput: Data
  public let standardError: Data
  public let stdoutTruncated: Bool
  public let stderrTruncated: Bool
}

public enum WindowsGuestInteractiveError: LocalizedError, Sendable, Equatable {
  case invalidConfiguration
  case invalidRequest
  case requestTooLarge
  case invalidResponse
  case identityMismatch
  case desktopUnavailable
  case timedOut
  case cancellationFailed
  case helperFailure(code: String, win32Error: UInt32?)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The desktop helper configuration is invalid."
    case .invalidRequest: "The desktop execution request is invalid."
    case .requestTooLarge: "The desktop execution request exceeds the supported size."
    case .invalidResponse: "The desktop helper returned an invalid response."
    case .identityMismatch: "The desktop helper returned another execution's identity."
    case .desktopUnavailable: "An unlocked, logged-in Windows desktop is required."
    case .timedOut: "The desktop execution operation timed out."
    case .cancellationFailed: "The desktop target could not be cancelled."
    case .helperFailure: "The desktop helper reported a guest execution failure."
    }
  }
}

enum WindowsGuestInteractiveManifest {
  static let maximumBytes = 16 * 1024

  static func encode(
    executable: String, arguments: [String], environment: [String: String]
  ) throws -> String {
    guard !executable.isEmpty, !executable.contains("\0"), arguments.count <= 256,
      environment.count <= 256, arguments.allSatisfy({ !$0.contains("\0") })
    else { throw WindowsGuestInteractiveError.invalidRequest }
    var names = Set<String>()
    for (key, value) in environment {
      guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0"),
        names.insert(key.uppercased()).inserted
      else { throw WindowsGuestInteractiveError.invalidRequest }
    }
    var data = Data("MBD1".utf8)
    try append(executable, to: &data)
    append(UInt32(arguments.count), to: &data)
    for argument in arguments { try append(argument, to: &data) }
    append(UInt32(environment.count), to: &data)
    for key in environment.keys.sorted() {
      try append(key, to: &data)
      try append(environment[key] ?? "", to: &data)
    }
    guard data.count <= maximumBytes else { throw WindowsGuestInteractiveError.requestTooLarge }
    return data.base64EncodedString()
  }

  private static func append(_ value: String, to data: inout Data) throws {
    let bytes = Data(value.utf8)
    guard bytes.count <= maximumBytes, data.count + bytes.count + 4 <= maximumBytes else {
      throw WindowsGuestInteractiveError.requestTooLarge
    }
    append(UInt32(bytes.count), to: &data)
    data.append(bytes)
  }

  private static func append(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
}

struct WindowsGuestInteractiveResponse: Decodable {
  let schemaVersion: Int
  let requestID: String
  let controllerPID: Int32
  let targetPID: Int32
  let targetCreationTime: String
  let sessionID: UInt32
  let state: WindowsGuestInteractiveProcessState
  let rootExited: Bool
  let rootExitCode: Int64?
  let activeProcessCount: UInt32
  let cancelled: Bool
  let launchSuppressed: Bool?
  let exitCode: Int64?
  let stdoutBase64: String
  let stderrBase64: String
  let error: String?
  let win32Error: UInt32?
  let stdoutTruncated: Bool
  let stderrTruncated: Bool

  static let maximumOutputBytes = 1024 * 1024

  static func decode(_ data: Data, requestID: String) throws -> Self {
    guard data.count <= maximumOutputBytes * 3 else {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    let response: Self
    do { response = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    guard response.schemaVersion == 1 else { throw WindowsGuestInteractiveError.invalidResponse }
    guard response.requestID == requestID else {
      throw WindowsGuestInteractiveError.identityMismatch
    }
    guard UUID(uuidString: response.requestID) != nil else {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    return response
  }

  func snapshot(
    matching handle: WindowsGuestInteractiveProcessHandle? = nil
  ) throws -> WindowsGuestInteractiveProcessSnapshot {
    if state == .failed { try throwFailureError() }
    let creationTime = try validatedCreationTime(matching: handle)
    guard state != .exited || (rootExited && activeProcessCount == 0),
      state != .running || activeProcessCount > 0,
      rootExited == (rootExitCode != nil)
    else { throw WindowsGuestInteractiveError.invalidResponse }
    let codes = try validatedExitCodes()
    let stdout = try decodeBoundedOutput(stdoutBase64)
    let stderr = try decodeBoundedOutput(stderrBase64)
    return WindowsGuestInteractiveProcessSnapshot(
      requestID: requestID, controllerPID: controllerPID, targetPID: targetPID,
      targetCreationTime: creationTime, sessionID: sessionID, state: state,
      rootExited: rootExited, rootExitCode: codes.root, activeProcessCount: activeProcessCount,
      cancelled: cancelled, exitCode: codes.final, standardOutput: stdout,
      standardError: stderr, stdoutTruncated: stdoutTruncated, stderrTruncated: stderrTruncated)
  }

  private func throwFailureError() throws -> Never {
    let code = error ?? "executionFailed"
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    guard code.count <= 64, code.unicodeScalars.allSatisfy(allowed.contains) else {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    if ["desktopUnavailable", "noInteractiveSession", "desktopLocked"].contains(code) {
      throw WindowsGuestInteractiveError.desktopUnavailable
    }
    throw WindowsGuestInteractiveError.helperFailure(code: code, win32Error: win32Error)
  }

  private func validatedCreationTime(
    matching handle: WindowsGuestInteractiveProcessHandle?
  ) throws -> UInt64 {
    guard controllerPID > 0, targetPID > 0, sessionID > 0,
      let creationTime = UInt64(targetCreationTime), creationTime > 0,
      state == .running || state == .exited
    else { throw WindowsGuestInteractiveError.invalidResponse }
    if let handle {
      guard requestID == handle.requestID, controllerPID == handle.controllerPID,
        targetPID == handle.targetPID, creationTime == handle.targetCreationTime,
        sessionID == handle.sessionID
      else { throw WindowsGuestInteractiveError.identityMismatch }
    }
    return creationTime
  }

  private func validatedExitCodes() throws -> (root: Int32?, final: Int32?) {
    let root = try rootExitCode.map(Self.validatedStatusCode)
    let final: Int32?
    if let exitCode {
      guard state == .exited else { throw WindowsGuestInteractiveError.invalidResponse }
      final = try Self.validatedStatusCode(exitCode)
    } else {
      guard state != .exited else { throw WindowsGuestInteractiveError.invalidResponse }
      final = nil
    }
    guard state != .exited || (cancelled ? final == 1223 : final == root) else {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    return (root, final)
  }

  private static func validatedStatusCode(_ value: Int64) throws -> Int32 {
    guard value >= Int64(Int32.min), value <= Int64(UInt32.max) else {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    return Int32(bitPattern: UInt32(truncatingIfNeeded: value))
  }

  private func decodeBoundedOutput(_ base64: String) throws -> Data {
    guard let data = Data(base64Encoded: base64), data.count <= Self.maximumOutputBytes else {
      throw WindowsGuestInteractiveError.invalidResponse
    }
    return data
  }
}
