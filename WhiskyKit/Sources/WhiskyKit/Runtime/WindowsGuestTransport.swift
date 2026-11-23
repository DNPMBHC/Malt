// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

func makeWindowsGuestTransport() -> any UTMGuestTransport {
  UTMAppleScriptTransport()
}

struct UTMAppleScriptTransport: UTMGuestTransport {
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
        if try await self.result(identifier, pid: pid) != nil { return }
        if result.signal != 0 || result.exitCode != 0 { throw UTMGuestError.automationFailed }
        // taskkill success alone does not prove the selected QGA control process was reaped.
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UTMGuestError.automationFailed
  }
  private static func parseCapturedResult(
    _ raw: String, expectedRequestID: String?
  ) throws -> Data? {
    let fields = raw.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false)
      .map(String.init)
    guard let state = fields.first else { throw UTMGuestError.automationFailed }
    guard state == "1" else { return nil }
    guard fields.count >= 3 else { throw UTMGuestError.automationFailed }
    let exit = try UTMGuestResultParser.windowsStatusCode(fields[1])
    let signal = try UTMGuestResultParser.windowsStatusCode(fields[2])
    let base64Text = fields.count > 3 ? fields[3] : ""
    let decoded =
      base64Text.isEmpty
      ? nil : Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters)
    let data = decoded ?? Data((fields.count > 4 ? fields[4] : "").utf8)
    if let expectedRequestID, !capturedResponseMatches(data, requestID: expectedRequestID) {
      // A reused QGA PID can still have an earlier completion cached. Request UUIDs
      // keep that record from becoming output or lifecycle facts for this operation.
      return nil
    }
    guard signal == 0, exit == 0 else { throw UTMGuestError.invalidResult }
    return data
  }

  func collectOutput(
    _ identifier: String, executable: String, arguments: [String],
    until deadline: ContinuousClock.Instant, pollInterval: Duration,
    expectedRequestID: String? = nil
  ) async throws -> Data {
    let args = [identifier, executable, String(arguments.count)] + arguments
    guard let pid = Int32(try await run(Self.executeCapturingScript, args: args, until: deadline)),
      pid > 0
    else {
      throw UTMGuestError.automationFailed
    }
    do {
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard try await inspect(identifier).status == .started else {
          throw UTMGuestError.vmStopped
        }
        let raw = try await run(
          Self.capturedResultScript, args: [identifier, String(pid)], until: deadline)
        if let data = try Self.parseCapturedResult(raw, expectedRequestID: expectedRequestID) {
          return data
        }
        try await Task.sleep(for: pollInterval)
      }
      throw RuntimeLaunchError.issue(.guestTimeout)
    } catch {
      if expectedRequestID == nil {
        let cleanup = Task {
          try await UTMGuestOperationDeadline.$value.withValue(.now + .seconds(10)) {
            try await terminate(identifier, pid: pid)
          }
        }
        try? await cleanup.value
      }
      // Interactive helper commands are bounded natively. Their target cleanup uses the
      // request UUID and authenticated Job, never a potentially reused capture PID.
      throw error
    }
  }
  static func capturedResponseMatches(_ data: Data, requestID: String) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let actualID = object["requestID"] as? String
    else { return false }
    return actualID.caseInsensitiveCompare(requestID) == .orderedSame
  }

  private func run(
    _ script: String, args: [String], until requestedDeadline: ContinuousClock.Instant? = nil
  ) async throws -> String {
    let localDeadline = requestedDeadline ?? (.now + .seconds(10))
    let deadline = min(localDeadline, UTMGuestOperationDeadline.value ?? localDeadline)
    do {
      let result = try await UTMHostProcessRunner.run(
        executable: URL(fileURLWithPath: "/usr/bin/osascript"),
        arguments: ["-e", script, "--"] + args, until: deadline,
        maximumOutputBytes: 3 * 1024 * 1024)
      guard result.terminationReason == .exit, result.terminationStatus == 0,
        let text = String(data: result.standardOutput, encoding: .utf8)
      else { throw UTMGuestError.automationFailed }
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch is CancellationError { throw CancellationError() } catch UTMHostProcessError.timedOut {
      throw RuntimeLaunchError.issue(.guestTimeout)
    } catch let error as UTMGuestError { throw error } catch {
      throw UTMGuestError.automationFailed
    }
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
      // The script is fixed. The path is UTF-8 data, never PowerShell source.
      let script = """
        try { $p = [Text.Encoding]::UTF8.GetString(\
        [Convert]::FromBase64String($env:DEMO_DIRECTORY_BASE64)); \
        [IO.Directory]::CreateDirectory($p) | Out-Null; exit 0 } catch { exit 1 }
        """
      let encodedScript = Data(
        script.utf16.flatMap {
          [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
        }
      ).base64EncodedString()
      let mkdirPID = try await execute(
        identifier, executable: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#,
        arguments: ["-NoProfile", "-NonInteractive", "-EncodedCommand", encodedScript],
        environment: ["DEMO_DIRECTORY_BASE64": Data(parent.utf8).base64EncodedString()])
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

// Task-local deadlines reach every in-flight AppleScript process in an operation.
enum UTMGuestOperationDeadline {
  @TaskLocal static var value: ContinuousClock.Instant?
}
