// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import AppKit
import Foundation

/// A fresh nonce separates replies even when the VM frontend reuses a cached Guest PID.
enum UTMGuestCommandBridge {
  static func query(
    _ identifier: String, body: String, arguments: [String], until deadline: ContinuousClock.Instant
  ) async throws -> Data {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.utmapp.UTM") else {
      throw UTMGuestError.utmNotInstalled
    }
    let encodedArguments = try JSONEncoder().encode(arguments).base64EncodedString()
    for _ in 0..<3 {
      try Task.checkCancellation()
      let nonce = UUID().uuidString.lowercased()
      let script = """
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';
        $values=@([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encodedArguments)'))|ConvertFrom-Json);
        $value=& {\(body)};
        @{owner='@DNPMBHC';nonce='\(nonce)';value=$value}|ConvertTo-Json -Depth 8 -Compress
        """
      let encoded = Data(
        script.utf16.flatMap {
          [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
        }
      ).base64EncodedString()
      let result = try await UTMHostProcessRunner.run(
        executable: app.appendingPathComponent("Contents/MacOS/utmctl"),
        arguments: [
          "exec", "--hide", identifier, "--cmd",
          #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#,
          "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded
        ],
        until: deadline, maximumOutputBytes: 3 * 1024 * 1024)
      guard result.terminationReason == .exit, result.terminationStatus == 0 else {
        throw UTMGuestError.automationFailed
      }
      if let value = try matchedValue(result.standardOutput, nonce: nonce) { return value }
    }
    throw UTMGuestError.invalidResult
  }

  static func matchedValue(_ data: Data, nonce: String) throws -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["nonce"] as? String == nonce, object["owner"] as? String == "@DNPMBHC"
    else { return nil }
    guard let value = object["value"], JSONSerialization.isValidJSONObject(value) else {
      throw UTMGuestError.invalidResult
    }
    return try JSONSerialization.data(withJSONObject: value)
  }

  static func authenticatedOutput(
    _ identifier: String, executable: String, arguments: [String], until deadline: ContinuousClock.Instant
  ) async throws -> Data {
    guard arguments.count == 2, ["status", "cancel", "force-cancel"].contains(arguments[0]),
      UUID(uuidString: arguments[1]) != nil
    else { throw UTMGuestError.invalidArguments }
    let result = try await query(
      identifier, body: "& $values[0] $values[1] $values[2]|ConvertFrom-Json",
      arguments: [executable] + arguments, until: deadline)
    guard UTMAppleScriptTransport.capturedResponseMatches(result, requestID: arguments[1]) else {
      throw WindowsGuestInteractiveError.identityMismatch
    }
    return result
  }
}
