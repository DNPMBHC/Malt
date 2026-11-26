// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A discovered shortcut is a candidate, never proof of installation or compatibility.
public struct InstalledGameCandidate: Equatable, Sendable, Identifiable {
    public let name: String
    public let executablePath: String
    public let arguments: String
    public let workingDirectory: String
    public let vmIdentifier: String

    public var id: String {
        [vmIdentifier.lowercased(), executablePath.lowercased(), arguments, workingDirectory.lowercased()]
            .joined(separator: "|")
    }

    public init(
        name: String, executablePath: String, arguments: String = "",
        workingDirectory: String = "", vmIdentifier: String
    ) {
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.vmIdentifier = vmIdentifier
    }
}

/// Read-only guest discovery followed by explicit, verified game-entry registration.
@MainActor
public struct InstalledGameRegistrationService {
    private let libraryStore: UnifiedGameLibraryStore
    private let resolved: ResolvedRuntimePaths
    private let controlBinaryPath: String?
    private let commandRunner: UnifiedRuntimeOrchestrator.CommandRunner
    private let fileManager: FileManager

    public init(
        libraryStore: UnifiedGameLibraryStore,
        resolved: ResolvedRuntimePaths,
        controlBinaryPath: String?,
        commandRunner: @escaping UnifiedRuntimeOrchestrator.CommandRunner,
        fileManager: FileManager = .default
    ) {
        self.libraryStore = libraryStore
        self.resolved = resolved
        self.controlBinaryPath = controlBinaryPath
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    public func discover(
        for entry: UnifiedGameEntry, query: String? = nil
    ) async throws -> [InstalledGameCandidate] {
        let context = try guestContext(for: entry)
        let terms = try Self.searchTerms(query ?? entry.name)
        let script = Self.discoveryScript(terms: terms, identifier: context.identifier)
        let report: DiscoveryReport = try await execute(script, context: context, marker: "GAME_DISCOVERY_V1=")
        guard report.schemaVersion == 1,
              UUID(uuidString: report.vmIdentifier) == UUID(uuidString: context.identifier),
              report.candidates.count <= 64 else { throw Self.invalidResponse() }
        try verifyUnchangedContext(context, for: entry)
        var unique: [String: InstalledGameCandidate] = [:]
        for item in report.candidates {
            let candidate = InstalledGameCandidate(
                name: item.name, executablePath: item.executablePath,
                arguments: item.arguments, workingDirectory: item.workingDirectory ?? "",
                vmIdentifier: context.identifier)
            try Self.validate(candidate, identifier: context.identifier)
            unique[candidate.id] = candidate
        }
        return unique.values.sorted {
            ($0.name.lowercased(), $0.executablePath.lowercased(), $0.arguments, $0.workingDirectory.lowercased())
                < ($1.name.lowercased(), $1.executablePath.lowercased(), $1.arguments, $1.workingDirectory.lowercased())
        }
    }

    /// Requires an explicit candidate; no first-match selection or automatic ready transition.
    @discardableResult
    public func register(
        entry: UnifiedGameEntry, candidate: InstalledGameCandidate
    ) async throws -> UnifiedGameEntry {
        let context = try guestContext(for: entry)
        try Self.validate(candidate, identifier: context.identifier)
        let previous = libraryStore.entries.first { $0.id == entry.id }
        guard previous == nil || previous == entry else {
            throw UnifiedOrchestrationError.backendUnavailable("游戏条目已更新，请刷新后重新扫描入口。")
        }
        let literal = ContainerGuestDispatcher.powerShellLiteral(candidate.executablePath)
        let workingDirectory = candidate.workingDirectory.isEmpty
            ? Self.parentDirectory(of: candidate.executablePath) : candidate.workingDirectory
        let directoryLiteral = ContainerGuestDispatcher.powerShellLiteral(workingDirectory)
        let script = """
            $ErrorActionPreference='Stop';
            $target=\(literal);
            $exists=(Test-Path -LiteralPath $target -PathType Leaf);
            $directory=\(directoryLiteral);
            $directoryExists=(Test-Path -LiteralPath $directory -PathType Container);
            $fullPath=''; $fullDirectory='';
            if ($exists) { $fullPath=(Get-Item -LiteralPath $target -Force).FullName };
            if ($directoryExists) { $fullDirectory=(Get-Item -LiteralPath $directory -Force).FullName };
            $report=@{
                schemaVersion=1; vmIdentifier='\(context.identifier)'; exists=[bool]$exists; executablePath=$fullPath;
                directoryExists=[bool]$directoryExists; workingDirectory=$fullDirectory
            };
            Write-Output ('GAME_ENTRY_V1=' + ($report | ConvertTo-Json -Compress));
            """
        let report: EntryReport = try await execute(script, context: context, marker: "GAME_ENTRY_V1=")
        guard report.schemaVersion == 1,
              UUID(uuidString: report.vmIdentifier) == UUID(uuidString: context.identifier),
              report.exists, report.directoryExists,
              Self.sameWindowsPath(report.workingDirectory, workingDirectory),
              Self.sameWindowsPath(report.executablePath, candidate.executablePath) else {
            throw UnifiedOrchestrationError.backendUnavailable("所选程序未在当前运行环境中核验，请重新扫描并选择真实游戏入口。")
        }
        try Task.checkCancellation()
        try verifyUnchangedContext(context, for: entry)
        guard libraryStore.entries.first(where: { $0.id == entry.id }) == previous else {
            throw UnifiedOrchestrationError.backendUnavailable("游戏条目已被其他操作更新，请刷新后重新选择入口。")
        }
        var registered = entry
        registered.executablePath = report.executablePath
        registered.launchArguments = candidate.arguments.isEmpty ? nil : candidate.arguments
        registered.launchWorkingDirectory = report.workingDirectory
        registered.vmBundlePath = context.bundlePath
        registered.installationState = .ready
        try persistVerified(registered)
        return registered
    }

    private func persistVerified(_ registered: UnifiedGameEntry) throws {
        let originalEntries = libraryStore.entries
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(registered)
        libraryStore.upsert(registered)
        guard let data = try? Data(contentsOf: libraryStore.storageURL),
              let persisted = try? decoder.decode([UnifiedGameEntry].self, from: data),
              let saved = persisted.first(where: { $0.id == registered.id }),
              let savedData = try? encoder.encode(saved), savedData == expected else {
            libraryStore.entries = originalEntries
            throw UnifiedOrchestrationError.commandFailed("游戏入口已核验，但无法保存游戏库。请检查应用数据目录的写入权限后重试。")
        }
    }

    private struct GuestContext {
        let bundlePath: String
        let identifier: String
        let controlBinary: String
        let canonicalBundleURL: URL
    }

    private func verifyUnchangedContext(_ context: GuestContext, for entry: UnifiedGameEntry) throws {
        let current = try guestContext(for: entry)
        guard current.canonicalBundleURL == context.canonicalBundleURL,
              UUID(uuidString: current.identifier) == UUID(uuidString: context.identifier) else {
            throw UnifiedOrchestrationError.backendUnavailable("查询期间运行环境已变化，请刷新并重新扫描，未保存游戏入口。")
        }
    }

    private func guestContext(for entry: UnifiedGameEntry) throws -> GuestContext {
        guard entry.engineKind == .antiCheatVM else {
            throw UnifiedOrchestrationError.backendUnavailable("自动扫描当前适用于 Windows 容器；原生转译模式请在对应环境中选择游戏入口。")
        }
        guard let bundlePath = entry.vmBundlePath ?? resolved.playableVMBundlePath,
              UnifiedRuntimeDiscovery.isUsablePlayableVMBundle(bundlePath, fileManager: fileManager) else {
            throw UnifiedOrchestrationError.backendUnavailable("请先选择可游玩的 Windows 运行环境。")
        }
        guard let controlBinaryPath,
              fileManager.isExecutableFile(atPath: controlBinaryPath) else {
            throw UnifiedOrchestrationError.backendUnavailable("缺少运行环境控制组件，请安装完整应用。")
        }
        return try GuestContext(
            bundlePath: bundlePath,
            identifier: ContainerGuestDispatcher.vmIdentifier(bundlePath: bundlePath),
            controlBinary: controlBinaryPath,
            canonicalBundleURL: URL(filePath: bundlePath).resolvingSymlinksInPath().standardizedFileURL)
    }

    private func execute<Report: Decodable>(
        _ script: String, context: GuestContext, marker: String
    ) async throws -> Report {
        try Task.checkCancellation()
        let result = try await commandRunner(
            context.controlBinary,
            ["exec", "--hide", context.identifier, "--cmd", "powershell.exe", "-NoProfile",
             "-NonInteractive", "-EncodedCommand", ContainerGuestDispatcher.encodedPowerShell(script)],
            ["__DEMOAPP_TIMEOUT_SECONDS": "30"])
        try Task.checkCancellation()
        try ContainerGuestDispatcher.requireAutomationAccess(result)
        guard result.exitCode == 0 else {
            throw UnifiedOrchestrationError.commandFailed("无法读取游戏入口。请先启动所选运行环境、登录 Windows 并确认来宾工具可用。")
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(marker) }
        guard result.stdout.utf8.count <= 262_144, lines.count == 1,
              let line = lines.first,
              let data = String(line.dropFirst(marker.count)).data(using: .utf8),
              let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw Self.invalidResponse()
        }
        return report
    }

