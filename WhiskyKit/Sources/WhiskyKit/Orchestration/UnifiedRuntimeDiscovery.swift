// SPDX-License-Identifier: GPL-3.0-or-later
// Multi-tier runtime discovery for embedded Malt helpers, scripts, and external SSD VM bundles.

import Foundation

/// Active container network transport mode.
public enum ContainerNetworkMode: String, Codable, Equatable, Sendable {
  case vmnetKernelDirect
  case zeroPrivilegeNativeTCPUDP
  case notVerified

  public var displayName: String {
    switch self {
    case .vmnetKernelDirect:
      return "原生内核网络直通（vmnet）"
    case .zeroPrivilegeNativeTCPUDP:
      return "独立 TCP+UDP 通道（待核验）"
    case .notVerified:
      return "当前容器网络通道待核验"
    }
  }
}

/// Read-only status of the optional privileged vmnet daemon and automatic fallback transport.
public struct NativeVMNetStatus: Equatable, Sendable {
  public let daemonInstalled: Bool
  public let socketActive: Bool
  public let socketPath: String?
  public let activeMode: ContainerNetworkMode

  public init(
    daemonInstalled: Bool,
    socketActive: Bool,
    socketPath: String?,
    activeMode: ContainerNetworkMode
  ) {
    self.daemonInstalled = daemonInstalled
    self.socketActive = socketActive
    self.socketPath = socketPath
    self.activeMode = activeMode
  }

  public var statusSummary: String {
    if socketActive {
      return "网络桥接服务已就绪；当前容器的网络通道仍需启动后核验。"
    }
    if daemonInstalled {
      return "网络桥接服务已安装，等待系统批准或启动。"
    }
    return "尚未启用网络桥接服务，可在运行环境设置中申请系统授权。"
  }
}

/// Resolved paths for container runtime helper, guest scripts, and playable VM bundles.
public struct ResolvedRuntimePaths: Equatable, Sendable {
  public let containerHelperBinaryPath: String?
  public let isEmbeddedHelper: Bool
  public let goldenManagerScriptPath: String?
  public let kioskShellScriptPath: String?
  public let usesEmbeddedScripts: Bool
  public let playableVMBundlePath: String?
  public let pythonExecutablePath: String?
  public let optimizerApplyScriptPath: String?
  public let optimizerRollbackScriptPath: String?
  public let optimizerProfilePath: String?
  public let userNetProxyBinaryPath: String?

  public init(
    containerHelperBinaryPath: String?, isEmbeddedHelper: Bool,
    goldenManagerScriptPath: String?, kioskShellScriptPath: String?,
    usesEmbeddedScripts: Bool, playableVMBundlePath: String?,
    pythonExecutablePath: String? = nil, optimizerApplyScriptPath: String? = nil,
    optimizerRollbackScriptPath: String? = nil, optimizerProfilePath: String? = nil,
    userNetProxyBinaryPath: String? = nil
  ) {
    self.containerHelperBinaryPath = containerHelperBinaryPath
    self.isEmbeddedHelper = isEmbeddedHelper
    self.goldenManagerScriptPath = goldenManagerScriptPath
    self.kioskShellScriptPath = kioskShellScriptPath
    self.usesEmbeddedScripts = usesEmbeddedScripts
    self.playableVMBundlePath = playableVMBundlePath
    self.pythonExecutablePath = pythonExecutablePath
    self.optimizerApplyScriptPath = optimizerApplyScriptPath
    self.optimizerRollbackScriptPath = optimizerRollbackScriptPath
    self.optimizerProfilePath = optimizerProfilePath
    self.userNetProxyBinaryPath = userNetProxyBinaryPath
  }
}

/// Discovers embedded Malt.app helpers/scripts first, then falls back to external/dev paths and SSD volumes.
public enum UnifiedRuntimeDiscovery {
  private static let skippedVolumeNames: Set<String> = [
    "Macintosh HD", "Recovery", "Preboot", "VM", "Update", "DATA"
  ]

