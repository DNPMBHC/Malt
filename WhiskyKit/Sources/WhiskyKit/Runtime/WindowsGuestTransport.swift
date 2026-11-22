// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

func makeWindowsGuestTransport() -> any UTMGuestTransport {
  UTMAppleScriptTransport()
}

private struct UTMAppleScriptTransport: UTMGuestTransport {
  func inspect(_ identifier: String) async throws -> UTMVMSnapshot {
    let fields = try await run(Self.inspectScript, args: [identifier]).split(
      separator: "\n", omittingEmptySubsequences: false
    ).map(String.init)
    guard fields.count == 4, let status = UTMVMStatus(rawValue: fields[2].lowercased()) else {
      throw UTMGuestError.automationFailed
    }
    return UTMVMSnapshot(
      identifier: fields[0], backend: fields[1], status: status, architecture: fields[3])
  }
  func start(_ identifier: String) async throws {
    _ = try await run(Self.startScript, args: [identifier])
  }
  func stop(_ identifier: String) async throws {
    _ = try await run(Self.stopScript, args: [identifier])
  }
  func push(_ identifier: String, hostURL: URL, guestPath: String) async throws {
    _ = try await run(Self.pushScript, args: [identifier, guestPath, hostURL.path])
  }
  func execute(
    _ identifier: String, executable: String, arguments: [String], environment: [String: String]
  ) async throws -> Int32 {
    let entries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let args =
      [identifier, executable, String(arguments.count), String(entries.count)] + arguments + entries
    guard let pid = Int32(try await run(Self.executeScript, args: args)), pid > 0 else {
      throw UTMGuestError.automationFailed
    }
    return pid
  }
  func result(_ identifier: String, pid: Int32) async throws -> UTMProcessResult? {
    let fields = try await run(Self.resultScript, args: [identifier, String(pid)]).split(
      separator: "\n", omittingEmptySubsequences: false
    ).map(String.init)
    guard fields.count == 3 else { throw UTMGuestError.automationFailed }
    guard fields[0] == "1" else { return nil }
    let exit = try UTMGuestResultParser.windowsStatusCode(fields[1])
    let signal = try UTMGuestResultParser.windowsStatusCode(fields[2])
    return UTMProcessResult(exitCode: exit, signal: signal)
  }
  func terminate(_ identifier: String, pid: Int32) async throws {
    if try await result(identifier, pid: pid) != nil { return }
    let killPID = try await execute(
      identifier, executable: "taskkill.exe",
      arguments: ["/PID", String(pid), "/T", "/F"], environment: [:])
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let result = try await result(identifier, pid: killPID) {
        if result.signal == 0, result.exitCode == 0 { return }
        if try await self.result(identifier, pid: pid) != nil { return }
        throw UTMGuestError.automationFailed
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UTMGuestError.automationFailed
  }
  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    let args = [identifier, executable, String(arguments.count)] + arguments
    guard let pid = Int32(try await run(Self.executeCapturingScript, args: args)), pid > 0 else {
      throw UTMGuestError.automationFailed
    }
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard try await inspect(identifier).status == .started else {
        throw UTMGuestError.vmStopped
      }
      let raw = try await run(Self.capturedResultScript, args: [identifier, String(pid)])
      let fields = raw.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false)
        .map(String.init)
      guard fields.count == 5 else { throw UTMGuestError.automationFailed }
      if fields[0] == "1" {
        let exit = try UTMGuestResultParser.windowsStatusCode(fields[1])
        let signal = try UTMGuestResultParser.windowsStatusCode(fields[2])
        guard signal == 0, exit == 0 else { throw UTMGuestError.invalidResult }
        let decoded = Data(base64Encoded: fields[3], options: .ignoreUnknownCharacters)
        if !fields[3].isEmpty, let decoded { return decoded }
        return Data(fields[4].utf8)
      }
      try await Task.sleep(for: pollInterval)
    }
    throw RuntimeLaunchError.issue(.guestTimeout)
  }
  private func run(_ script: String, args: [String]) async throws -> String {
    do {
      return try await Task.detached(priority: .utility) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)
        else {
          throw UTMGuestError.automationFailed
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }.value
    } catch is CancellationError { throw CancellationError() } catch let error as UTMGuestError {
      throw error
    } catch { throw UTMGuestError.automationFailed }
  }

  private static let inspectScript = #"""
    on run argv
      tell application id "com.utmapp.UTM"
        set vm to virtual machine id (item 1 of argv)
        set vmBackend to backend of vm as text
        set vmArchitecture to ""
        if vmBackend is "QEMU" or vmBackend is "qemu" then
          set vmConfig to configuration of vm
          set vmArchitecture to architecture of vmConfig as text
        end if
        return (id of vm as text) & linefeed & vmBackend & linefeed & (status of vm as text) & linefeed & vmArchitecture
      end tell
    end run
    """#
  private static let startScript = #"""
    on run argv
      tell application id "com.utmapp.UTM"
        start (virtual machine id (item 1 of argv))
        return "ok"
      end tell
    end run
    """#
  private static let pushScript = #"""
    on run argv
      tell application id "com.utmapp.UTM"
        set vm to virtual machine id (item 1 of argv)
        set guestFile to open file vm at (item 2 of argv) for writing
        push guestFile from (POSIX file (item 3 of argv)) with closing
        return "ok"
      end tell
    end run
    """#
  private static let executeScript = #"""
    on run argv
      set n to (item 3 of argv) as integer
      set m to (item 4 of argv) as integer
      set args to {}
      set envs to {}
      repeat with i from 5 to (4 + n)
        set end of args to item i of argv
      end repeat
      repeat with i from (5 + n) to (4 + n + m)
        set end of envs to item i of argv
      end repeat
      tell application id "com.utmapp.UTM"
        set vm to virtual machine id (item 1 of argv)
        set p to execute of vm at (item 2 of argv) with arguments args with environment envs
        return id of p as text
      end tell
    end run
    """#
  private static let resultScript = #"""
    on run argv
      tell application id "com.utmapp.UTM"
        set vm to virtual machine id (item 1 of argv)
        set processID to (item 2 of argv) as integer
        set p to guest process id processID of vm
        set r to get result of p
        if exited of r then
          return "1" & linefeed & (exit code of r as text) & linefeed & (signal code of r as text)
        else
          return "0" & linefeed & "0" & linefeed & "0"
        end if
      end tell
    end run
    """#
  private static let stopScript = #"""
    on run argv
      tell application id "com.utmapp.UTM"
        stop (virtual machine id (item 1 of argv)) by force
        return "ok"
      end tell
    end run
    """#
  private static let executeCapturingScript = #"""
    on run argv
      set n to (item 3 of argv) as integer
      set args to {}
      repeat with i from 4 to (3 + n)
        set end of args to item i of argv
      end repeat
      tell application id "com.utmapp.UTM"
        set vm to virtual machine id (item 1 of argv)
        set p to execute of vm at (item 2 of argv) with arguments args with output capturing
        return id of p as text
      end tell
    end run
    """#
  private static let capturedResultScript = #"""
    on run argv
      tell application id "com.utmapp.UTM"
        set vm to virtual machine id (item 1 of argv)
        set processID to (item 2 of argv) as integer
        set p to guest process id processID of vm
        set r to get result of p
        if exited of r then
          set head to "1" & linefeed & (exit code of r as text) & linefeed & (signal code of r as text)
          return head & linefeed & (output data of r as text) & linefeed & (output text of r as text)
        else
          return "0" & linefeed & "0" & linefeed & "0" & linefeed & "" & linefeed & ""
        end if
      end tell
    end run
    """#
}

extension UTMGuestTransport {
  func pushCreatingParentDirectory(
    _ identifier: String, hostURL: URL, guestPath: String,
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws {
    do {
      try await push(identifier, hostURL: hostURL, guestPath: guestPath)
    } catch {
      guard let parent = Self.windowsParentDirectory(of: guestPath) else { throw error }
      let mkdirPID = try await execute(
        identifier, executable: "cmd.exe",
        arguments: ["/d", "/c", "if", "not", "exist", parent, "mkdir", parent],
        environment: [:]
      )
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard try await inspect(identifier).status == .started else {
          throw UTMGuestError.vmStopped
        }
        if let res = try await result(identifier, pid: mkdirPID) {
          guard res.signal == 0, res.exitCode == 0 else { throw error }
          try await push(identifier, hostURL: hostURL, guestPath: guestPath)
          return
        }
        try await Task.sleep(for: pollInterval)
      }
      throw RuntimeLaunchError.issue(.guestTimeout)
    }
  }

  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration
  ) async throws -> Data {
    if let appleScriptTransport = self as? UTMAppleScriptTransport {
      return try await appleScriptTransport.collectOutput(
        identifier, executable: executable, arguments: arguments,
        until: deadline, pollInterval: pollInterval)
    }
    let pid = try await execute(
      identifier, executable: executable, arguments: arguments, environment: [:])
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard try await inspect(identifier).status == .started else {
        throw UTMGuestError.vmStopped
      }
      if let res = try await result(identifier, pid: pid) {
        guard res.signal == 0, res.exitCode == 0 else { throw UTMGuestError.invalidResult }
        return Data()
      }
      try await Task.sleep(for: pollInterval)
    }
    throw RuntimeLaunchError.issue(.guestTimeout)
  }

  static func windowsParentDirectory(of guestPath: String) -> String? {
    let normalized = guestPath.replacingOccurrences(of: "/", with: "\\")
    guard let lastSlash = normalized.lastIndex(of: "\\") else { return nil }
    let parent = String(normalized[..<lastSlash])
    guard !parent.isEmpty, parent.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) == nil
    else {
      return nil
    }
    return parent
  }
}