    private static func validate(_ candidate: InstalledGameCandidate, identifier: String) throws {
        let path = candidate.executablePath
        guard UUID(uuidString: candidate.vmIdentifier) == UUID(uuidString: identifier),
              UUID(uuidString: identifier) != nil,
              safeText(candidate.name, limit: 256), !candidate.name.isEmpty,
              safeText(path, limit: 4096), safeText(candidate.arguments, limit: 8192),
              candidate.workingDirectory.isEmpty || validDirectoryPath(candidate.workingDirectory),
              path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil,
              path.lowercased().hasSuffix(".exe"),
              !path.contains("\""), !path.contains("*"), !path.contains("?"),
              !path.dropFirst(2).contains(":"),
              !path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).contains("..") else {
            throw UnifiedOrchestrationError.backendUnavailable("游戏入口无效或属于其他运行环境，请重新扫描并选择。")
        }
    }

    private static func validDirectoryPath(_ path: String) -> Bool {
        safeText(path, limit: 4096)
            && path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
            && !path.contains("\"") && !path.contains("*") && !path.contains("?")
            && !path.dropFirst(2).contains(":")
            && !path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).contains("..")
    }

    private static func parentDirectory(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "/", with: "\\")
        guard let separator = normalized.lastIndex(of: "\\") else { return "" }
        let result = String(normalized[..<separator])
        return result.count == 2 ? result + "\\" : result
    }

    private static func safeText(_ value: String, limit: Int) -> Bool {
        value.count <= limit && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func sameWindowsPath(_ lhs: String, _ rhs: String) -> Bool {
        lhs.replacingOccurrences(of: "/", with: "\\").caseInsensitiveCompare(
            rhs.replacingOccurrences(of: "/", with: "\\")) == .orderedSame
    }

    private static func invalidResponse() -> UnifiedOrchestrationError {
        .commandFailed("运行环境返回了无效的游戏入口信息，未更新游戏库，请重试。")
    }

    static func searchTerms(_ query: String) throws -> [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, safeText(value, limit: 128) else {
            throw UnifiedOrchestrationError.backendUnavailable("请输入至少两个字符的游戏名称后重新扫描。")
        }
        if value.localizedCaseInsensitiveContains("valorant") || value.contains("无畏契约") {
            return ["VALORANT", "无畏契约"]
        }
        return [value]
    }

}

