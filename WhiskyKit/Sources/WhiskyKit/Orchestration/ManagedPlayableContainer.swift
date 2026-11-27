// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit stopped-container import and private selection persistence.

import Darwin
import Foundation

/// A user-selected container verified by the management transaction and local metadata.
public struct ImportedPlayableContainer: Equatable, Sendable {
  public let bundlePath: String
  public let vmIdentifier: String
  public let alreadyManaged: Bool
}

struct PlayableContainerSelection: Codable {
  let schemaVersion: Int
  let bundlePath: String
  let vmIdentifier: String

  static func defaultStorageURL(fileManager: FileManager) -> URL {
    UnifiedGameLibraryStore.defaultStorageURL(fileManager: fileManager)
      .deletingLastPathComponent().appending(path: "RuntimeSelection/selected-container.json")
  }

  static func load(from storageURL: URL, fileManager: FileManager) -> String? {
    guard privateRegularFile(storageURL, fileManager: fileManager),
      privateDirectory(storageURL.deletingLastPathComponent(), fileManager: fileManager),
      let data = try? Data(contentsOf: storageURL),
      let selection = try? JSONDecoder().decode(Self.self, from: data),
      selection.schemaVersion == 1, selection.bundlePath.hasPrefix("/"),
      let expectedID = UUID(uuidString: selection.vmIdentifier),
      let verifiedID = verifiedIdentifier(at: URL(filePath: selection.bundlePath), fileManager: fileManager),
      verifiedID == expectedID
    else { return nil }
    return selection.bundlePath
  }

