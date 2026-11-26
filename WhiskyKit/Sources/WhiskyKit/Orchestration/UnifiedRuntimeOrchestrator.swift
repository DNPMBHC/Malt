// SPDX-License-Identifier: GPL-3.0-or-later
// Unified runtime orchestrator bridging native Wine bottles and embedded single-app containers.

// Keep the orchestration facade and its startup transactions together.
// swiftlint:disable file_length

import AppKit
import Combine
import Foundation

/// Configuration overrides for locating embedded helpers, Wine binaries, scripts, and SSD VM bundles.
public struct UnifiedOrchestratorConfiguration: Sendable {
  public let utmCustomAppPath: String
  public let utmAppPath: String
  public let goldenManagerScriptPath: String?
  public let kioskShellScriptPath: String?
  public let defaultPlayableVMBundlePath: String?
  public let defaultBottleURL: URL?
  public let appBundleURL: URL?
  public let workspaceRootURL: URL?
  public let volumesRootURL: URL
  public let wineBinaryURL: URL?
  public let wineLibraryFolderURL: URL?
  public let appShellWindowSize: String
  public let appShellStateDirectory: URL?
  public let localVMSearchRoots: [URL]?
  public let containerControlBinaryURL: URL?
  public let guestAgentReadinessTimeout: TimeInterval
  public let runtimePythonURL: URL?
  public let playableSelectionStorageURL: URL

  public init(
    utmCustomAppPath: String = "/Applications/UTM-Custom.app",
    utmAppPath: String = "/Applications/UTM.app",
    goldenManagerScriptPath: String? = nil,
    kioskShellScriptPath: String? = nil,
    defaultPlayableVMBundlePath: String? = nil,
    defaultBottleURL: URL? = nil,
    appBundleURL: URL? = nil,
    workspaceRootURL: URL? = nil,
    volumesRootURL: URL = URL(filePath: "/Volumes"),
    wineBinaryURL: URL? = nil,
    wineLibraryFolderURL: URL? = nil,
    appShellWindowSize: String = "1024x680",
    appShellStateDirectory: URL? = nil,
    localVMSearchRoots: [URL]? = nil,
    containerControlBinaryURL: URL? = nil,
    guestAgentReadinessTimeout: TimeInterval = 90,
    runtimePythonURL: URL? = nil,
    playableSelectionStorageURL: URL? = nil
  ) {
    self.utmCustomAppPath = utmCustomAppPath
    self.utmAppPath = utmAppPath
    self.goldenManagerScriptPath = goldenManagerScriptPath
    self.kioskShellScriptPath = kioskShellScriptPath
    self.defaultPlayableVMBundlePath = defaultPlayableVMBundlePath
    self.defaultBottleURL = defaultBottleURL
    self.appBundleURL = appBundleURL
    self.workspaceRootURL = workspaceRootURL
    self.volumesRootURL = volumesRootURL
    self.wineBinaryURL = wineBinaryURL
    self.wineLibraryFolderURL = wineLibraryFolderURL
    self.appShellWindowSize = appShellWindowSize
    self.appShellStateDirectory = appShellStateDirectory
    self.localVMSearchRoots = localVMSearchRoots
    self.containerControlBinaryURL = containerControlBinaryURL
    self.guestAgentReadinessTimeout = min(180, max(0.1, guestAgentReadinessTimeout))
    self.runtimePythonURL = runtimePythonURL
    self.playableSelectionStorageURL = playableSelectionStorageURL
      ?? PlayableContainerSelection.defaultStorageURL(fileManager: .default)
  }
}

/// Unified entry point for launching, installing, and health-checking Wine and container titles.
public final class UnifiedRuntimeOrchestrator: ObservableObject, @unchecked Sendable {
  public typealias CommandRunner =
    @Sendable (String, [String], [String: String]) async throws -> OrchestratorCommandResult

  @Published public private(set) var activeEntryID: UUID?
  @Published public private(set) var lastStatusMessage: String = ""
  @Published public private(set) var nativeNetworkPermissionState: NativeNetworkPermissionSnapshot?

  public let libraryStore: UnifiedGameLibraryStore
  public let configuration: UnifiedOrchestratorConfiguration

  private let fileManager: FileManager
  private let commandRunner: CommandRunner
  private let helperRunningProbe: @Sendable (String) async -> Bool
  private let runtimeSettingsCapabilityProbe: @Sendable (String) -> Bool
  private let appShellSessionBridge: AppShellSessionBridge
  private let helperIdentityProbe: @Sendable (String) async -> String?

