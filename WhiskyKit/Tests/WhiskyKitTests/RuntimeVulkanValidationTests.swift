// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC

import XCTest

@testable import WhiskyKit

final class RuntimeVulkanValidationTests: XCTestCase {
  func testLockedDriverAndRelativeManifestSurviveBundleMove() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appending(path: "demo-app.app")
    let fixture = try makeFixture(app: app)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: fixture.icd, loaderURL: fixture.loader, component: fixture.lock
      ), .verified)
    let moved = root.appending(path: "moved/demo-app.app")
    try FileManager.default.createDirectory(
      at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: app, to: moved)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: moved.appending(path: "Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json"),
        loaderURL: moved.appending(path: "Contents/Frameworks/libvulkan.1.dylib"),
        component: fixture.lock
      ), .verified)
  }

  func testTamperingAndMissingLockAreRejected() throws {
    let app = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: app) }
    let fixture = try makeFixture(app: app)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: fixture.icd, loaderURL: fixture.loader, component: nil
      ), .unlocked)
    try Data("tampered".utf8).write(to: fixture.driver)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: fixture.icd, loaderURL: fixture.loader, component: fixture.lock
      ), .checksumMismatch)
    try FileManager.default.removeItem(at: fixture.driver)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: fixture.icd, loaderURL: fixture.loader, component: fixture.lock
      ), .missing)
  }

  func testArmOnlyDriverAndAbsoluteICDAreRejected() throws {
    let app = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: app) }
    let fixture = try makeFixture(app: app, cpu: 0x0100_000c)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: fixture.icd, loaderURL: fixture.loader, component: fixture.lock
      ), .architectureMismatch)
    try Data(#"{"ICD":{"library_path":"/invalid/libvulkan.dylib"}}"#.utf8).write(to: fixture.icd)
    XCTAssertEqual(
      RuntimeVulkanValidator.inspect(
        manifestURL: fixture.icd, loaderURL: fixture.loader, component: fixture.lock
      ), .invalidPath)
  }

  private struct Fixture {
    let icd: URL
    let loader: URL
    let driver: URL
    let lock: RuntimeComponentLock
  }

  private func makeFixture(
    app: URL, cpu: UInt32 = 0x0100_0007
  ) throws -> Fixture {
    let frameworks = app.appending(path: "Contents/Frameworks")
    let icd = app.appending(path: "Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json")
    try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: icd.deletingLastPathComponent(), withIntermediateDirectories: true)
    let loader = frameworks.appending(path: "libvulkan.1.dylib")
    let driver = frameworks.appending(path: "libvulkan_kosmickrisp.dylib")
    var header = [UInt32(0xfeed_facf).littleEndian, cpu.littleEndian, 0, 0]
    let bytes = header.withUnsafeMutableBytes { Data($0) }
    try bytes.write(to: loader)
    try bytes.write(to: driver)
    let json = #"{"ICD":{"library_path":"../../../Frameworks/libvulkan_kosmickrisp.dylib"}}"#
    try Data(json.utf8).write(to: icd)
    let artifacts = try [loader, driver, icd].map {
      RuntimeLockedArtifact(
        name: $0.lastPathComponent, relativePath: $0.lastPathComponent,
        sha256: try RuntimeManifestVerifier.sha256Hex(forFileAt: $0))
    }
    let lock = RuntimeComponentLock(
      id: "kosmicKrisp", displayName: "module-x", version: "test", status: .locked,
      supportedAPIs: "Vulkan", artifacts: artifacts,
      requiredVulkanFeatures: ["geometryShader", "fillModeNonSolid"]
    )
    return Fixture(icd: icd, loader: loader, driver: driver, lock: lock)
  }
}