  static func verifiedIdentifier(at url: URL, fileManager: FileManager) -> UUID? {
    let path = url.path(percentEncoded: false)
    let config = url.appending(path: "config.plist")
    let marker = url.appending(path: ".playable-meta.json")
    guard url.isFileURL, url == url.standardizedFileURL,
      !path.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
      UnifiedRuntimeDiscovery.isUsablePlayableVMBundle(path, fileManager: fileManager),
      (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory,
      !hasSymbolicLinkComponent(url, fileManager: fileManager),
      ownedWritableConfiguration(config, fileManager: fileManager),
      privateRegularFile(marker, fileManager: fileManager),
      let data = try? Data(contentsOf: marker),
      let metadata = try? JSONDecoder().decode(PlayableContainerMetadata.self, from: data),
      metadata.schemaVersion == 1, metadata.role == "playable_working_vm",
      let markerUUID = UUID(uuidString: metadata.vmUUID),
      let configID = try? ContainerGuestDispatcher.vmIdentifier(bundlePath: path),
      UUID(uuidString: configID) == markerUUID
    else { return nil }
    return markerUUID
  }

  func save(to storageURL: URL, fileManager: FileManager) throws {
    let parent = storageURL.deletingLastPathComponent()
    if fileManager.fileExists(atPath: parent.path) {
      guard (try fileManager.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType)
        == .typeDirectory
      else { throw CocoaError(.fileWriteNoPermission) }
    } else {
      try fileManager.createDirectory(
        at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    if fileManager.fileExists(atPath: storageURL.path) {
      guard Self.privateRegularFile(storageURL, fileManager: fileManager) else {
        throw CocoaError(.fileWriteNoPermission)
      }
    }
    let data = try JSONEncoder().encode(self)
    try data.write(to: storageURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
  }

  private static func privateRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
    guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
      attrs[.type] as? FileAttributeType == .typeRegular,
      (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
      (attrs[.referenceCount] as? NSNumber)?.intValue == 1,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { return false }
    return true
  }

  private static func ownedWritableConfiguration(_ url: URL, fileManager: FileManager) -> Bool {
    guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
      attrs[.type] as? FileAttributeType == .typeRegular,
      (attrs[.referenceCount] as? NSNumber)?.intValue == 1,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue,
      permissions & 0o200 != 0
    else { return false }
    return true
  }

  private static func hasSymbolicLinkComponent(_ url: URL, fileManager: FileManager) -> Bool {
    var component = url
    while component.path != "/" {
      guard let attrs = try? fileManager.attributesOfItem(atPath: component.path) else { return true }
      if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
        let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp"]
        guard let expected = systemAliases[component.path],
          let destination = try? fileManager.destinationOfSymbolicLink(atPath: component.path),
          destination == expected || "/" + destination == expected
        else { return true }
      }
      component.deleteLastPathComponent()
    }
    return false
  }

  private static func privateDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
      attrs[.type] as? FileAttributeType == .typeDirectory,
      (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { return false }
    return true
  }
}

private struct PlayableContainerMetadata: Decodable {
  let schemaVersion: Int
  let role: String
  let vmUUID: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case role
    case vmUUID = "vm_uuid"
  }
}

private struct PlayableContainerImportReport: Decodable {
  let action: String
  let imported: Bool
  let metadataVerified: Bool?
  let alreadyManaged: Bool?
  let vmUUID: String?
  let dryRun: Bool?
  let errorCode: String?

  enum CodingKeys: String, CodingKey {
    case action, imported
    case metadataVerified = "metadata_verified"
    case alreadyManaged = "already_managed"
    case vmUUID = "vm_uuid"
    case dryRun = "dry_run"
    case errorCode = "error_code"
  }
}

struct PlayableContainerImporter {
  let resolved: ResolvedRuntimePaths
  let selectionStorageURL: URL
  let fileManager: FileManager
  let commandRunner: UnifiedRuntimeOrchestrator.CommandRunner

  func run(at url: URL, confirmedStopped: Bool) async throws -> ImportedPlayableContainer {
    guard confirmedStopped else {
      throw UnifiedOrchestrationError.backendUnavailable("请先确认容器已完全关闭，且所选目录不是模板或冷备份。")
    }
    let selected = url.standardizedFileURL
    var path = selected.path(percentEncoded: false)
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    guard url.isFileURL, !path.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
      UnifiedRuntimeDiscovery.isUsablePlayableVMBundle(path, fileManager: fileManager)
    else { throw UnifiedOrchestrationError.backendUnavailable("请选择可写的容器目录，并保留有效的配置文件。") }
    guard let python = resolved.pythonExecutablePath, let script = resolved.goldenManagerScriptPath else {
      throw UnifiedOrchestrationError.backendUnavailable("安装包缺少容器管理组件，请重新安装完整应用。")
    }
    try Task.checkCancellation()
    let result: OrchestratorCommandResult
    do {
      result = try await commandRunner(
        python, ["-I", script, "import-playable", "--playable", path, "--confirmed-stopped"],
        ["PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "__DEMOAPP_TIMEOUT_SECONDS": "25"])
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw UnifiedOrchestrationError.commandFailed("容器管理命令未完成，请确认应用组件可用并在容器完全关闭后重试。")
    }
    try Task.checkCancellation()
    let report = result.stdout.data(using: .utf8).flatMap {
      try? JSONDecoder().decode(PlayableContainerImportReport.self, from: $0)
    }
    guard result.exitCode == 0 else {
      throw UnifiedOrchestrationError.commandFailed(Self.rejectionMessage(for: report?.errorCode))
    }
    guard let report, report.action == "import-playable", report.imported,
      report.metadataVerified == true, report.dryRun == false,
      let alreadyManaged = report.alreadyManaged, let identifier = report.vmUUID,
      let verifiedID = PlayableContainerSelection.verifiedIdentifier(at: selected, fileManager: fileManager),
      UUID(uuidString: identifier) == verifiedID
    else {
      throw UnifiedOrchestrationError.commandFailed("未能核验容器导入结果，未保存所选运行环境，请重试或重新选择容器。")
    }
    do {
      try PlayableContainerSelection(schemaVersion: 1, bundlePath: path, vmIdentifier: verifiedID.uuidString)
        .save(to: selectionStorageURL, fileManager: fileManager)
      try? ManagedContainerRegistry.upsert(
        bundlePath: path, vmIdentifier: verifiedID.uuidString,
        selectionURL: selectionStorageURL, fileManager: fileManager
      )
    } catch {
      throw UnifiedOrchestrationError.commandFailed("容器元数据已核验，但无法保存运行环境选择，请检查应用数据目录的写入权限后重试。")
    }
    return ImportedPlayableContainer(
      bundlePath: path, vmIdentifier: verifiedID.uuidString, alreadyManaged: alreadyManaged)
  }

  private static func rejectionMessage(for code: String?) -> String {
    switch code {
    case "needs_confirmation": return "请先确认容器已完全关闭，再重新导入。"
    case "active_runtime", "process_check_failed": return "无法确认容器已停止，请关闭容器及运行组件后重试。"
    case "suspended_state": return "容器仍有保存的运行状态，请先恢复并正常关机后再导入。"
    case "protected_instance": return "不能将系统模板或冷备份导入为可游玩容器，请先创建独立工作副本。"
    case "unsafe_path": return "容器路径不安全，请直接选择本机或外置磁盘中的容器目录，避免使用符号链接。"
    case "invalid_configuration": return "容器配置无效，请检查系统、磁盘和唯一标识后重试。"
    case "conflicting_metadata": return "容器已有不一致的管理信息，请保留原文件并检查所选目录。"
    case "config_changed": return "导入期间容器配置发生变化，请关闭相关程序后重试。"
    case "busy_lock": return "另一个管理操作正在处理此容器，请稍后重试。"
    default: return "容器导入未完成，未保存所选运行环境，请确认容器已完全关闭后重试。"
    }
  }
}