  public init(
    libraryStore: UnifiedGameLibraryStore = UnifiedGameLibraryStore(),
    configuration: UnifiedOrchestratorConfiguration = UnifiedOrchestratorConfiguration(),
    fileManager: FileManager = .default,
    commandRunner: CommandRunner? = nil,
    helperRunningProbe: (@Sendable (String) async -> Bool)? = nil,
    runtimeSettingsCapabilityProbe: (@Sendable (String) -> Bool)? = nil,
    appShellSessionBridge: AppShellSessionBridge = AppShellSessionBridge(),
    helperIdentityProbe: (@Sendable (String) async -> String?)? = nil
  ) {
    self.libraryStore = libraryStore
    self.configuration = configuration
    self.fileManager = fileManager
    self.commandRunner = commandRunner ?? Self.defaultCommandRunner
    self.helperRunningProbe = helperRunningProbe ?? Self.isContainerHelperRunning
    self.runtimeSettingsCapabilityProbe = runtimeSettingsCapabilityProbe ?? Self.supportsRuntimeSettings
    self.appShellSessionBridge = appShellSessionBridge
    self.helperIdentityProbe = helperIdentityProbe ?? Self.containerHelperIdentity
  }

  public func resolvedRuntimePaths() -> ResolvedRuntimePaths {
    UnifiedRuntimeDiscovery.resolve(configuration: configuration, fileManager: fileManager)
  }

  public func nativeVMNetStatus() -> NativeVMNetStatus {
    UnifiedRuntimeDiscovery.detectNativeVMNetStatus(fileManager: fileManager)
  }

  @MainActor
  @discardableResult
  public func refreshNativeNetworkStatus() -> NativeNetworkPermissionSnapshot {
    let snapshot = NativeNetworkPermissionService(
      appBundleURL: configuration.appBundleURL ?? Bundle.main.bundleURL
    )
    .status()
    nativeNetworkPermissionState = snapshot
    return snapshot
  }

  @MainActor
  @discardableResult
  public func requestNativeNetworkAuthorization() -> NativeNetworkPermissionSnapshot {
    let snapshot = NativeNetworkPermissionService(
      appBundleURL: configuration.appBundleURL ?? Bundle.main.bundleURL
    )
    .requestAuthorization()
    nativeNetworkPermissionState = snapshot
    return snapshot
  }

  @MainActor
  public func openNativeNetworkApprovalSettings() {
    NativeNetworkPermissionService(
      appBundleURL: configuration.appBundleURL ?? Bundle.main.bundleURL
    )
    .openApprovalSettings()
  }

  @MainActor
  @discardableResult
  public func revokeNativeNetworkAuthorization() async -> NativeNetworkPermissionSnapshot {
    let snapshot = await NativeNetworkPermissionService(
      appBundleURL: configuration.appBundleURL ?? Bundle.main.bundleURL
    ).revokeAuthorization()
    nativeNetworkPermissionState = snapshot
    return snapshot
  }

