// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded guest-agent dispatch for explicitly selected installers and game executables.

import Foundation

/// A submitted installer is separate from a configured, launchable game.
public enum UnifiedInstallationState: String, Codable, Sendable {
  case installerRequested
  case ready
}

// Keep this established public API name descriptive and source-compatible.
// swiftlint:disable type_name
/// Read-back result for a stopped container's reversible network configuration change.
public struct NativeContainerNetworkConfigurationResult: Equatable, Sendable {
  public let networkMode: String
  public let restored: Bool
  public let changed: Bool
}
// swiftlint:enable type_name

// Guest command templates remain adjacent to their transaction and failure cleanup.
// swiftlint:disable type_body_length
struct ContainerGuestDispatcher: Sendable {
  typealias Runner = UnifiedRuntimeOrchestrator.CommandRunner

  let controlBinaryPath: String
  let vmIdentifier: String
  let commandRunner: Runner
  var readinessTimeout: TimeInterval = 90

  static func vmIdentifier(bundlePath: String) throws -> String {
    let configURL = URL(filePath: bundlePath).appending(path: "config.plist")
    guard let data = try? Data(contentsOf: configURL),
      let config = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let information = config["Information"] as? [String: Any],
      let identifier = information["UUID"] as? String,
      UUID(uuidString: identifier) != nil
    else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "容器配置缺少有效标识。请重新导入可游玩容器，不要选择系统模板或备份。"
      )
    }
    return identifier
  }

  static func isWindowsExecutablePath(_ path: String) -> Bool {
    guard !path.contains(where: { $0.isNewline || $0.asciiValue == 0 }), path.count > 3 else {
      return false
    }
    let drivePath = path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    return drivePath || path.hasPrefix(#"\\"#)
  }

  static func powerShellLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
  }

  static func encodedPowerShell(_ script: String) -> String {
    Data(
      script.utf16.flatMap { value in
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
      }
    ).base64EncodedString()
  }

  static func requireAutomationAccess(_ result: OrchestratorCommandResult) throws {
    let detail = (result.stdout + "\n" + result.stderr).lowercased()
    if [
      "-1743", "-1744", "automation_permission_denied", "erraeeventnotpermitted",
      "not authorized to send apple events",
      "not authorised to send apple events"
    ].contains(where: detail.contains) {
      throw UnifiedOrchestrationError.backendUnavailable(
        "macOS 尚未允许应用控制容器引擎。请打开“系统设置 → 隐私与安全性 → 自动化”，允许此应用控制容器运行组件，然后重试。若列表中没有此项，请从应用内重试一次以触发授权提示。"
      )
    }
  }

  func waitUntilReady() async throws {
    let deadline = Date().addingTimeInterval(readinessTimeout)
    while Date() < deadline {
      try Task.checkCancellation()
      let result: OrchestratorCommandResult?
      do {
        result = try await commandRunner(
          controlBinaryPath,
          ["exec", "--hide", vmIdentifier, "--cmd", "cmd.exe", "/c", "echo", "GUEST_AGENT_READY"],
          ["__DEMOAPP_TIMEOUT_SECONDS": String(min(5, max(0.1, deadline.timeIntervalSinceNow)))]
        )
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        // A cold guest can time out individual probes before its agent becomes available.
        result = nil
      }
      if let result {
        try Self.requireAutomationAccess(result)
        if result.exitCode == 0,
          result.stdout.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "GUEST_AGENT_READY"
          }) {
          return
        }
      }
      let remaining = deadline.timeIntervalSinceNow
      if remaining > 0 { try await Task.sleep(for: .seconds(min(1.5, remaining))) }
    }
    throw UnifiedOrchestrationError.backendUnavailable(
      "容器尚未就绪或未安装来宾工具。请启动容器、安装来宾工具并登录 Windows 桌面后重试。"
    )
  }

  // PowerShell templates dominate this transaction; preserve their auditable literal form.
  // swiftlint:disable function_body_length line_length cyclomatic_complexity
  func submit(
    targetExecutable: String,
    targetArguments: String = "",
    targetWorkingDirectory: String = "",
    kioskScriptPath: String,
    installerURL: URL? = nil,
    displayPolicy: UnifiedDisplayPolicy = .automatic,
    appShellSession: GuestAppShellSession? = nil
  ) async throws {
    guard !targetArguments.contains(where: { $0.asciiValue == 0 }),
      !targetWorkingDirectory.contains(where: { $0.asciiValue == 0 }) else {
      throw UnifiedOrchestrationError.backendUnavailable("启动参数包含无效字符。")
    }
    if let session = appShellSession {
      guard installerURL == nil, UUID(uuidString: session.vmIdentifier) == UUID(uuidString: vmIdentifier),
        GuestAppShellSession.normalizedPath(session.targetExecutable)
          == GuestAppShellSession.normalizedPath(targetExecutable)
      else { throw GuestAppShellValidationError.invalidResponse }
    }
    let token = appShellSession?.id.uuidString ?? UUID().uuidString
    let guestRoot = appShellSession?.guestRoot ?? (#"C:\ProgramData\DemoApp\Sessions\"# + token)
    let kioskPath = guestRoot + #"\kiosk.ps1"#
    let receiptPath = guestRoot + #"\launch-receipt.json"#
    let displayReceiptPath = guestRoot + #"\display-receipt.json"#
    let displayScriptPath = guestRoot + #"\display.ps1"#
    let taskName = "DemoApp-" + token
    let target: String
    if let installerURL {
      let suffix = installerURL.pathExtension.lowercased()
      guard suffix == "exe" || suffix == "msi" else {
        throw UnifiedOrchestrationError.backendUnavailable("请选择 .exe 或 .msi 安装器。")
      }
      target = guestRoot + "\\installer." + suffix
    } else {
      guard Self.isWindowsExecutablePath(targetExecutable) else {
        throw UnifiedOrchestrationError.backendUnavailable(
          "请选择容器内已安装游戏的 Windows 完整路径，不能将 macOS 安装器路径作为游戏入口。"
        )
      }
      target = targetExecutable
    }
    let displayScript = try Self.displayApplyScript(for: displayPolicy)
    let localDisplayScript: URL?
    if let displayScript {
      let url = FileManager.default.temporaryDirectory.appending(path: "guest-display-\(token).ps1")
      try Data(displayScript.utf8).write(to: url, options: .atomic)
      localDisplayScript = url
    } else {
      localDisplayScript = nil
    }
    let localObserverScript: URL?
    if let appShellSession {
      let url = FileManager.default.temporaryDirectory.appending(path: "guest-observer-\(token).ps1")
      // Windows PowerShell 5.1 needs a BOM to preserve non-ASCII executable paths.
      let script = Data([0xEF, 0xBB, 0xBF]) + Data(GuestAppShellScripts.observer(for: appShellSession).utf8)
      try script.write(to: url, options: .atomic)
      localObserverScript = url
    } else { localObserverScript = nil }
    defer {
      if let localDisplayScript { try? FileManager.default.removeItem(at: localDisplayScript) }
      if let localObserverScript { try? FileManager.default.removeItem(at: localObserverScript) }
    }
    let requiredBytes = (try? installerURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let literalRoot = Self.powerShellLiteral(guestRoot)
    let prepare = """
      $ErrorActionPreference='Stop';
      $user=(Get-CimInstance Win32_ComputerSystem).UserName;
      if ([string]::IsNullOrWhiteSpace($user)) { throw '请先登录 Windows 桌面。' };
      if ((Get-PSDrive -Name C).Free -lt \(requiredBytes + 536_870_912)) { throw '容器磁盘空间不足。' };
      $root=\(literalRoot);
      New-Item -ItemType Directory -Path $root -Force | Out-Null;
      & "$env:SystemRoot\\System32\\icacls.exe" $root '/grant' ($user+':(OI)(CI)M') | Out-Null;
      if ($LASTEXITCODE -ne 0) { throw '无法准备安装器目录权限。' };
      """
    do {
      try await runPowerShell(prepare)
      try await push(localURL: URL(filePath: kioskScriptPath), guestPath: kioskPath)
      if let installerURL { try await push(localURL: installerURL, guestPath: target) }
      if let localDisplayScript {
        try await push(localURL: localDisplayScript, guestPath: displayScriptPath)
      }
      if let localObserverScript, let appShellSession {
        try await push(localURL: localObserverScript, guestPath: appShellSession.observerPath)
      }

      let displaySetup: String
      let displayFailure: String
      let displayRestore: String
      let displayConfirmation: String
      switch displayPolicy {
      case .automatic:
        displaySetup = ""
        displayFailure = ""
        displayRestore = ""
        displayConfirmation = ""
      case .fixed(let width, let height):
        displaySetup = """
          $displaySnapshot = (& \(Self.powerShellLiteral(displayScriptPath)) | ConvertFrom-Json);
          $displaySnapshot | ConvertTo-Json -Compress | Set-Content -LiteralPath \(Self.powerShellLiteral(displayReceiptPath)) -Encoding UTF8;
          if (!$displaySnapshot.ok -or [int]$displaySnapshot.current_width -ne \(width) -or [int]$displaySnapshot.current_height -ne \(height)) {
              throw 'fixedDisplayUnsupported';
          };
          $displayReady=$true;
          """
        displayFailure = """
          if (!$displayReady) { $displayFailed=$true };
          """
        displayRestore = """
          if ($null -ne $displaySnapshot -and [int]$displaySnapshot.previous_width -gt 0 -and [int]$displaySnapshot.previous_height -gt 0 -and [int]$displaySnapshot.previous_refresh_hz -gt 0) {
              try {
                  $restoreCode=[GuestDisplayModeHelper]::Apply([string]$displaySnapshot.device_name, [uint32]$displaySnapshot.previous_width, [uint32]$displaySnapshot.previous_height, [uint32]$displaySnapshot.previous_refresh_hz);
                  $restored=[GuestDisplayModeHelper]::Query([string]$displaySnapshot.device_name, -1);
                  $displayRestored=($restoreCode -eq 0 -and [int]$restored.width -eq [int]$displaySnapshot.previous_width -and [int]$restored.height -eq [int]$displaySnapshot.previous_height);
              } catch { $displayRestored=$false };
          };
          if ($displayFailed) {
              @{ state='failed'; failureStage='display'; displayRestored=$displayRestored } | ConvertTo-Json -Compress | Set-Content -LiteralPath \(Self.powerShellLiteral(receiptPath)) -Encoding UTF8;
          };
          """
        displayConfirmation = """
          if (!(Test-Path -LiteralPath \(Self.powerShellLiteral(displayReceiptPath)))) { throw '固定分辨率未回读。' };
          $display=Get-Content -LiteralPath \(Self.powerShellLiteral(displayReceiptPath)) -Raw | ConvertFrom-Json;
          if (!$display.ok -or [int]$display.current_width -ne \(width) -or [int]$display.current_height -ne \(height)) {
              Write-Output 'FIXED_DISPLAY_POLICY_FAILED'; throw '固定分辨率未生效。';
          };
          """
      }
      let observerSetup: String
      let observerCleanup: String
      if let session = appShellSession {
        observerSetup = """
          @{sessionStartedAt=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0)} | ConvertTo-Json -Compress | Set-Content -LiteralPath \(Self.powerShellLiteral(session.contextPath)) -Encoding UTF8;
          $observer=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\(Self.powerShellLiteral(session.observerPath))) -WindowStyle Hidden -PassThru;
          """
        observerCleanup = """
          New-Item -ItemType File -Path \(Self.powerShellLiteral(session.stopPath)) -Force -ErrorAction SilentlyContinue | Out-Null;
          if ($null -ne $observer) {
              try { if (!$observer.WaitForExit(1500)) { $observer.Kill() } } catch {};
          };
          """
      } else { observerSetup = ""; observerCleanup = "" }
      let actionScript = """
        $ErrorActionPreference='Stop';
        $displaySnapshot=$null; $displayReady=$false; $displayFailed=$false; $displayRestored=$false; $observer=$null;
        try {
            \(displaySetup)
            \(observerSetup)
            & \(Self.powerShellLiteral(kioskPath)) -Mode Enter -PreserveDesktopState -TargetExecutable \(Self.powerShellLiteral(target)) -TargetArguments \(Self.powerShellLiteral(targetArguments)) -TargetWorkingDirectory \(Self.powerShellLiteral(targetWorkingDirectory)) -StatePath \(Self.powerShellLiteral(guestRoot + "\\state.json")) -SignalOutputPath \(Self.powerShellLiteral(guestRoot + "\\signal.json")) -LaunchReceiptPath \(Self.powerShellLiteral(receiptPath));
        } catch {
            \(displayFailure)
            throw;
        } finally {
            \(observerCleanup)
            \(displayRestore)
            Start-Sleep -Seconds 5;
            Remove-Item -LiteralPath \(literalRoot) -Recurse -Force -ErrorAction SilentlyContinue;
        }
        """
      let actionArguments =
        "-NoProfile -ExecutionPolicy Bypass -EncodedCommand "
        + Self.encodedPowerShell(actionScript)
      let schedule = """
        $ErrorActionPreference='Stop';
        $user=(Get-CimInstance Win32_ComputerSystem).UserName;
        if ([string]::IsNullOrWhiteSpace($user)) { throw '请先登录 Windows 桌面。' };
        if (!(Test-Path -LiteralPath \(Self.powerShellLiteral(target)) -PathType Leaf)) {
            throw '所选游戏或安装器在容器中不存在。'
        };
        $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument \(Self.powerShellLiteral(actionArguments));
        $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited;
        $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries;
        $task=New-ScheduledTask -Action $action -Principal $principal -Settings $settings;
        $confirmed=$false;
        try {
            Register-ScheduledTask -TaskName \(Self.powerShellLiteral(taskName)) -InputObject $task -Force | Out-Null;
            Start-ScheduledTask -TaskName \(Self.powerShellLiteral(taskName));
            $deadline=[DateTime]::UtcNow.AddSeconds(180);
            while ([DateTime]::UtcNow -lt $deadline) {
                if (Test-Path -LiteralPath \(Self.powerShellLiteral(receiptPath))) {
                    $receipt=Get-Content -LiteralPath \(Self.powerShellLiteral(receiptPath)) -Raw | ConvertFrom-Json;
                    if ($receipt.state -eq 'failed') {
                        if ($receipt.failureStage -eq 'display') { Write-Output 'FIXED_DISPLAY_POLICY_FAILED' };
                        throw '目标程序启动失败。';
                    };
                    if ($receipt.state -eq 'started' -and [int]$receipt.pid -gt 0 -and $receipt.targetExecutable -eq \(Self.powerShellLiteral(target))) {
                        \(displayConfirmation)
                        $confirmed=$true; break;
                    };
                };
                Start-Sleep -Milliseconds 100;
            };
            if (!$confirmed) { throw '未收到目标程序的启动确认。请完成 Windows 中的权限或安全确认后重试。' };
        } finally {
            if (!$confirmed) {
                Stop-ScheduledTask -TaskName \(Self.powerShellLiteral(taskName)) -ErrorAction SilentlyContinue;
            };
            Unregister-ScheduledTask -TaskName \(Self.powerShellLiteral(taskName)) -Confirm:$false -ErrorAction SilentlyContinue;
        };

        """
      try await runPowerShell(schedule, timeout: 195)
    } catch {
      let cleanup = """
        Stop-ScheduledTask -TaskName \(Self.powerShellLiteral(taskName)) -ErrorAction SilentlyContinue;
        Unregister-ScheduledTask -TaskName \(Self.powerShellLiteral(taskName)) -Confirm:$false -ErrorAction SilentlyContinue;
        Remove-Item -LiteralPath \(literalRoot) -Recurse -Force -ErrorAction SilentlyContinue;
        """
      let cleanupTask = Task.detached { try? await runPowerShell(cleanup) }
      await cleanupTask.value
      throw error
    }
  }

  static func displayApplyScript(for policy: UnifiedDisplayPolicy) throws -> String? {
    guard case .fixed(let width, let height) = policy else { return nil }
    let script = try GuestDisplaySyncScriptBuilder.applyScript(
      for: GuestDisplayMode(width: width, height: height, refreshRateHz: 240))
    // The resolution selector never asks to raise the guest's current refresh rate.
    return script.replacingOccurrences(of: "[uint32]240);", with: "[uint32]$before.frequency);")
  }

  // swiftlint:enable function_body_length line_length cyclomatic_complexity

  private func push(localURL: URL, guestPath: String) async throws {
    let result = try await commandRunner(
      controlBinaryPath, ["file", "push", "--hide", vmIdentifier, guestPath],
      [
        "__DEMOAPP_STDIN_FILE": localURL.path(percentEncoded: false),
        "__DEMOAPP_TIMEOUT_SECONDS": "180"
      ]
    )
    try Self.requireAutomationAccess(result)
    guard result.exitCode == 0 else {
      throw UnifiedOrchestrationError.commandFailed(
        "文件传输到容器失败。请检查来宾工具、磁盘可用空间及所选文件的读取权限。"
      )
    }
  }

  private func runPowerShell(_ script: String, timeout: TimeInterval = 15) async throws {
    let encoded = Self.encodedPowerShell(script)
    guard encoded.count < 28_000 else {
      throw UnifiedOrchestrationError.backendUnavailable("目标路径过长，请将游戏或安装器移至较短路径后重试。")
    }
    let result = try await commandRunner(
      controlBinaryPath,
      [
        "exec", "--hide", vmIdentifier, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand",
        encoded
      ],
      ["__DEMOAPP_TIMEOUT_SECONDS": String(timeout)]
    )
    try Self.requireAutomationAccess(result)
    guard result.exitCode == 0 else {
      if result.stdout.contains("FIXED_DISPLAY_POLICY_FAILED") {
        throw UnifiedOrchestrationError.backendUnavailable(
          "容器无法应用所选固定分辨率。请切换自动模式，或选择 Windows 当前支持的分辨率。")
      }
      throw UnifiedOrchestrationError.commandFailed(
        "容器未接受启动请求。请确认已登录 Windows 桌面、目标文件存在且来宾工具可用。"
      )
    }
  }
}

// swiftlint:enable type_body_length
