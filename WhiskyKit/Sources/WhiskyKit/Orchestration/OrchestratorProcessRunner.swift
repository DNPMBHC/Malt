// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded process execution with file-backed output and explicit background launch semantics.

import Darwin
import Foundation

private final class DetachedRuntimeProcesses: @unchecked Sendable {
  static let shared = DetachedRuntimeProcesses()
  private let lock = NSLock()
  private var processes: [UUID: Process] = [:]

  func retain(_ process: Process, id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    processes[id] = process
  }

  func release(id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    processes.removeValue(forKey: id)
  }
}

enum OrchestratorProcessRunner {
  static func run(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) async throws -> OrchestratorCommandResult {
    let task = Task.detached(priority: .userInitiated) {
      try execute(executable: executable, arguments: arguments, environment: environment)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func execute(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) throws -> OrchestratorCommandResult {
    try Task.checkCancellation()
    let fileManager = FileManager.default
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment where !key.hasPrefix("__DEMOAPP_") { merged[key] = value }
    process.environment = merged
    let detached = environment["__DEMOAPP_DETACHED"] == "1"
    let timeout = min(600, max(1, Double(environment["__DEMOAPP_TIMEOUT_SECONDS"] ?? "120") ?? 120))
    let id = UUID()
    let outputDirectory = fileManager.temporaryDirectory.appending(
      path: "runtime-command-\(id.uuidString)")
    try fileManager.createDirectory(
      at: outputDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: outputDirectory) }
    let stdoutURL = outputDirectory.appending(path: "stdout")
    let stderrURL = outputDirectory.appending(path: "stderr")
    fileManager.createFile(
      atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    fileManager.createFile(
      atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    process.standardOutput = detached ? FileHandle.nullDevice : stdout
    process.standardError = detached ? FileHandle.nullDevice : stderr
    let stdin = try environment["__DEMOAPP_STDIN_FILE"].map {
      try FileHandle(forReadingFrom: URL(filePath: $0))
    }
    defer { try? stdin?.close() }
    process.standardInput = stdin ?? FileHandle.nullDevice

    try launch(process, detached: detached, id: id)
    if detached {
      Thread.sleep(forTimeInterval: 0.35)
      if process.isRunning { return OrchestratorCommandResult(exitCode: 0) }
      process.waitUntilExit()
      return OrchestratorCommandResult(exitCode: process.terminationStatus)
    }
    try waitForExit(process, timeout: timeout)
    return OrchestratorCommandResult(
      exitCode: process.terminationStatus,
      stdout: readOutput(stdoutURL), stderr: readOutput(stderrURL)
    )
  }

  private static func launch(_ process: Process, detached: Bool, id: UUID) throws {
    if detached {
      DetachedRuntimeProcesses.shared.retain(process, id: id)
      process.terminationHandler = { _ in DetachedRuntimeProcesses.shared.release(id: id) }
    }
    do {
      try process.run()
    } catch {
      if detached { DetachedRuntimeProcesses.shared.release(id: id) }
      throw UnifiedOrchestrationError.backendUnavailable(
        "运行组件无法启动。请重新安装完整应用，并检查所选文件的执行权限。"
      )
    }
  }

  private static func waitForExit(_ process: Process, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
      if Task.isCancelled || Date() >= deadline {
        process.terminate()
        let stopDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        if Task.isCancelled { throw CancellationError() }
        throw UnifiedOrchestrationError.commandFailed("运行组件响应超时，请检查容器状态后重试。")
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    process.waitUntilExit()
  }

  private static func readOutput(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 1_048_576) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
}