  /// Applies or restores the bridge only after the management helper verifies the VM is stopped.
  @discardableResult
  public func configureNativeNetwork(
    for entry: UnifiedGameEntry,
    restore: Bool = false
  ) async throws -> NativeContainerNetworkConfigurationResult {
    guard entry.engineKind == .antiCheatVM else {
      throw UnifiedOrchestrationError.backendUnavailable("此网络设置仅适用于容器运行环境。")
    }
    let resolved = resolvedRuntimePaths()
    guard let vmPath = entry.vmBundlePath ?? resolved.playableVMBundlePath,
      UnifiedRuntimeDiscovery.isUsablePlayableVMBundle(vmPath, fileManager: fileManager)
    else {
      throw UnifiedOrchestrationError.missingVMBundle(entry.vmBundlePath ?? "")
    }
    guard let python = resolved.pythonExecutablePath,
      let script = resolved.goldenManagerScriptPath,
      let control = resolvedContainerControlBinary(resolved: resolved)
    else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "安装包缺少网络管理组件。请安装包含内嵌管理运行时的完整应用。"
      )
    }
    if !restore && !nativeVMNetStatus().socketActive {
      throw UnifiedOrchestrationError.backendUnavailable(
        "请先申请原生网络权限，并在系统设置中批准网络服务，待服务就绪后重试。"
      )
    }
    let helper = try await prepareContainerForNetworkConfiguration(resolved: resolved, vmPath: vmPath, control: control)
    var arguments = ["-I", script, "configure-network", "--playable", vmPath, "--utmctl", control]
    if restore { arguments.append("--restore") }
    let result = try await commandRunner(
      python, arguments,
      [
        "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "__DEMOAPP_TIMEOUT_SECONDS": "25"
      ])
    guard result.exitCode == 0,
      let data = result.stdout.data(using: .utf8),
      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      report["configured"] as? Bool == true,
      report["config_verified"] as? Bool == true,
      report["dry_run"] as? Bool == false,
      report["restored"] as? Bool == restore,
      report["network_mode"] as? String == (restore ? "restored" : "socket-vmnet")
    else {
      throw UnifiedOrchestrationError.commandFailed(
        "未修改运行中的或状态未知的容器。请正常关闭容器，确认桥接服务可用后重试。"
      )
    }
    try await reloadContainerNetworkConfiguration(helper: helper, vmPath: vmPath)
    let outcome = NativeContainerNetworkConfigurationResult(
      networkMode: restore ? "restored" : "socket-vmnet", restored: restore,
      changed: report["changed"] as? Bool ?? false
    )
    lastStatusMessage = restore ? "已恢复容器原有网络配置。" : "已配置容器桥接网络；下次启动后请核验实际连接。"
    return outcome
  }

  public func launch(entry: UnifiedGameEntry, settings: UnifiedLaunchSettings? = nil) async throws {
    guard entry.installationState != .installerRequested else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "安装器请求已提交。请完成安装并选择真正的游戏主程序，再使用快速启动。"
      )
    }
    let settings = (settings ?? UnifiedLaunchSettings.load()).resolved(
      for: entry, hardware: HardwareAutoTuner().detectHardwareProfile())
    activeEntryID = entry.id
    defer { activeEntryID = nil }

    switch entry.engineKind {
    case .nativeWine:
      try await launchWineEntry(entry, settings: settings)
    case .antiCheatVM:
      try await launchAntiCheatVMEntry(entry, settings: settings)
    }

    var updated = entry
    updated.lastPlayedAt = Date()
    libraryStore.upsert(updated)
    lastStatusMessage =
      entry.engineKind == .nativeWine
      ? "已提交启动请求：\(entry.name)。原生游戏的分辨率与资源由游戏自身管理。"
      : "已提交启动请求：\(entry.name)。输入与缓存设置需正常关闭 Windows 并完全退出容器引擎后，重新打开时生效。"
  }

  public func install(
    installerURL: URL,
    engineKind: UnifiedEngineKind,
    title: String,
    settings: UnifiedLaunchSettings? = nil
  ) async throws -> UnifiedGameEntry {
    let installerPath = installerURL.path(percentEncoded: false)
    guard fileManager.isReadableFile(atPath: installerPath),
      (try? installerURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else {
      throw UnifiedOrchestrationError.missingInstaller(installerPath)
    }

    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle =
      cleanTitle.isEmpty
      ? installerURL.deletingPathExtension().lastPathComponent
      : cleanTitle

    let settings = settings ?? UnifiedLaunchSettings.load()
    let entry: UnifiedGameEntry
    switch engineKind {
    case .nativeWine:
      entry = try await installViaWine(
        installerURL: installerURL, title: resolvedTitle, settings: settings)
    case .antiCheatVM:
      entry = try await installViaAntiCheatVM(
        installerURL: installerURL, title: resolvedTitle, settings: settings)
    }

    libraryStore.upsert(entry)
    lastStatusMessage = "安装器启动请求已提交。安装完成后请选择游戏主程序。"
    return entry
  }

  public func healthStatus() -> [String: Bool] {
    let resolved = resolvedRuntimePaths()
    let wineBinary = resolvedWineBinaryURL().path(percentEncoded: false)
    let wineReady = fileManager.isExecutableFile(atPath: wineBinary)
    let embeddedHelperReady = resolved.isEmbeddedHelper && resolved.containerHelperBinaryPath != nil
    let utmCustomReady = resolved.containerHelperBinaryPath != nil
    let settingsContractReady = resolved.containerHelperBinaryPath.map(runtimeSettingsCapabilityProbe) ?? false
    let utmAppReady = fileManager.fileExists(atPath: configuration.utmAppPath)
    let goldenManagerReady = resolved.goldenManagerScriptPath != nil
    let kioskScriptReady = resolved.kioskShellScriptPath != nil
    let playableVMDiscovered = resolved.playableVMBundlePath != nil
    let vmnetStatus = nativeVMNetStatus()
    let controlReady = resolvedContainerControlBinary(resolved: resolved) != nil
    let storeParent = libraryStore.storageURL.deletingLastPathComponent().path(
      percentEncoded: false)
    let storeWritable =
      fileManager.isWritableFile(atPath: storeParent)
      || fileManager.isWritableFile(
        atPath: fileManager.homeDirectoryForCurrentUser.path(percentEncoded: false))

    return [
      "wine_ready": wineReady,
      "runtime_python_ready": resolved.pythonExecutablePath != nil,
      "container_control_ready": controlReady,
      "container_settings_contract_ready": settingsContractReady,
      "native_network_service_bundled": NativeNetworkPermissionService.validatePayload(
        in: configuration.appBundleURL ?? Bundle.main.bundleURL
      ),
      "guest_config_valid": resolved.playableVMBundlePath.map {
        (try? ContainerGuestDispatcher.vmIdentifier(bundlePath: $0)) != nil
      } ?? false,
      "network_management_ready": resolved.pythonExecutablePath != nil && goldenManagerReady
        && controlReady,
      "embedded_helper_ready": embeddedHelperReady,
      "embedded_scripts_ready": resolved.usesEmbeddedScripts,
      "utm_custom_ready": utmCustomReady,
      "utm_app_ready": utmAppReady,
      "golden_manager_ready": goldenManagerReady,
      "kiosk_shell_script_ready": kioskScriptReady,
      "playable_vm_discovered": playableVMDiscovered,
      "vmnet_kernel_direct_ready": vmnetStatus.socketActive,
      "library_store_writable": storeWritable,
      "anti_cheat_vm_ready": utmCustomReady && playableVMDiscovered && kioskScriptReady
        && controlReady && settingsContractReady
    ]
  }

  /// Constructs the native WhiskyKit Wine launch environment with DXMT/D3DMetal/DXVK/WINEDLLPATH routing.
  public func buildWineEnvironment(
    for bottleURL: URL, settings: UnifiedLaunchSettings? = nil
  ) -> [String: String] {
    let bottle = Bottle(bottleUrl: bottleURL, readOnly: true)
    let libraryFolder =
      configuration.wineLibraryFolderURL ?? embeddedWineLibraryFolderURL()
      ?? WhiskyWineInstaller.libraryFolder
    var wineEnv: [String: String] = [
      "WINEPREFIX": bottleURL.path(percentEncoded: false),
      "WINEDEBUG": "fixme-all",
      "GST_DEBUG": "1"
    ]
    bottle.settings.environmentVariables(
      wineEnv: &wineEnv,
      bottleURL: bottleURL,
      libraryFolder: libraryFolder
    )
    return (settings ?? UnifiedLaunchSettings.load()).applyingWineCachePolicy(to: wineEnv)
  }
}

