// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

final class RuntimeManifestTests: XCTestCase {
    func testBundledManifestDecodesAllFiveLockedComponentsIncludingKosmicKrisp() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WhiskyKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WhiskyKit
            .deletingLastPathComponent() // Whisky
            .appending(path: "Whisky/Resources/runtime-manifest.json")

        let manifest = try RuntimeManifest.load(fromFileURL: manifestURL)
        XCTAssertEqual(manifest.schemaVersion, "1.1.0")
        XCTAssertEqual(manifest.owner, "@DNPMBHC")

        let byID = Dictionary(uniqueKeysWithValues: manifest.components.map { ($0.id, $0) })
        XCTAssertEqual(byID["wine"]?.status, .locked)
        XCTAssertEqual(byID["dxmt"]?.status, .locked)
        XCTAssertEqual(byID["d3dMetal"]?.status, .locked)
        XCTAssertEqual(byID["dxvk"]?.status, .locked)
        XCTAssertEqual(byID["kosmicKrisp"]?.status, .locked)
        XCTAssertEqual(byID["dxmt"]?.artifacts.count, 4)
        XCTAssertEqual(byID["d3dMetal"]?.artifacts.count, 3)
        XCTAssertEqual(byID["dxvk"]?.artifacts.count, 2)
        XCTAssertEqual(byID["kosmicKrisp"]?.artifacts.count, 3)
    }

    func testManifestVerifierResolvesContentsBundleRelativeArtifactsAndAlternateSHA256() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-bundle-manifest-\(UUID().uuidString)")
        let fakeApp = root.appending(path: "Sample.app")
        let fakeLibs = root.appending(path: "Libraries")
        try FileManager.default.createDirectory(
            at: fakeApp.appending(path: "Contents/Resources/vulkan/icd.d"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let icdFile = fakeApp.appending(path: "Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json")
        try Data(
            "{\"ICD\":{\"library_path\":\"../../../Frameworks/libvulkan_kosmickrisp.dylib\"}}".utf8
        ).write(to: icdFile)
        let icdSHA = try RuntimeManifestVerifier.sha256Hex(forFileAt: icdFile)

        let manifest = RuntimeManifest(
            schemaVersion: "1.1.0",
            owner: "@DNPMBHC",
            capturedAt: "2026-11-23T00:00:00Z",
            baselineSource: "unit-test",
            components: [
                RuntimeComponentLock(
                    id: "kosmicKrisp", displayName: "KosmicKrisp", version: "mesa-27",
                    status: .locked, supportedAPIs: "Vulkan 1.4",
                    artifacts: [
                        RuntimeLockedArtifact(
                            name: "kosmickrisp_icd.json",
                            relativePath: "Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json",
                            sha256: String(repeating: "0", count: 64),
                            alternateSHA256s: [icdSHA]
                        )
                    ]
                )
            ]
        )

        let report = RuntimeManifestVerifier.verify(manifest: manifest, in: fakeLibs, appBundleURL: fakeApp)
        XCTAssertTrue(report.allLockedComponentsVerified)
        XCTAssertEqual(report.components.first?.state, .verified)
    }

    func testManifestVerifierDistinguishesVerifiedMismatchMissingAndReserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-manifest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let goodFile = root.appending(path: "DXMT/wine/x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(at: goodFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("good-dxmt-bytes".utf8).write(to: goodFile)
        let goodSHA = try RuntimeManifestVerifier.sha256Hex(forFileAt: goodFile)

        let tamperedFile = root.appending(path: "DXVK/wine/x86_64-windows/d3d11.dll")
        try FileManager.default.createDirectory(at: tamperedFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("tampered-dxvk".utf8).write(to: tamperedFile)

        let manifest = Self.makeSampleManifest(goodDXMTSHA: goodSHA)
        let report = RuntimeManifestVerifier.verify(manifest: manifest, in: root)
        let byID = Dictionary(uniqueKeysWithValues: report.components.map { ($0.id, $0) })
        XCTAssertEqual(byID["dxmt"]?.state, .verified)
        XCTAssertEqual(byID["dxvk"]?.state, .mismatch)
        XCTAssertEqual(byID["d3dMetal"]?.state, .missing)
        XCTAssertEqual(byID["kosmicKrisp"]?.state, .reserved)
        XCTAssertTrue(report.hasMismatch)
        XCTAssertFalse(report.allLockedComponentsVerified)
    }

    private static func makeSampleManifest(goodDXMTSHA: String) -> RuntimeManifest {
        RuntimeManifest(
            schemaVersion: "1.0.0",
            owner: "@DNPMBHC",
            capturedAt: "2026-11-23T00:00:00Z",
            baselineSource: "unit-test",
            components: [
                RuntimeComponentLock(
                    id: "dxmt", displayName: "DXMT", version: "v0.80", status: .locked, supportedAPIs: "D3D11",
                    artifacts: [
                        RuntimeLockedArtifact(
                            name: "winemetal.so", relativePath: "DXMT/wine/x86_64-unix/winemetal.so",
                            sha256: goodDXMTSHA
                        )
                    ]
                ),
                RuntimeComponentLock(
                    id: "dxvk", displayName: "DXVK", version: "1.10.3", status: .locked, supportedAPIs: "D3D11",
                    artifacts: [
                        RuntimeLockedArtifact(
                            name: "d3d11.dll", relativePath: "DXVK/x64/d3d11.dll",
                            alternateRelativePaths: ["DXVK/wine/x86_64-windows/d3d11.dll"],
                            sha256: String(repeating: "a", count: 64)
                        )
                    ]
                ),
                RuntimeComponentLock(
                    id: "d3dMetal", displayName: "D3DMetal", version: "GPTK 4.0-1", status: .locked,
                    supportedAPIs: "D3D12",
                    artifacts: [
                        RuntimeLockedArtifact(
                            name: "libd3dshared.dylib", relativePath: "Wine/lib/external/libd3dshared.dylib",
                            sha256: String(repeating: "b", count: 64)
                        )
                    ]
                ),
                RuntimeComponentLock(
                    id: "kosmicKrisp", displayName: "KosmicKrisp", version: "reserved", status: .reserved,
                    supportedAPIs: "Vulkan 1.4", artifacts: []
                )
            ]
        )
    }

    func testCustomRuntimeLocationResolvesExternalPathAndEnvironmentOverride() {
        let suiteName = "whisky-runtime-loc-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let externalRoot = URL(fileURLWithPath: "/Volumes/ExternalTest/RuntimeRoot", isDirectory: true)
        WhiskyWineInstaller.setCustomRuntimeLocation(externalRoot, userDefaults: defaults)
        XCTAssertTrue(WhiskyWineInstaller.isUsingCustomRuntimeLocation(userDefaults: defaults))
        XCTAssertEqual(
            WhiskyWineInstaller.resolveApplicationFolder(environment: [:], userDefaults: defaults),
            externalRoot.standardizedFileURL
        )

        let envOverride = "/tmp/env-override-runtime"
        XCTAssertEqual(
            WhiskyWineInstaller.resolveApplicationFolder(
                environment: [WhiskyWineInstaller.runtimeLocationEnvironmentKey: envOverride],
                userDefaults: defaults
            ),
            URL(fileURLWithPath: envOverride, isDirectory: true).standardizedFileURL
        )

        WhiskyWineInstaller.setCustomRuntimeLocation(nil, userDefaults: defaults)
        XCTAssertFalse(WhiskyWineInstaller.isUsingCustomRuntimeLocation(userDefaults: defaults))
        XCTAssertEqual(
            WhiskyWineInstaller.resolveApplicationFolder(environment: [:], userDefaults: defaults),
            WhiskyWineInstaller.defaultApplicationFolder
        )
    }
}
