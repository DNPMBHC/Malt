// SPDX-License-Identifier: GPL-3.0-or-later
// High-speed virtual USB ISO transfer service and guest zh-CN IME dictionary repair helper.

import Foundation

/// Receipt returned after staging and mounting host files as a virtual USB media image.
public struct VirtualUSBTransferReceipt: Equatable, Sendable {
    public let fileNames: [String]
    public let totalBytes: Int64
    public let imageFileName: String
    public let hasRemovableSlot: Bool
    public let mountedLive: Bool
}

public enum VirtualUSBTransferError: LocalizedError, Equatable, Sendable {
    case noFilesSelected
    case unreadableSource(String)
    case missingContainerBundle
    case isoCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFilesSelected:
            return "请先拖入或选择至少一个需要传入容器的文件或文件夹。"
        case .unreadableSource(let name):
            return "无法读取文件「\(name)」，请检查文件权限后重试。"
        case .missingContainerBundle:
            return "尚未配置可游玩 Windows 容器，请先在「环境与存储」中导入或准备容器。"
        case .isoCreationFailed(let detail):
            return "生成模拟 USB 传输镜像失败：\(detail)"
        }
    }
}

/// Packages host installers/files into a local ISO inside VM Data/ and hot-swaps it into the removable USB slot.
public enum VirtualUSBTransferService {
    public static let transferNotificationName = Notification.Name("com.malt.virtualUsbTransfer")
    public static let transferImageFilename = "malt-usb-transfer.iso"
    public static let volumeLabel = "MALT_USB"

    public static func hasRemovableUSBSlot(
        in bundlePath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let configURL = URL(filePath: bundlePath).appending(path: "config.plist")
        guard let data = try? Data(contentsOf: configURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let drives = plist["Drive"] as? [[String: Any]] else {
            return false
        }
        return drives.contains(where: isRemovableUSBDrive)
    }

    /// Ensures stopped container config.plist contains one empty removable USB media slot.
    @discardableResult
    public static func ensureRemovableUSBSlot(
        in bundlePath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let configURL = URL(filePath: bundlePath).appending(path: "config.plist")
        guard fileManager.fileExists(atPath: configURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: configURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw VirtualUSBTransferError.missingContainerBundle
        }
        var drives = plist["Drive"] as? [[String: Any]] ?? []
        if drives.contains(where: isRemovableUSBDrive) {
            return false
        }
        drives.append([
            "Identifier": UUID().uuidString.uppercased(),
            "ImageType": "CD",
            "Interface": "USB",
            "InterfaceVersion": 1,
            "ReadOnly": true
        ])
        plist["Drive"] = drives
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: configURL, options: .atomic)
        return true
    }

    public static func stageAndMountFiles(
        _ sourceURLs: [URL],
        vmBundlePath: String,
        vmIdentifier: String,
        isContainerRunning: Bool,
        commandRunner: UnifiedRuntimeOrchestrator.CommandRunner? = nil,
        fileManager: FileManager = .default
    ) async throws -> VirtualUSBTransferReceipt {
        let validURLs = sourceURLs.filter { !$0.path(percentEncoded: false).isEmpty }
        guard !validURLs.isEmpty else { throw VirtualUSBTransferError.noFilesSelected }
        let dataDir = URL(filePath: vmBundlePath).appending(path: "Data", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: dataDir.path(percentEncoded: false)) else {
            throw VirtualUSBTransferError.missingContainerBundle
        }

        let stagingDir = fileManager.temporaryDirectory
            .appending(path: "malt-usb-stage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tempISO = fileManager.temporaryDirectory
            .appending(path: "malt-usb-\(UUID().uuidString).iso")
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingDir)
            try? fileManager.removeItem(at: tempISO)
        }

        let (fileNames, totalBytes) = try stageItems(validURLs, into: stagingDir, fileManager: fileManager)