extension UnifiedRuntimeOrchestrator {
  fileprivate func resolvedWineBinaryURL() -> URL {
    if let explicit = configuration.wineBinaryURL { return explicit }
    if let folder = embeddedWineLibraryFolderURL() {
      return folder.appending(path: "Wine/bin/wine64")
    }
    return WhiskyWineInstaller.binFolder.appending(path: "wine64")
  }

  fileprivate func embeddedWineLibraryFolderURL() -> URL? {
    let app = configuration.appBundleURL ?? Bundle.main.bundleURL
    let folder = app.appending(path: "Contents/Resources/Libraries")
    return fileManager.isExecutableFile(
      atPath: folder.appending(path: "Wine/bin/wine64").path(percentEncoded: false))
      ? folder : nil
  }

  fileprivate func launchWineEntry(_ entry: UnifiedGameEntry, settings: UnifiedLaunchSettings)
    async throws {
    guard let bottleURL = entry.bottleURL ?? configuration.defaultBottleURL else {
      throw UnifiedOrchestrationError.missingBottleURL(entry.name)
    }
    guard fileManager.fileExists(atPath: entry.executablePath) else {
      throw UnifiedOrchestrationError.missingExecutable(entry.executablePath)
    }
    let wineBinary = resolvedWineBinaryURL().path(percentEncoded: false)
    try validateWineRuntime(binaryPath: wineBinary)
    guard fileManager.fileExists(atPath: bottleURL.path(percentEncoded: false)) else {
      throw UnifiedOrchestrationError.backendUnavailable("游戏运行环境已移动或不可访问，请重新选择运行环境。")
    }
    let environment = buildWineEnvironment(for: bottleURL, settings: settings)
    let result = try await commandRunner(
      wineBinary,
      ["start", "/unix", entry.executablePath],
      environment
    )
    guard result.exitCode == 0 else {
      throw UnifiedOrchestrationError.commandFailed(result.stderr)
    }
  }

