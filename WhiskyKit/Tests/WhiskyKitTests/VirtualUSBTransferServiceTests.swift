// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for Malt virtual USB ISO transfer service and guest zh-CN IME repair script.

import Foundation
import XCTest
@testable import WhiskyKit

final class VirtualUSBTransferServiceTests: XCTestCase {
    func testEnsureRemovableUSBSlotIsIdempotent() throws {
        let vmDir = FileManager.default.temporaryDirectory
            .appending(path: "malt-vusb-slot-\(UUID().uuidString).utm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vmDir) }

        let initialConfig: [String: Any] = [
            "Drive": [
                [
                    "Identifier": "DISK-1",
                    "ImageName": "win11.qcow2",
                    "ImageType": "Disk",
                    "Interface": "VirtIO",
                    "ReadOnly": false
                ]
            ]
        ]
        let configURL = vmDir.appending(path: "config.plist")
        let plistData = try PropertyListSerialization.data(fromPropertyList: initialConfig, format: .xml, options: 0)
        try plistData.write(to: configURL)

        XCTAssertFalse(VirtualUSBTransferService.hasRemovableUSBSlot(in: vmDir.path(percentEncoded: false)))
        let addedFirst = try VirtualUSBTransferService.ensureRemovableUSBSlot(in: vmDir.path(percentEncoded: false))
        XCTAssertTrue(addedFirst)
        XCTAssertTrue(VirtualUSBTransferService.hasRemovableUSBSlot(in: vmDir.path(percentEncoded: false)))

        let addedSecond = try VirtualUSBTransferService.ensureRemovableUSBSlot(in: vmDir.path(percentEncoded: false))
        XCTAssertFalse(addedSecond)
    }

    func testStageAndMountBuildsISOInContainerDataAndEjectCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "malt-vusb-stage-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let vmDir = root.appending(path: "test.utm", directoryHint: .isDirectory)
        let dataDir = vmDir.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config: [String: Any] = ["Drive": []]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            .write(to: vmDir.appending(path: "config.plist"))
        _ = try VirtualUSBTransferService.ensureRemovableUSBSlot(in: vmDir.path(percentEncoded: false))

        let sampleExe = root.appending(path: "SampleInstaller.exe")
        try Data(repeating: 0x5A, count: 4096).write(to: sampleExe)

        let receipt = try await VirtualUSBTransferService.stageAndMountFiles(
            [sampleExe],
            vmBundlePath: vmDir.path(percentEncoded: false),
            vmIdentifier: UUID().uuidString,
            isContainerRunning: true,
            commandRunner: { exe, args, _ in
                XCTAssertEqual(exe, "/usr/bin/hdiutil")
                if let outIdx = args.firstIndex(of: "-o"), outIdx + 1 < args.count {
                    try Data("MOCK_ISO_PAYLOAD".utf8).write(to: URL(filePath: args[outIdx + 1]))
                }
                return OrchestratorCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        XCTAssertEqual(receipt.fileNames, ["SampleInstaller.exe"])
        XCTAssertEqual(receipt.totalBytes, 4096)
        XCTAssertTrue(receipt.hasRemovableSlot)
        XCTAssertTrue(receipt.mountedLive)

        let finalISO = dataDir.appending(path: VirtualUSBTransferService.transferImageFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalISO.path(percentEncoded: false)))

        VirtualUSBTransferService.eject(
            vmBundlePath: vmDir.path(percentEncoded: false), vmIdentifier: UUID().uuidString
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalISO.path(percentEncoded: false)))
    }

    func testChineseIMERepairScriptTemporarilyStartsWindowsUpdateAndInstallsFOD() {
        let script = VirtualUSBTransferService.guestChineseIMERepairPowerShell()
        XCTAssertTrue(script.contains("Start-Service wuauserv"))
        XCTAssertTrue(script.contains("Language.Basic~~~zh-CN~0.0.1.0"))
        XCTAssertTrue(script.contains("Install-Language -Language zh-CN"))
        XCTAssertTrue(script.contains("ZH_CN_IME_REPAIR_INSTALLED"))
    }
}