  public static func resolve(
    configuration: UnifiedOrchestratorConfiguration,
    fileManager: FileManager = .default
  ) -> ResolvedRuntimePaths {
    let appBundleURL = configuration.appBundleURL ?? Bundle.main.bundleURL
    let (helperBinary, isEmbedded) = resolveContainerHelperBinary(
      appBundleURL: appBundleURL, configuration: configuration, fileManager: fileManager)
    let (goldenScript, goldenEmbedded) = resolveScript(
      fileName: "golden_guest_manager.py", explicitPath: configuration.goldenManagerScriptPath,
      devRelativePath: "graphics-lab/golden_guest_manager.py", configuration: configuration, fileManager: fileManager)
    let (kioskScript, kioskEmbedded) = resolveScript(
      fileName: "kiosk-app-shell.ps1", explicitPath: configuration.kioskShellScriptPath,
      devRelativePath: "Whisky/Modules/guest-optimizer/scripts/kiosk-app-shell.ps1",
      configuration: configuration, fileManager: fileManager)
    let playableVM = resolvePlayableVMBundle(
      explicitPath: configuration.defaultPlayableVMBundlePath,
      selectionStorageURL: configuration.playableSelectionStorageURL,
      volumesRootURL: configuration.volumesRootURL,
      localSearchRoots: configuration.localVMSearchRoots ?? defaultLocalVMSearchRoots(fileManager: fileManager),
      fileManager: fileManager)
    let extras = resolveProvisioningExtras(
      appBundleURL: appBundleURL, configuration: configuration, fileManager: fileManager)
    return ResolvedRuntimePaths(
      containerHelperBinaryPath: helperBinary, isEmbeddedHelper: isEmbedded,
      goldenManagerScriptPath: goldenScript, kioskShellScriptPath: kioskScript,
      usesEmbeddedScripts: goldenEmbedded && kioskEmbedded, playableVMBundlePath: playableVM,
      pythonExecutablePath: resolvePython(configuration: configuration, fileManager: fileManager),
      optimizerApplyScriptPath: extras.applyScript, optimizerRollbackScriptPath: extras.rollbackScript,
      optimizerProfilePath: extras.profile, userNetProxyBinaryPath: extras.userNetProxy)
  }

  public static func detectNativeVMNetStatus(
    socketCandidates: [String] = ["/var/run/malt-vmnet-bridge.sock"],
    daemonPlistCandidates: [String] = ["/Library/LaunchDaemons/com.malt.vmnet-bridge.plist"],
    fileManager: FileManager = .default
  ) -> NativeVMNetStatus {
    let activeSocket = socketCandidates.first { NativeNetworkPermissionService.isSocketReady(path: $0) }
    let daemonInstalled = activeSocket != nil
      || daemonPlistCandidates.contains { fileManager.fileExists(atPath: $0) }
    return NativeVMNetStatus(
      daemonInstalled: daemonInstalled, socketActive: activeSocket != nil,
      socketPath: activeSocket, activeMode: .notVerified)
  }

  /// Scans external SSD volumes for persistent playable `.utm` bundles, strictly excluding
  /// read-only golden templates and cold-backup `vm-a` bundles.
  public static func discoverPlayableVMBundles(
    volumesRootURL: URL = URL(filePath: "/Volumes"),
    localSearchRoots: [URL] = [],
    fileManager: FileManager = .default
  ) -> [String] {
    let volumes =
      (try? fileManager.contentsOfDirectory(
        at: volumesRootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    var discovered: [String] = []
    for directory in localSearchRoots {
      if isUsablePlayableVMBundle(directory.path(percentEncoded: false), fileManager: fileManager) {
        discovered.append(normalizedDirectoryPath(directory))
      }
      discovered.append(
        contentsOf: scanDirectoryForPlayableUTMs(directory, fileManager: fileManager))
    }
    let subDirs = ["whisky-phase2-guest", "MaltVMs", "Malt", ""]
    for volume in volumes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      if skippedVolumeNames.contains(volume.lastPathComponent) {
        continue
      }
      for sub in subDirs {
        let searchRoot = sub.isEmpty ? volume : volume.appending(path: sub)
        discovered.append(
          contentsOf: scanDirectoryForPlayableUTMs(searchRoot, fileManager: fileManager))
      }
    }

    var seen: Set<String> = []
    let unique = discovered.filter { seen.insert($0).inserted }
    return unique.sorted { lhs, rhs in
      let lhsPlayable = lhs.lowercased().contains("playable")
      let rhsPlayable = rhs.lowercased().contains("playable")
      if lhsPlayable != rhsPlayable {
        return lhsPlayable
      }
      return lhs < rhs
    }
  }

}

extension UnifiedRuntimeDiscovery {
  private static func resolvePython(
    configuration: UnifiedOrchestratorConfiguration,
    fileManager: FileManager
  ) -> String? {
    let app = configuration.appBundleURL ?? Bundle.main.bundleURL
    let python =
      configuration.runtimePythonURL
      ?? app.appending(path: "Contents/Frameworks/Python.framework/Versions/Current/bin/python3")
    return fileManager.isExecutableFile(atPath: python.path(percentEncoded: false))
      ? python.path(percentEncoded: false) : nil
  }

