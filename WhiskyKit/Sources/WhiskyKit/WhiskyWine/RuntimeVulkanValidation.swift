// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC

import Foundation

/// Validates the exact Vulkan files before enabling the optional DXVK driver.
public enum RuntimeVulkanValidationState: String, Sendable {
  case verified
  case missing
  case unlocked
  case checksumMismatch
  case invalidPath
  case architectureMismatch
  case featureMismatch

  public var localizationKey: String { "runtime.vulkan.validation.\(rawValue)" }
}

public enum RuntimeVulkanValidator {
  public static func inspect(
    manifestURL: URL?,
    loaderURL: URL?,
    component: RuntimeComponentLock?
  ) -> RuntimeVulkanValidationState {
    guard let manifestURL, let loaderURL,
      let data = try? Data(contentsOf: manifestURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let icd = json["ICD"] as? [String: Any],
      let relativePath = icd["library_path"] as? String
    else { return .missing }
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return .invalidPath }
    let driverURL = manifestURL.deletingLastPathComponent()
      .appending(path: relativePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: driverURL.path) else { return .missing }
    guard let component, component.status == .locked,
      component.artifacts.count == 3
    else { return .unlocked }
    for url in [manifestURL, loaderURL, driverURL] {
      guard let artifact = component.artifacts.first(where: { $0.name == url.lastPathComponent }),
        let digest = try? RuntimeManifestVerifier.sha256Hex(forFileAt: url),
        artifact.acceptedSHA256s.contains(digest)
      else { return .checksumMismatch }
    }
    guard containsX86Slice(at: loaderURL), containsX86Slice(at: driverURL) else {
      return .architectureMismatch
    }
    guard
      Set(component.requiredVulkanFeatures ?? []).isSuperset(
        of: ["geometryShader", "fillModeNonSolid"]
      )
    else { return .featureMismatch }
    return .verified
  }

  /// Checks Mach-O headers directly so a native ARM UI validates its x86 Wine driver.
  public static func containsX86Slice(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4096), data.count >= 12 else { return false }
    let bytes = [UInt8](data)
    func word(_ offset: Int, little: Bool) -> UInt32 {
      guard offset + 4 <= bytes.count else { return 0 }
      let values = bytes[offset..<(offset + 4)]
      return (little ? Array(values.reversed()) : Array(values)).reduce(0) {
        ($0 << 8) | UInt32($1)
      }
    }
    let magic = word(0, little: false)
    if magic == 0xcffa_edfe || magic == 0xcefa_edfe {
      return word(4, little: true) == 0x0100_0007
    }
    if magic == 0xfeed_facf || magic == 0xfeed_face {
      return word(4, little: false) == 0x0100_0007
    }
    let little = magic == 0xbeba_feca || magic == 0xbfba_feca
    guard [0xcafe_babe, 0xcafe_babf, 0xbeba_feca, 0xbfba_feca].contains(magic) else { return false }
    let count = Int(word(4, little: little))
    let stride = magic == 0xcafe_babf || magic == 0xbfba_feca ? 32 : 20
    guard count > 0, count <= (bytes.count - 8) / stride else { return false }
    return (0..<count).contains { word(8 + $0 * stride, little: little) == 0x0100_0007 }
  }
}
