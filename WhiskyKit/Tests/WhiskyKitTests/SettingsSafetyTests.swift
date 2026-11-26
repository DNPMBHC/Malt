// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WhiskyKit

final class SettingsSafetyTests: XCTestCase {
    func testDPIMissingOrInvalidStoredValueUses96WithoutAWrite() throws {
        XCTAssertEqual(WineDPIConfigurationPolicy.loadedDPI(nil), 96)
        XCTAssertEqual(WineDPIConfigurationPolicy.loadedDPI(0), 96)
        XCTAssertEqual(WineDPIConfigurationPolicy.loadedDPI(-1), 96)
        XCTAssertEqual(WineDPIConfigurationPolicy.loadedDPI(120), 120)
        XCTAssertEqual(WineDPIConfigurationPolicy.loadedDPI(480), 480)
    }

    func testDPIRejectsNonFiniteFractionalAndOutOfRangeInputBeforeConversion() throws {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 95, 96.5, 481, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try WineDPIConfigurationPolicy.validatedDPI(value)) { error in
                XCTAssertEqual(error as? WineDPIConfigurationError, .invalidDPI)
            }
        }
        for value in [Int.min, -1, 0, 95, 481, Int.max] {
            XCTAssertThrowsError(try WineDPIConfigurationPolicy.validatedDPI(value))
        }
        XCTAssertEqual(try WineDPIConfigurationPolicy.validatedDPI(144.0), 144)
        XCTAssertEqual(try WineDPIConfigurationPolicy.validatedDPI(96), 96)
        XCTAssertEqual(try WineDPIConfigurationPolicy.validatedDPI(480), 480)
    }

    func testCacheInventoryMeasuresAndClearsTheSameSharedAndBottleCachesIncludingHiddenFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ShaderCacheService()
        let bottle = root.appending(path: "bottle")
        let targets = service.targets(bottleURLs: [bottle, bottle],
                                      cachesDirectory: root.appending(path: "shared"),
                                      darwinCacheDirectory: root.appending(path: "darwin"))
        XCTAssertEqual(targets.count, 4)
        for (index, target) in targets.enumerated() {
            try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: index + 3).write(to: target.url.appending(path: ".cache"))
        }
        let before = service.measure(targets: targets + [targets[0]])
        XCTAssertEqual(before.byteCount, 18)
        XCTAssertTrue(before.failures.isEmpty)
        let result = service.clear(targets: targets) { .idle }
        XCTAssertFalse(result.wasBlocked)
        XCTAssertEqual(result.removedCount, 4)
        XCTAssertEqual(result.removedBytes, before.byteCount)
        XCTAssertTrue(result.failures.isEmpty)
        let after = service.measure(targets: targets)
        XCTAssertEqual(after.byteCount, 0)
        XCTAssertTrue(after.failures.isEmpty)
    }

    func testActiveOrUnknownActivityNeverDeletesCache() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ShaderCacheTarget(label: "测试缓存", url: root.appending(path: "cache"))
        try Data([1, 2, 3]).write(to: target.url)
        for activity: ShaderCacheActivityState in [.active, .unknown] {
            let result = ShaderCacheService().clear(targets: [target]) { activity }
            XCTAssertTrue(result.wasBlocked)
            XCTAssertEqual(result.removedCount, 0)
            XCTAssertEqual(try Data(contentsOf: target.url), Data([1, 2, 3]))
        }
    }

    func testCleanupStopsBeforeNextTargetWhenActivityChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = ["one", "two"].map { ShaderCacheTarget(label: $0, url: root.appending(path: $0)) }
        for target in targets { try Data([1]).write(to: target.url) }
        var checks = 0
        let result = ShaderCacheService().clear(targets: targets) {
            checks += 1
            return checks < 3 ? .idle : .active
        }
        XCTAssertTrue(result.wasBlocked)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets[1].url.path))
    }

    func testSymlinkTargetsReportPartialFailureAndNeverDeleteExternalContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appending(path: "external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: external.appending(path: "preserved"))
        let linked = root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        let managed = root.appending(path: "managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data([1]).write(to: managed.appending(path: "cache"))
        try FileManager.default.createSymbolicLink(
            at: managed.appending(path: "nested-link"), withDestinationURL: external
        )
        let targets = [ShaderCacheTarget(label: "正常缓存", url: managed), ShaderCacheTarget(label: "跳过缓存", url: linked)]
        let service = ShaderCacheService()
        XCTAssertEqual(service.measure(targets: targets).byteCount, 1)
        let result = service.clear(targets: targets) { .idle }
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(result.failures[0].message.contains(root.path))
        XCTAssertEqual(try Data(contentsOf: external.appending(path: "preserved")), Data([7, 8, 9]))
    }

    func testActivityProbeRecognizesNativeAndContainerProcessesAndFailsClosedOnEmptySnapshot() {
        XCTAssertEqual(ShaderCacheService.classifyProcessSnapshot(""), .unknown)
        XCTAssertEqual(ShaderCacheService.classifyProcessSnapshot("  \n"), .unknown)
        XCTAssertEqual(ShaderCacheService.classifyProcessSnapshot("/sbin/launchd\n/usr/bin/login"), .idle)
        let commands = [
            "/tmp/wineserver", "/tmp/wine64-preloader", "/tmp/qemu-system-aarch64", "/tmp/UTM", "C:\\game.exe"
        ]
        for command in commands {
            XCTAssertEqual(ShaderCacheService.classifyProcessSnapshot(command), .active)
        }
        XCTAssertEqual(
            ShaderCacheService.classifyProcessSnapshot("/tmp/demo-helper", additionalExecutableNames: ["demo-helper"]),
            .active
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "settings-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
