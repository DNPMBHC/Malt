// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import Virtualization

public struct SecureBootReport: Encodable {
    public let owner: String
    public let defaultSignaturesEnrolled: Bool
    public let enabled: Bool
    public let persistedEnabled: Bool
    public let keyExchangeKeys: Int
    public let allowedSignatures: Int
    public let forbiddenSignatures: Int
    public let errorDomain: String?
    public let errorCode: Int?
    public let windowsBootTested = false
}

@available(macOS 27.0, *)
public enum SecureBootProbe {
    public static func run() -> SecureBootReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("nvram")
            let store = try VZEFIVariableStore(creatingVariableStoreAt: url)
            try store.enrollDefaultSecureBootSignatures()
            try store.enableSecureBootUsingDefaultPlatformKey()
            let enabled = try store.isSecureBootEnabled
            let signatures = try store.enrolledSecureBootSignatures
            let restored = VZEFIVariableStore(url: url)
            return SecureBootReport(owner: "@DNPMBHC", defaultSignaturesEnrolled: true, enabled: enabled,
                persistedEnabled: try restored.isSecureBootEnabled, keyExchangeKeys: signatures.keyExchangeKeys.count,
                allowedSignatures: signatures.dbSignatures.count, forbiddenSignatures: signatures.dbxSignatures.count,
                errorDomain: nil, errorCode: nil)
        } catch {
            let native = error as NSError
            return SecureBootReport(owner: "@DNPMBHC", defaultSignaturesEnrolled: false, enabled: false,
                persistedEnabled: false, keyExchangeKeys: 0, allowedSignatures: 0, forbiddenSignatures: 0,
                errorDomain: native.domain, errorCode: native.code)
        }
    }
}