  private struct ProvisioningExtras {
    let applyScript, rollbackScript, profile, userNetProxy: String?
  }

  private static func resolveProvisioningExtras(
    appBundleURL: URL, configuration: UnifiedOrchestratorConfiguration, fileManager: FileManager
  ) -> ProvisioningExtras {
    func find(_ name: String, _ rel: String) -> String? {
      resolveScript(fileName: name, explicitPath: nil, devRelativePath: rel,
                    configuration: configuration, fileManager: fileManager).path
    }
    let embeddedProxy = appBundleURL.appending(path: "Contents/Helpers/malt-net-proxy").path(percentEncoded: false)
    let explicitProxy = configuration.userNetProxyBinaryURL?.path(percentEncoded: false)
    let proxy = fileManager.isExecutableFile(atPath: embeddedProxy) ? embeddedProxy
      : (explicitProxy.flatMap { fileManager.isExecutableFile(atPath: $0) ? $0 : nil })
    let profileRel = "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"
    return ProvisioningExtras(
      applyScript: find("apply-optimizer.ps1", "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"),
      rollbackScript: find("rollback-optimizer.ps1", "Whisky/Modules/guest-optimizer/scripts/rollback-optimizer.ps1"),
      profile: find("anticheat-minimal-win11-arm64.json", profileRel),
      userNetProxy: proxy
    )
  }

  private static func resolveContainerHelperBinary(
    appBundleURL: URL,
    configuration: UnifiedOrchestratorConfiguration,
    fileManager: FileManager
  ) -> (path: String?, isEmbedded: Bool) {
    let embeddedCandidates = [
      appBundleURL.appending(path: "Contents/Helpers/MaltContainerHelper.app/Contents/MacOS/UTM"),
      appBundleURL.appending(path: "Contents/Helpers/UTM-Custom.app/Contents/MacOS/UTM")
    ]
    for candidate in embeddedCandidates {
      let path = candidate.path(percentEncoded: false)
      if fileManager.isExecutableFile(atPath: path) {
        return (path, true)
      }
    }

    var externalCandidates: [String] = []
    if !configuration.utmCustomAppPath.isEmpty {
      externalCandidates.append("\(configuration.utmCustomAppPath)/Contents/MacOS/UTM")
    }

    for candidate in externalCandidates where fileManager.isExecutableFile(atPath: candidate) {
      return (candidate, false)
    }
    return (nil, false)
  }

