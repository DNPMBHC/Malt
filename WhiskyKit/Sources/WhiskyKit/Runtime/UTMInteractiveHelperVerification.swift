// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import CryptoKit
import Foundation

protocol UTMGuestHelperFingerprinting: Sendable {
  func helperFingerprint(
    _ identifier: String, guestPath: String, until deadline: ContinuousClock.Instant
  ) async throws -> String?
}

extension UTMAppleScriptTransport: UTMGuestHelperFingerprinting {
  func helperFingerprint(
    _ identifier: String, guestPath: String, until deadline: ContinuousClock.Instant
  ) async throws -> String? {
    let result = try await UTMGuestCommandBridge.query(
      identifier,
      body: """
        if(Test-Path -LiteralPath $values[0]){
          @{exists=$true;sha256=(Get-FileHash -LiteralPath $values[0] -Algorithm SHA256).Hash.ToLowerInvariant()}
        }else{@{exists=$false}}
        """, arguments: [guestPath], until: deadline)
    guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
      let exists = object["exists"] as? Bool
    else { throw UTMGuestError.invalidResult }
    if !exists { return nil }
    guard let digest = object["sha256"] as? String,
      digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw UTMGuestError.invalidResult }
    return digest
  }
}

extension UTMHeadlessGuestTransport: UTMGuestHelperFingerprinting {
  func helperFingerprint(
    _ identifier: String, guestPath: String, until deadline: ContinuousClock.Instant
  ) async throws -> String? {
    guard let verifier = base as? any UTMGuestHelperFingerprinting else { return nil }
    return try await verifier.helperFingerprint(identifier, guestPath: guestPath, until: deadline)
  }
}

extension UTMWindowsGuestProvider {
  func ensureInteractiveHelper(
    _ helper: WindowsGuestInteractiveConfiguration, configuration config: RuntimeGuestConfiguration,
    until deadline: ContinuousClock.Instant
  ) async throws {
    let expected = SHA256.hash(data: try Data(contentsOf: helper.helperURL))
      .map { String(format: "%02x", $0) }.joined()
    let verifier = transport as? any UTMGuestHelperFingerprinting
    if let verifier {
      let current = try await verifier.helperFingerprint(
        config.identifier, guestPath: helper.guestHelperPath, until: deadline)
      if current == expected { return }
    }
    try await transport.pushCreatingParentDirectory(
      config.identifier, hostURL: helper.helperURL, guestPath: helper.guestHelperPath,
      until: deadline, pollInterval: pollInterval)
    if let verifier {
      let actual = try await verifier.helperFingerprint(
        config.identifier, guestPath: helper.guestHelperPath, until: deadline)
      guard actual == expected else { throw UTMGuestError.fileMappingUnavailable }
    }
  }
}