  fileprivate func launchAntiCheatVMEntry(
    _ entry: UnifiedGameEntry, settings: UnifiedLaunchSettings
  ) async throws {
    let resolved = resolvedRuntimePaths()
    guard let vmPath = entry.vmBundlePath ?? resolved.playableVMBundlePath,
      UnifiedRuntimeDiscovery.isUsablePlayableVMBundle(vmPath, fileManager: fileManager)
    else {
      throw UnifiedOrchestrationError.missingVMBundle(entry.vmBundlePath ?? "")
    }
    guard ContainerGuestDispatcher.isWindowsExecutablePath(entry.executablePath) else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "请选择容器内已安装游戏的 Windows 完整路径，不能使用 macOS 安装器路径。"
      )
    }
    let dispatcher = try containerDispatcher(resolved: resolved, vmPath: vmPath)
    try await applyContainerResources(
      settings, vmPath: vmPath, dispatcher: dispatcher, resolved: resolved, title: entry.name)
    let binding = try await startContainerHelper(
      resolved: resolved, vmPath: vmPath, title: entry.name, settings: settings)
    try await appShellSessionBridge.resetCompact(bindingID: binding.id)
    try await dispatcher.waitUntilReady()
    if let helper = resolved.containerHelperBinaryPath {
      await appShellSessionBridge.recordHelperIdentity(await helperIdentityProbe(helper), bindingID: binding.id)
    }
    let session = GuestAppShellSession(vmIdentifier: dispatcher.vmIdentifier, targetExecutable: entry.executablePath)
    do {
      try await dispatcher.submit(
        targetExecutable: entry.executablePath, targetArguments: entry.launchArguments ?? "",
        targetWorkingDirectory: entry.launchWorkingDirectory ?? "",
        kioskScriptPath: try requiredKioskScript(resolved: resolved),
        displayPolicy: settings.displayPolicy, appShellSession: session)
      try Task.checkCancellation()
      try await appShellSessionBridge.startMonitoring(session: session, bindingID: binding.id, dispatcher: dispatcher)
    } catch {
      try? await appShellSessionBridge.resetCompact(bindingID: binding.id)
      throw error
    }
  }

  fileprivate func installViaWine(
    installerURL: URL, title: String, settings: UnifiedLaunchSettings
  ) async throws -> UnifiedGameEntry {
    let bottleURL =
      configuration.defaultBottleURL
      ?? libraryStore.storageURL.deletingLastPathComponent().appending(path: "Bottles/Default")
    let wineBinary = resolvedWineBinaryURL().path(percentEncoded: false)
    let installerPath = installerURL.path(percentEncoded: false)
    try validateWineRuntime(binaryPath: wineBinary)
    try fileManager.createDirectory(at: bottleURL, withIntermediateDirectories: true)
    let environment = buildWineEnvironment(for: bottleURL, settings: settings)
    let result = try await commandRunner(
      wineBinary,
      ["start", "/unix", installerPath],
      environment
    )
    guard result.exitCode == 0 else {
      throw UnifiedOrchestrationError.commandFailed(result.stderr)
    }
    return UnifiedGameEntry(
      name: title,
      executablePath: installerPath,
      engineKind: .nativeWine,
      presetTier: .balanced,
      bottleURL: bottleURL,
      installationState: .installerRequested
    )
  }

  fileprivate func installViaAntiCheatVM(
    installerURL: URL, title: String, settings: UnifiedLaunchSettings
  ) async throws -> UnifiedGameEntry {
    let resolved = resolvedRuntimePaths()
    guard let vmPath = resolved.playableVMBundlePath else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "尚未配置可游玩容器。请先导入已安装 Windows 和来宾工具的容器；应用安装包不包含 Windows 系统镜像。"
      )
    }
    let dispatcher = try containerDispatcher(resolved: resolved, vmPath: vmPath)
    let kioskScript = try requiredKioskScript(resolved: resolved)
    try await applyContainerResources(
      settings, vmPath: vmPath, dispatcher: dispatcher, resolved: resolved, title: title)
    let binding = try await startContainerHelper(
      resolved: resolved, vmPath: vmPath, title: title, settings: settings)
    try await appShellSessionBridge.resetCompact(bindingID: binding.id)
    try await dispatcher.waitUntilReady()
    try await dispatcher.submit(
      targetExecutable: "", kioskScriptPath: kioskScript, installerURL: installerURL,
      displayPolicy: settings.displayPolicy)
    return UnifiedGameEntry(
      name: title,
      executablePath: installerURL.path(percentEncoded: false),
      engineKind: .antiCheatVM,
      presetTier: .balanced,
      vmBundlePath: vmPath,
      installationState: .installerRequested
    )
  }

  fileprivate func validateWineRuntime(binaryPath: String) throws {
    guard fileManager.isExecutableFile(atPath: binaryPath) else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "原生运行组件尚未安装或无法执行。请在运行环境设置中完成组件安装后重试。"
      )
    }
  }

  fileprivate func requiredKioskScript(resolved: ResolvedRuntimePaths) throws -> String {
    guard let path = resolved.kioskShellScriptPath, fileManager.isReadableFile(atPath: path) else {
      throw UnifiedOrchestrationError.backendUnavailable("安装包缺少来宾启动组件，请重新安装完整应用。")
    }
    return path
  }

  fileprivate func resolvedContainerControlBinary(resolved: ResolvedRuntimePaths) -> String? {
    let candidate =
      configuration.containerControlBinaryURL
      ?? resolved.containerHelperBinaryPath.map {
        URL(filePath: $0).deletingLastPathComponent().appending(path: "utmctl")
      }
    guard let candidate, fileManager.isExecutableFile(atPath: candidate.path(percentEncoded: false))
    else {
      return nil
    }
    return candidate.path(percentEncoded: false)
  }

  fileprivate func containerDispatcher(resolved: ResolvedRuntimePaths, vmPath: String) throws
    -> ContainerGuestDispatcher {
    _ = try requiredKioskScript(resolved: resolved)
    guard resolved.containerHelperBinaryPath != nil,
      let control = resolvedContainerControlBinary(resolved: resolved)
    else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "安装包缺少可执行容器引擎或来宾控制组件，请重新安装完整应用。"
      )
    }
    return ContainerGuestDispatcher(
      controlBinaryPath: control,
      vmIdentifier: try ContainerGuestDispatcher.vmIdentifier(bundlePath: vmPath),
      commandRunner: commandRunner,
      readinessTimeout: configuration.guestAgentReadinessTimeout
    )
  }

  fileprivate static func supportsRuntimeSettings(_ helper: String) -> Bool {
    let info = URL(filePath: helper).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Info.plist")
    guard let data = try? Data(contentsOf: info),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let version = values["UTMRuntimeSettingsContractVersion"] as? Int else { return false }
    return version >= 1
  }

  fileprivate func requireRuntimeSettingsSupport(_ helper: String) throws {
    guard runtimeSettingsCapabilityProbe(helper) else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "当前容器运行组件不支持此版本的运行设置。请安装包含新版容器引擎的完整应用后重试。")
    }
  }

  fileprivate func applyContainerResources(
    _ settings: UnifiedLaunchSettings, vmPath: String, dispatcher: ContainerGuestDispatcher,
    resolved: ResolvedRuntimePaths, title: String
  ) async throws {
    guard try ContainerResourceConfigurator.requiresUpdate(settings, bundlePath: vmPath) else { return }
    let hardware = HardwareAutoTuner().detectHardwareProfile()
    try ContainerResourceConfigurator.validate(settings, hardware: hardware)
    guard let helper = resolved.containerHelperBinaryPath else {
      throw UnifiedOrchestrationError.backendUnavailable("缺少容器运行组件，请重新安装完整应用。")
    }
    try requireRuntimeSettingsSupport(helper)
    let preparedBinding: AppShellBinding?
    if !(await helperRunningProbe(helper)) {
      let state = try await createAppShellBinding(vmPath: vmPath, helper: helper, title: title)
      preparedBinding = state
      let args = [
        "--app-shell-vm", vmPath, "--app-shell-prepare-only", "--window-title", title,
        "--window-size", configuration.appShellWindowSize,
        "--app-shell-state-file", state.stateURL.path(percentEncoded: false)
      ]
      let environment = settings.containerEnvironment.merging(["__DEMOAPP_DETACHED": "1"]) { _, new in new }
      let result = try await commandRunner(helper, args, environment)
      guard result.exitCode == 0 else {
        await appShellSessionBridge.invalidate(bindingID: state.id)
        throw UnifiedOrchestrationError.commandFailed("容器引擎未能准备资源设置，未启动 Windows。")
      }
    } else { preparedBinding = nil }
    try await ContainerResourceConfigurator.apply(
      settings, bundlePath: vmPath, controlBinaryPath: dispatcher.controlBinaryPath,
      commandRunner: commandRunner, hardware: hardware,
      verifyStopped: {
        try await self.verifyContainerStopped(helper: helper, dispatcher: dispatcher)
        if let preparedBinding {
          await self.appShellSessionBridge.recordHelperIdentity(
            await self.helperIdentityProbe(helper), bindingID: preparedBinding.id)
        }
        try await self.reloadContainerConfiguration(
          helper: helper, vmIdentifier: dispatcher.vmIdentifier, beforeWrite: true)
      })
    try await reloadContainerConfiguration(helper: helper, vmIdentifier: dispatcher.vmIdentifier, beforeWrite: false)
  }

  fileprivate func reloadContainerConfiguration(
    helper: String, vmIdentifier: String, beforeWrite: Bool
  ) async throws {
    // The versioned helper rejects running, paused, suspended, or saved-state configurations.
    let helperApp = URL(filePath: helper).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().path(percentEncoded: false)
    let script = """
      on run argv
          set helperApp to item 1 of argv
          set targetID to item 2 of argv
          tell application helperApp
              «event UTMcReLd» («class UTMv» id targetID)
          end tell
      end run
      """
    let reloaded = try await commandRunner(
      "/usr/bin/osascript", ["-e", script, helperApp, vmIdentifier],
      ["__DEMOAPP_TIMEOUT_SECONDS": "15"])
    try ContainerGuestDispatcher.requireAutomationAccess(reloaded)
    guard reloaded.exitCode == 0 else {
      throw UnifiedOrchestrationError.commandFailed(
        beforeWrite
          ? "运行环境仍在运行、挂起或保留保存状态，或引擎无法确认安全冷启动。请正常关闭 Windows 后重试；资源配额未修改。"
          : "资源配额已保存，但容器引擎尚未重新载入配置。请完全退出容器引擎后重试；本次未启动 Windows。")
    }
  }

  fileprivate func verifyContainerStopped(
    helper: String, dispatcher: ContainerGuestDispatcher
  ) async throws {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      try Task.checkCancellation()
      // Sending AppleEvents to a missing target app would launch a second ordinary helper.
      if await helperRunningProbe(helper) {
        let result = try await commandRunner(
          dispatcher.controlBinaryPath, ["status", "--hide", dispatcher.vmIdentifier],
          ["__DEMOAPP_TIMEOUT_SECONDS": "5"])
        try ContainerGuestDispatcher.requireAutomationAccess(result)
        if result.exitCode == 0 {
          guard result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stopped" else {
            throw UnifiedOrchestrationError.backendUnavailable(
              "资源设置已保留，但运行环境尚未确认完全关闭。请正常关闭 Windows 运行环境后重试；从暂停或挂起恢复不会应用新配额。")
          }
          return
        }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UnifiedOrchestrationError.backendUnavailable(
      "容器引擎尚未完成准备或无法确认停止状态。资源配额未修改，Windows 未启动。")
  }

  fileprivate func startContainerHelper(
    resolved: ResolvedRuntimePaths, vmPath: String, title: String, settings: UnifiedLaunchSettings
  ) async throws -> AppShellBinding {
    guard let helper = resolved.containerHelperBinaryPath else {
      throw UnifiedOrchestrationError.backendUnavailable("缺少容器运行组件，请重新安装完整应用。")
    }
    try requireRuntimeSettingsSupport(helper)
    // A scripting status query launches its target app. Only probe an already-running helper,
    // otherwise that probe would create a second, ordinary instance before the shell instance.
    if await helperRunningProbe(helper),
      let control = resolvedContainerControlBinary(resolved: resolved) {
      let identifier = try ContainerGuestDispatcher.vmIdentifier(bundlePath: vmPath)
      let binding = try await appShellSessionBridge.requireBinding(
        vmIdentifier: identifier, helper: helper, identity: await helperIdentityProbe(helper))
      let status: OrchestratorCommandResult
      do {
        status = try await commandRunner(
          control, ["status", "--hide", identifier], ["__DEMOAPP_TIMEOUT_SECONDS": "5"])
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        // Only this known helper binding may continue through a transient control timeout.
        return binding
      }
      try ContainerGuestDispatcher.requireAutomationAccess(status)
      guard status.exitCode == 0 else {
        throw UnifiedOrchestrationError.backendUnavailable(
          "容器引擎正在运行，但尚未登记所选容器。请关闭现有容器窗口后从此应用重新打开，避免同时启动多个引擎实例。"
        )
      }
      let state = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      if state == "stopped" || state == "paused" {
        let result = try await commandRunner(
          control, ["start", "--hide", identifier], ["__DEMOAPP_TIMEOUT_SECONDS": "15"])
        try ContainerGuestDispatcher.requireAutomationAccess(result)
        guard result.exitCode == 0 else {
          throw UnifiedOrchestrationError.commandFailed("现有容器引擎未能启动所选容器。请检查容器状态后重试。")
        }
      }
      return binding
    }
    let stateFile = try await createAppShellBinding(vmPath: vmPath, helper: helper, title: title)
    let args = [
      "--app-shell-vm", vmPath, "--window-title", title,
      "--window-size", configuration.appShellWindowSize,
      "--app-shell-state-file", stateFile.stateURL.path(percentEncoded: false)
    ]
    let environment = settings.containerEnvironment.merging(["__DEMOAPP_DETACHED": "1"]) { _, new in
      new
    }
    let result = try await commandRunner(helper, args, environment)
    guard result.exitCode == 0 else {
      await appShellSessionBridge.invalidate(bindingID: stateFile.id)
      throw UnifiedOrchestrationError.commandFailed("容器引擎未能启动，请检查容器配置和系统虚拟化支持。")
    }
    await appShellSessionBridge.recordHelperIdentity(await helperIdentityProbe(helper), bindingID: stateFile.id)
    return stateFile
  }

  fileprivate func createAppShellBinding(
    vmPath: String, helper: String, title: String
  ) async throws -> AppShellBinding {
    let directory = configuration.appShellStateDirectory
      ?? fileManager.temporaryDirectory.appending(path: "runtime-app-shell")
    return try await appShellSessionBridge.createBinding(
      vmIdentifier: ContainerGuestDispatcher.vmIdentifier(bundlePath: vmPath), helper: helper,
      directory: directory, title: title, windowSize: configuration.appShellWindowSize)
  }

  private static func containerHelperIdentity(_ executable: String) async -> String? {
    let expected = URL(filePath: executable).standardizedFileURL.resolvingSymlinksInPath()
    return await MainActor.run {
      guard let application = NSWorkspace.shared.runningApplications.first(where: {
        $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == expected
      }), let launchDate = application.launchDate else { return nil }
      return String(application.processIdentifier) + ":" + String(launchDate.timeIntervalSince1970)
    }
  }

  private static func isContainerHelperRunning(_ executable: String) async -> Bool {
    let expected = URL(filePath: executable).standardizedFileURL.resolvingSymlinksInPath()
    return await MainActor.run {
      NSWorkspace.shared.runningApplications.contains { application in
        application.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == expected
      }
    }
  }

  fileprivate static func defaultCommandRunner(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) async throws -> OrchestratorCommandResult {
    try await OrchestratorProcessRunner.run(
      executable: executable, arguments: arguments, environment: environment
    )
  }
}

