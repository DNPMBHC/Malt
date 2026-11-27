// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class ManagedContainerRegistryTests: XCTestCase {
    private var tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appending(path: "malt-registry-tests-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "malt-registry-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testMultiContainerRegisterSwitchAndFallbackOnRemoval() async throws {
        let selectionURL = tempDir.appending(path: "RuntimeSelection/selected-container.json")
        let vm1 = try makeManagedBundle(name: "malt-v1.utm")
        let vm2 = try makeManagedBundle(name: "malt-v2.utm")
        let path1 = vm1.path(percentEncoded: false)
        let path2 = vm2.path(percentEncoded: false)

        _ = try ManagedContainerRegistry.select(bundlePath: path1, selectionURL: selectionURL, fileManager: .default)
        _ = try ManagedContainerRegistry.select(bundlePath: path2, selectionURL: selectionURL, fileManager: .default)

        let items = ManagedContainerRegistry.listItems(selectionURL: selectionURL, fileManager: .default)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.bundlePath, path2)
        XCTAssertEqual(items.first?.isActive, true)

        let next = try await ManagedContainerRegistry.remove(
            bundlePath: path2,
            deleteFilesOnDisk: false,
            selectionURL: selectionURL,
            fileManager: .default,
            commandRunner: { _, _, _ in OrchestratorCommandResult(exitCode: 1) }
        )
        XCTAssertEqual(next, path1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path2))

        let afterItems = ManagedContainerRegistry.listItems(selectionURL: selectionURL, fileManager: .default)
        XCTAssertEqual(afterItems.count, 1)
        XCTAssertEqual(afterItems.first?.bundlePath, path1)
        XCTAssertEqual(afterItems.first?.isActive, true)
    }

    func testDeleteFromDiskRemovesStoppedBundleAndBlocksRunningOrProtected() async throws {
        let selectionURL = tempDir.appending(path: "RuntimeSelection/selected-container.json")
        let vm1 = try makeManagedBundle(name: "malt-deletable.utm")
        let golden = try makeManagedBundle(name: "golden-win11-arm64-v1.utm")
        let path1 = vm1.path(percentEncoded: false)
        _ = try ManagedContainerRegistry.select(bundlePath: path1, selectionURL: selectionURL, fileManager: .default)

        // Running container must be rejected
        do {
            _ = try await ManagedContainerRegistry.remove(
                bundlePath: path1, deleteFilesOnDisk: true, selectionURL: selectionURL,
                fileManager: .default, commandRunner: { _, _, _ in OrchestratorCommandResult(exitCode: 0) }
            )
            XCTFail("Expected running container deletion to be rejected")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path1))
        }

        // Protected golden master must be rejected
        do {
            _ = try await ManagedContainerRegistry.remove(
                bundlePath: golden.path(percentEncoded: false), deleteFilesOnDisk: true, selectionURL: selectionURL,
                fileManager: .default, commandRunner: { _, _, _ in OrchestratorCommandResult(exitCode: 1) }
            )
            XCTFail("Expected protected golden deletion to be rejected")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: golden.path(percentEncoded: false)))
        }

        // Stopped managed container deletes cleanly
        let next = try await ManagedContainerRegistry.remove(
            bundlePath: path1, deleteFilesOnDisk: true, selectionURL: selectionURL,
            fileManager: .default, commandRunner: { _, _, _ in OrchestratorCommandResult(exitCode: 1) }
        )
        XCTAssertNil(next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path1))
    }

    private func makeManagedBundle(name: String) throws -> URL {
        let bundle = tempDir.appending(path: name)
        try FileManager.default.createDirectory(at: bundle.appending(path: "Data"), withIntermediateDirectories: true)
        let uuid = UUID().uuidString.uppercased()
        let config: [String: Any] = [
            "Backend": "QEMU",
            "Information": ["Name": name, "UUID": uuid],
            "System": ["UEFIBoot": true, "CPUCount": 6, "MemorySize": 8192],
            "Drive": [["Identifier": "SYS", "ImageName": "disk.qcow2", "ImageType": "Disk", "ReadOnly": false]]
        ]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            .write(to: bundle.appending(path: "config.plist"))
        try ContainerAutoDeployConfigBuilder.writePlayableMetadata(
            vmUUID: uuid, bundleURL: bundle, fileManager: .default
        )
        return bundle
    }
}