private extension InstalledGameRegistrationService {
    // Resolve shortcut metadata only; never execute shortcut contents or uninstall commands.
    // Keep the bounded guest query together so the PowerShell can be audited directly.
    // swiftlint:disable:next function_body_length
    static func discoveryScript(terms: [String], identifier: String) -> String {
        let literals = terms.map(ContainerGuestDispatcher.powerShellLiteral).joined(separator: ",")
        return """
            $ErrorActionPreference='Stop';
            $terms=@(\(literals));
            $user=(Get-CimInstance Win32_ComputerSystem).UserName;
            if ([string]::IsNullOrWhiteSpace($user)) { throw '请先登录 Windows 桌面。' };
            $account=New-Object -TypeName System.Security.Principal.NTAccount -ArgumentList $user;
            $sid=$account.Translate([System.Security.Principal.SecurityIdentifier]).Value;
            $profileKey='HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\'+$sid;
            $profilePath=(Get-ItemProperty -LiteralPath $profileKey).ProfileImagePath;
            $profile=[Environment]::ExpandEnvironmentVariables($profilePath);
            if ([string]::IsNullOrWhiteSpace($profile)) { throw '无法读取当前用户的游戏快捷方式。' };
            $programs=Join-Path $profile 'AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs';
            $roots=@([Environment]::GetFolderPath('CommonPrograms'), $programs);
            $shell=New-Object -ComObject WScript.Shell;
            $found=New-Object 'System.Collections.Generic.List[object]';
            foreach ($root in $roots) {
                if ([string]::IsNullOrWhiteSpace($root)) { continue };
                if (!(Test-Path -LiteralPath $root -PathType Container)) { continue };
                $links=@(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue);
                foreach ($link in $links) {
                    if ($found.Count -ge 64) { break };
                    $matched=$false;
                    foreach ($term in $terms) {
                        if ($link.BaseName.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $matched=$true; break;
                        };
                    };
                    if (!$matched) { continue };
                    try {
                        $shortcut=$shell.CreateShortcut($link.FullName);
                        $target=[Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath);
                        if ($target -notmatch '^[A-Za-z]:[\\\\/]') { continue };
                        if ([IO.Path]::GetExtension($target) -ine '.exe') { continue };
                        $stem=[IO.Path]::GetFileNameWithoutExtension($target);
                        if ($stem -match '^(setup|install|installer|unins|uninstall)([0-9_.-].*)?$') { continue };
                        if (!(Test-Path -LiteralPath $target -PathType Leaf)) { continue };
                        $working=[Environment]::ExpandEnvironmentVariables([string]$shortcut.WorkingDirectory);
                        if ([string]::IsNullOrWhiteSpace($working)) { $working=[IO.Path]::GetDirectoryName($target) };
                        if (!(Test-Path -LiteralPath $working -PathType Container)) { continue };
                        $found.Add(@{
                            name=$link.BaseName; executablePath=(Get-Item -LiteralPath $target -Force).FullName;
                            arguments=[string]$shortcut.Arguments;
                            workingDirectory=(Get-Item -LiteralPath $working -Force).FullName
                        });
                    } catch { continue };
                };
            };
            $report=@{schemaVersion=1; vmIdentifier='\(identifier)'; candidates=@($found.ToArray())};
            Write-Output ('GAME_DISCOVERY_V1=' + ($report | ConvertTo-Json -Depth 4 -Compress));
            """
    }

    private struct DiscoveryReport: Decodable {
        let schemaVersion: Int
        let vmIdentifier: String
        let candidates: [ShortcutReport]
    }

    private struct ShortcutReport: Decodable {
        let name: String
        let executablePath: String
        let arguments: String
        let workingDirectory: String?
    }

    private struct EntryReport: Decodable {
        let schemaVersion: Int
        let vmIdentifier: String
        let exists: Bool
        let executablePath: String
        let directoryExists: Bool
        let workingDirectory: String
    }
}