extension UnifiedRuntimeOrchestrator {
  fileprivate func prepareContainerForNetworkConfiguration(
    resolved: ResolvedRuntimePaths, vmPath: String, control: String
  ) async throws -> String {
    guard let helper = resolved.containerHelperBinaryPath else {
      throw UnifiedOrchestrationError.backendUnavailable("缺少容器运行组件，请重新安装完整应用。")
    }
    try requireRuntimeSettingsSupport(helper)
    let dispatcher = ContainerGuestDispatcher(
      controlBinaryPath: control, vmIdentifier: try ContainerGuestDispatcher.vmIdentifier(bundlePath: vmPath),
      commandRunner: commandRunner)
    if await helperRunningProbe(helper) {
      let status = try await commandRunner(
        control, ["status", "--hide", dispatcher.vmIdentifier], ["__DEMOAPP_TIMEOUT_SECONDS": "5"])
      try ContainerGuestDispatcher.requireAutomationAccess(status)
      guard status.exitCode == 0 else {
        throw UnifiedOrchestrationError.backendUnavailable(
          "容器引擎正在运行，但未登记所选容器或无法核验其状态。请关闭现有容器控制窗口后重试，网络配置尚未修改。")
      }
      guard status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stopped" else {
        throw UnifiedOrchestrationError.backendUnavailable("容器尚未确认完全关闭，请正常关闭 Windows 后重试，网络配置尚未修改。")
      }
    } else {
      let state = try await createAppShellBinding(vmPath: vmPath, helper: helper, title: "运行环境网络配置")
      let arguments = ["--app-shell-vm", vmPath, "--app-shell-prepare-only",
        "--window-title", "运行环境网络配置", "--window-size", configuration.appShellWindowSize,
        "--app-shell-state-file", state.stateURL.path(percentEncoded: false)]
      let result = try await commandRunner(helper, arguments, ["__DEMOAPP_DETACHED": "1"])
      guard result.exitCode == 0 else {
        throw UnifiedOrchestrationError.commandFailed("容器引擎未能登记所选容器，网络配置尚未修改，Windows 未启动。")
      }
      try await verifyContainerStopped(helper: helper, dispatcher: dispatcher)
      await appShellSessionBridge.recordHelperIdentity(await helperIdentityProbe(helper), bindingID: state.id)
    }
    try await reloadContainerNetworkConfiguration(helper: helper, vmPath: vmPath, beforeWrite: true)
    return helper
  }

  fileprivate func reloadContainerNetworkConfiguration(
    helper: String, vmPath: String, beforeWrite: Bool = false
  ) async throws {
    do {
      try await reloadContainerConfiguration(
        helper: helper, vmIdentifier: ContainerGuestDispatcher.vmIdentifier(bundlePath: vmPath),
        beforeWrite: beforeWrite)
    } catch {
      if beforeWrite {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        throw UnifiedOrchestrationError.commandFailed(
          "容器仍在运行、挂起或保留保存状态，或无法完成安全重载检查。请先恢复并正常关闭 Windows 后重试，网络配置尚未修改；若系统拒绝控制，请在隐私与安全性的自动化设置中批准。")
      }
      throw UnifiedOrchestrationError.commandFailed(
        "网络配置已写入，但容器引擎未能重新载入。请关闭容器控制组件后重试；Windows 未启动。若 macOS 拒绝控制，请在系统设置的“隐私与安全性 → 自动化”中批准后重试。")
    }
  }

  @MainActor
  public func discoverInstalledGameCandidates(
    for entry: UnifiedGameEntry, query: String? = nil
  ) async throws -> [InstalledGameCandidate] {
    try await installedGameRegistrationService().discover(for: entry, query: query)
  }

  @MainActor
  public func registerInstalledGame(
    _ entry: UnifiedGameEntry, candidate: InstalledGameCandidate
  ) async throws -> UnifiedGameEntry {
    try await installedGameRegistrationService().register(entry: entry, candidate: candidate)
  }

  @MainActor
  private func installedGameRegistrationService() -> InstalledGameRegistrationService {
    let resolved = resolvedRuntimePaths()
    return InstalledGameRegistrationService(
      libraryStore: libraryStore, resolved: resolved,
      controlBinaryPath: resolvedContainerControlBinary(resolved: resolved),
      commandRunner: commandRunner, fileManager: fileManager)
  }

  /// Adopts only an explicitly confirmed, stopped container and remembers the verified selection.
  @MainActor
  public func importPlayableContainer(
    at url: URL, confirmedStopped: Bool
  ) async throws -> ImportedPlayableContainer {
    let importer = PlayableContainerImporter(
      resolved: resolvedRuntimePaths(), selectionStorageURL: configuration.playableSelectionStorageURL,
      fileManager: fileManager, commandRunner: commandRunner)
    let result = try await importer.run(at: url, confirmedStopped: confirmedStopped)
    lastStatusMessage = "已导入所选容器。可继续配置运行环境或选择游戏主程序。"
    return result
  }
}
