// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import CryptoKit
import Foundation
import XCTest

@testable import WhiskyKit

final class UTMInteractiveHelperVerificationTests: XCTestCase {
  private let config = RuntimeGuestConfiguration(
    identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", architecture: "arm64", fileMappings: [])

  func testCachedRunningReplyWithSameRootIDCannotPassFreshNonce() throws {
    let root = UUID().uuidString
    let response: [String: Any] = ["requestID": root, "state": "running"]
    let data = try JSONSerialization.data(withJSONObject: [
      "owner": "@DNPMBHC", "nonce": "old-query", "value": response
    ])
    XCTAssertTrue(
      UTMAppleScriptTransport.capturedResponseMatches(
        try JSONSerialization.data(withJSONObject: response), requestID: root))
    XCTAssertNil(try UTMGuestCommandBridge.matchedValue(data, nonce: "fresh-query"))
    XCTAssertNotNil(try UTMGuestCommandBridge.matchedValue(data, nonce: "old-query"))
  }

  func testCorrectNonceWithWrongOwnerOrInvalidBodyIsRejected() throws {
    let wrongOwner = try JSONSerialization.data(withJSONObject: [
      "owner": "publisher-x", "nonce": "query-a", "value": ["state": "exited"]
    ])
    XCTAssertNil(try UTMGuestCommandBridge.matchedValue(wrongOwner, nonce: "query-a"))
    let invalid = try JSONSerialization.data(withJSONObject: [
      "owner": "@DNPMBHC", "nonce": "query-a", "value": NSNull()
    ])
    XCTAssertThrowsError(try UTMGuestCommandBridge.matchedValue(invalid, nonce: "query-a"))
  }

  func testAlreadyRunningVerifiedHelperIsReusedWithoutWritingExecutable() async throws {
    try await withHelper { helper, digest in
      let transport = HelperFingerprintTransport(digest: digest, inUse: true)
      let provider = self.provider(transport)
      try await provider.ensureInteractiveHelper(helper, configuration: self.config, until: .now + .seconds(10))
      let writes = await transport.writes
      XCTAssertEqual(writes, 0)
    }
  }

  func testMissingHelperIsInstalledAndReadBack() async throws {
    try await withHelper { helper, _ in
      let transport = HelperFingerprintTransport(digest: nil)
      try await self.provider(transport).ensureInteractiveHelper(
        helper, configuration: self.config, until: .now + .seconds(10))
      let writes = await transport.writes
      let reads = await transport.reads
      XCTAssertEqual(writes, 1)
      XCTAssertEqual(reads, 2)
    }
  }

  func testCorruptedTransferCannotAuthorizeHelperExecution() async throws {
    try await withHelper { helper, _ in
      let transport = HelperFingerprintTransport(digest: nil, corruptTransfer: true)
      do {
        try await self.provider(transport).ensureInteractiveHelper(
          helper, configuration: self.config, until: .now + .seconds(10))
        XCTFail("Expected failed readback")
      } catch let error as UTMGuestError { XCTAssertEqual(error, .fileMappingUnavailable) }
    }
  }

  private func provider(_ transport: HelperFingerprintTransport) -> UTMWindowsGuestProvider {
    UTMWindowsGuestProvider(configuration: config, transport: transport)
  }

  private func withHelper(
    _ operation: (WindowsGuestInteractiveConfiguration, String) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".exe")
    let bytes = Data("verified-helper-test".utf8)
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try await operation(
      WindowsGuestInteractiveConfiguration(helperURL: url, guestHelperPath: #"C:\guest-shell-lab\helper.exe"#), digest)
  }
}

private actor HelperFingerprintTransport: UTMGuestTransport, UTMGuestHelperFingerprinting {
  var digest: String?
  let inUse: Bool
  let corruptTransfer: Bool
  private(set) var writes = 0
  private(set) var reads = 0

  init(digest: String?, inUse: Bool = false, corruptTransfer: Bool = false) {
    self.digest = digest
    self.inUse = inUse
    self.corruptTransfer = corruptTransfer
  }

  func helperFingerprint(
    _ identifier: String, guestPath: String, until deadline: ContinuousClock.Instant
  ) async throws -> String? {
    reads += 1
    return digest
  }

  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {
    if inUse { throw UTMGuestError.automationFailed }
    writes += 1
    digest =
      corruptTransfer
      ? String(repeating: "0", count: 64)
      : SHA256.hash(data: try Data(contentsOf: hostURL)).map { String(format: "%02x", $0) }.joined()
  }

  func inspect(_ identifier: String) async throws -> UTMVMSnapshot { throw UTMGuestError.automationFailed }
  func start(_ identifier: String) async throws { throw UTMGuestError.automationFailed }
  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 { throw UTMGuestError.automationFailed }
  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    throw UTMGuestError.automationFailed
  }
  func terminate(_ identifier: String, pid: Int32) async throws { throw UTMGuestError.automationFailed }
  func stop(_ identifier: String) async throws { throw UTMGuestError.automationFailed }
  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data { throw UTMGuestError.automationFailed }
}