  private static func resolveScript(
    fileName: String,
    explicitPath: String?,
    devRelativePath: String,
    configuration: UnifiedOrchestratorConfiguration,
    fileManager: FileManager
  ) -> (path: String?, isEmbedded: Bool) {
    let appBundleURL = configuration.appBundleURL ?? Bundle.main.bundleURL
    let embeddedPath =
      appBundleURL
      .appending(path: "Contents/Resources/RuntimeScripts")
      .appending(path: fileName)
      .path(percentEncoded: false)
    if fileManager.fileExists(atPath: embeddedPath) {
      return (embeddedPath, true)
    }

    if let explicitPath, !explicitPath.isEmpty {
      if explicitPath.hasPrefix("/"), fileManager.fileExists(atPath: explicitPath) {
        return (explicitPath, false)
      }
      guard let workspaceRoot = configuration.workspaceRootURL else { return (nil, false) }
      let relativeResolved =
        workspaceRoot
        .appending(path: explicitPath)
        .standardizedFileURL
        .path(percentEncoded: false)
      if fileManager.fileExists(atPath: relativeResolved) {
        return (relativeResolved, false)
      }
    }

    for root in candidateWorkspaceRoots(
      explicitRoot: configuration.workspaceRootURL, fileManager: fileManager
    ) {
      let candidate = root.appending(path: devRelativePath).path(percentEncoded: false)
      if fileManager.fileExists(atPath: candidate) {
        return (candidate, false)
      }
    }
    return (nil, false)
  }

  private static func resolvePlayableVMBundle(
    explicitPath: String?,
    selectionStorageURL: URL,
    volumesRootURL: URL,
    localSearchRoots: [URL],
    fileManager: FileManager
  ) -> String? {
    if let explicitPath {
      return isUsablePlayableVMBundle(explicitPath, fileManager: fileManager) ? explicitPath : nil
    }
    if (try? fileManager.attributesOfItem(atPath: selectionStorageURL.path(percentEncoded: false))) != nil {
      return PlayableContainerSelection.load(from: selectionStorageURL, fileManager: fileManager)
    }
    return discoverPlayableVMBundles(
      volumesRootURL: volumesRootURL, localSearchRoots: localSearchRoots, fileManager: fileManager
    ).first
  }

  private static func scanDirectoryForPlayableUTMs(
    _ directory: URL,
    fileManager: FileManager
  ) -> [String] {
    guard
      let items = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var results: [String] = []
    for item in items {
      let lowerName = item.lastPathComponent.lowercased()
      if item.pathExtension.lowercased() == "utm" {
        if !isUsablePlayableVMBundle(item.path(percentEncoded: false), fileManager: fileManager) {
          continue
        }
        results.append(normalizedDirectoryPath(item))
        continue
      }
      if lowerName == "playable" || lowerName == "vms" {
        if let nested = try? fileManager.contentsOfDirectory(
          at: item,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        ) {
          for sub in nested where sub.pathExtension.lowercased() == "utm" {
            if isUsablePlayableVMBundle(sub.path(percentEncoded: false), fileManager: fileManager) {
              results.append(normalizedDirectoryPath(sub))
            }
          }
        }
      }
    }
    return results
  }

  /// Checks the selected bundle itself and its symlink destination before any runtime launch.
  public static func isUsablePlayableVMBundle(_ path: String, fileManager: FileManager = .default) -> Bool {
    let url = URL(filePath: path).standardizedFileURL
    let canonical = url.resolvingSymlinksInPath()
    guard url.pathExtension.lowercased() == "utm",
      !isProtectedTemplateOrColdBackup(url.lastPathComponent.lowercased()),
      !isProtectedTemplateOrColdBackup(canonical.lastPathComponent.lowercased()),
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      fileManager.isReadableFile(
        atPath: url.appending(path: "config.plist").path(percentEncoded: false)),
      fileManager.isWritableFile(atPath: url.path(percentEncoded: false))
    else { return false }
    return true
  }

  private static func defaultLocalVMSearchRoots(fileManager: FileManager) -> [URL] {
    let support = UnifiedGameLibraryStore.defaultStorageURL(fileManager: fileManager)
      .deletingLastPathComponent()
    return [support.appending(path: "VirtualMachines"), support.appending(path: "Containers")]
  }

  private static func normalizedDirectoryPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  private static func isProtectedTemplateOrColdBackup(_ lowerName: String) -> Bool {
    lowerName.contains("golden") || lowerName == "vm-a.utm" || lowerName.hasPrefix("vm-a-")
  }

  private static func candidateWorkspaceRoots(
    explicitRoot: URL?,
    fileManager: FileManager
  ) -> [URL] {
    guard let explicitRoot else { return [] }
    return [explicitRoot.standardizedFileURL]
  }
}