        let runner = commandRunner ?? { exe, args, env in
            try await OrchestratorProcessRunner.run(executable: exe, arguments: args, environment: env)
        }
        let result = try await runner(
            "/usr/bin/hdiutil",
            [
                "makehybrid", "-iso", "-joliet",
                "-default-volume-name", volumeLabel,
                "-o", tempISO.path(percentEncoded: false),
                stagingDir.path(percentEncoded: false)
            ],
            ["__DEMOAPP_TIMEOUT_SECONDS": "120"]
        )
        guard result.exitCode == 0,
              fileManager.fileExists(atPath: tempISO.path(percentEncoded: false)) else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VirtualUSBTransferError.isoCreationFailed(reason.isEmpty ? "hdiutil 退出码 \(result.exitCode)" : reason)
        }

        let finalISO = dataDir.appending(path: transferImageFilename)
        if fileManager.fileExists(atPath: finalISO.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: finalISO)
        }
        try fileManager.moveItem(at: tempISO, to: finalISO)

        let hasSlot = hasRemovableUSBSlot(in: vmBundlePath, fileManager: fileManager)
        if isContainerRunning && hasSlot {
            postTransferNotification(payload: "mount|\(vmIdentifier)|\(transferImageFilename)")
        }
        return VirtualUSBTransferReceipt(
            fileNames: fileNames,
            totalBytes: totalBytes,
            imageFileName: transferImageFilename,
            hasRemovableSlot: hasSlot,
            mountedLive: isContainerRunning && hasSlot
        )
    }

    private static func stageItems(
        _ sourceURLs: [URL],
        into stagingDir: URL,
        fileManager: FileManager
    ) throws -> ([String], Int64) {
        var fileNames: [String] = []
        var totalBytes: Int64 = 0
        for source in sourceURLs {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let srcPath = source.path(percentEncoded: false)
            guard fileManager.isReadableFile(atPath: srcPath) else {
                throw VirtualUSBTransferError.unreadableSource(source.lastPathComponent)
            }
            let target = uniqueDestination(named: source.lastPathComponent, in: stagingDir, fileManager: fileManager)
            try copyOrLinkItem(from: source, to: target, fileManager: fileManager)
            fileNames.append(target.lastPathComponent)
            totalBytes += itemByteSize(at: source, fileManager: fileManager)
        }
        return (fileNames, totalBytes)
    }

    public static func eject(
        vmBundlePath: String,
        vmIdentifier: String,
        fileManager: FileManager = .default
    ) {
        postTransferNotification(payload: "eject|\(vmIdentifier)")
        let isoURL = URL(filePath: vmBundlePath)
            .appending(path: "Data", directoryHint: .isDirectory)
            .appending(path: transferImageFilename)
        if fileManager.fileExists(atPath: isoURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: isoURL)
        }
    }

    public static func postTransferNotification(payload: String) {
        DistributedNotificationCenter.default().postNotificationName(
            transferNotificationName,
            object: payload,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Temporarily enables wuauserv to install zh-CN IME dictionaries & pack, then restores pause.
    public static func guestChineseIMERepairPowerShell() -> String {
        """
        $ErrorActionPreference='Continue';
        $origWu=(Get-Service wuauserv -ErrorAction SilentlyContinue).StartType;
        Set-Service wuauserv -StartupType Manual -ErrorAction SilentlyContinue;
        Start-Service wuauserv -ErrorAction SilentlyContinue;
        Start-Service UsoSvc -ErrorAction SilentlyContinue;
        Add-WindowsCapability -Online -Name 'Language.Basic~~~zh-CN~0.0.1.0' | Out-Null;
        Install-Language -Language zh-CN -CopyToSettings -ErrorAction SilentlyContinue | Out-Null;
        $state=(Get-WindowsCapability -Online -Name 'Language.Basic~~~zh-CN~0.0.1.0').State;
        if ($state -eq 'Installed') {
          Set-WinUILanguageOverride -Language zh-CN -ErrorAction SilentlyContinue;
          Set-WinSystemLocale -SystemLocale zh-CN -ErrorAction SilentlyContinue;
          Write-Output 'ZH_CN_IME_REPAIR_INSTALLED';
        } else {
          Write-Output ('ZH_CN_IME_REPAIR_STATE=' + $state);
        };
        if ($origWu -eq 'Disabled') {
          Stop-Service wuauserv -Force -ErrorAction SilentlyContinue;
        }
        """
    }

    private static func isRemovableUSBDrive(_ drive: [String: Any]) -> Bool {
        let imageType = (drive["ImageType"] as? String ?? "").lowercased()
        let iface = (drive["Interface"] as? String ?? "").lowercased()
        let imageName = (drive["ImageName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return imageType == "cd" && iface == "usb" && imageName.isEmpty
    }

    private static func uniqueDestination(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let initial = directory.appending(path: name)
        if !fileManager.fileExists(atPath: initial.path(percentEncoded: false)) {
            return initial
        }
        let stem = initial.deletingPathExtension().lastPathComponent
        let ext = initial.pathExtension
        for index in 2...99 {
            let candidateName = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
            let candidate = directory.appending(path: candidateName)
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return directory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    private static func copyOrLinkItem(from source: URL, to destination: URL, fileManager: FileManager) throws {
        do {
            try fileManager.linkItem(at: source, to: destination)
        } catch {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func itemByteSize(at url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory != true {
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var sum: Int64 = 0
        for case let fileURL as URL in enumerator {
            let fileValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if fileValues?.isRegularFile == true {
                sum += Int64(fileValues?.fileSize ?? 0)
            }
        }
        return sum
    }
}
