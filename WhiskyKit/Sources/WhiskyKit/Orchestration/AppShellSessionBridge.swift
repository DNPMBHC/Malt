// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AppShellBinding: Sendable {
  let id: UUID
  let stateURL: URL
}

/// Owns only state files created by this orchestrator's current helper lifecycle.
public actor AppShellSessionBridge {
  private struct Binding {
    let token: AppShellBinding
    let vmIdentifier: String
    let helper: String
    var helperIdentity: String?
    let payload: [String: String]
  }

  private var binding: Binding?
  private var generation = UUID()
  private var monitor: Task<Void, Never>?
  private var previous: GuestAppShellSignal?
  private var verifiedSourceTime: Double?

  public init() {}

  func createBinding(
    vmIdentifier: String, helper: String, directory: URL, title: String, windowSize: String
  ) throws -> AppShellBinding {
    guard UUID(uuidString: vmIdentifier) != nil else { throw GuestAppShellValidationError.invalidResponse }
    monitor?.cancel()
    generation = UUID()
    if binding != nil { try? writeState("installer") }
    let id = UUID()
    let privateDirectory = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: privateDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let token = AppShellBinding(id: id, stateURL: privateDirectory.appending(path: "state.json"))
      binding = Binding(
        token: token, vmIdentifier: vmIdentifier, helper: helper,
        payload: ["windowTitle": title, "windowSize": windowSize, "bindingID": id.uuidString,
          "vmIdentifier": vmIdentifier])
      try writeState("installer")
      return token
    } catch {
      binding = nil
      throw UnifiedOrchestrationError.backendUnavailable("无法建立私有窗口状态会话，请检查临时目录的写入权限后重试。")
    }
  }

  func recordHelperIdentity(_ identity: String?, bindingID: UUID) {
    guard binding?.token.id == bindingID, let identity,
      binding?.helperIdentity == nil || binding?.helperIdentity == identity else { return }
    binding?.helperIdentity = identity
  }

  func requireBinding(vmIdentifier: String, helper: String, identity: String?) throws -> AppShellBinding {
    guard let binding, let identity, binding.helperIdentity == identity,
      binding.helper == helper, UUID(uuidString: binding.vmIdentifier) == UUID(uuidString: vmIdentifier)
    else {
      throw UnifiedOrchestrationError.backendUnavailable(
        "现有容器窗口没有本次应用的有效状态绑定。请完全退出容器引擎，再从此应用重新打开所选运行环境。")
    }
    return binding.token
  }

  func resetCompact(bindingID: UUID) throws {
    guard binding?.token.id == bindingID else { throw GuestAppShellValidationError.invalidResponse }
    monitor?.cancel()
    monitor = nil
    generation = UUID()
    previous = nil
    verifiedSourceTime = nil
    try writeState("installer")
  }

  func invalidate(bindingID: UUID) {
    guard binding?.token.id == bindingID else { return }
    monitor?.cancel()
    generation = UUID()
    try? writeState("installer")
    binding = nil
  }

  func begin(session: GuestAppShellSession, bindingID: UUID) throws -> UUID {
    guard let binding, binding.token.id == bindingID,
      UUID(uuidString: binding.vmIdentifier) == UUID(uuidString: session.vmIdentifier)
    else { throw GuestAppShellValidationError.invalidResponse }
    try resetCompact(bindingID: bindingID)
    return generation
  }

  @discardableResult
  func consume(
    _ data: Data, session: GuestAppShellSession, challenge: String, generation expected: UUID
  ) throws -> GuestAppShellSignal? {
    guard generation == expected else { throw CancellationError() }
    let signal = try GuestAppShellSignalValidator.validate(
      data, session: session, challenge: challenge, previous: previous, verifiedSourceTime: verifiedSourceTime)
    guard generation == expected else { throw CancellationError() }
    if let signal {
      previous = signal
      if signal.event == "game_foreground" { verifiedSourceTime = signal.sourceObservedAt }
      try writeState(signal.event == "game_foreground" ? "game_foreground" : "installer")
    }
    return signal
  }

  func finish(generation expected: UUID) {
    guard generation == expected else { return }
    try? writeState("installer")
    monitor = nil
    previous = nil
    verifiedSourceTime = nil
    generation = UUID()
  }

  func startMonitoring(
    session: GuestAppShellSession, bindingID: UUID, dispatcher: ContainerGuestDispatcher
  ) throws {
    let expected = try begin(session: session, bindingID: bindingID)
    monitor = Task { [weak self] in
      var emptyReads = 0
      do {
        while !Task.isCancelled && session.createdAt.timeIntervalSinceNow > -43_200 {
          let challenge = UUID().uuidString
          let data = try await dispatcher.readAppShellEnvelope(session: session, challenge: challenge)
          guard let self else { break }
          let signal = try await self.consume(data, session: session, challenge: challenge, generation: expected)
          emptyReads = signal == nil ? emptyReads + 1 : 0
          if signal?.isTerminal == true || emptyReads > 5 { break }
          try await Task.sleep(for: .seconds(1))
        }
      } catch { /* Any failure restores compact without extending guest authority. */ }
      await self?.finish(generation: expected)
      // This stop marker belongs only to this random observer; it never stops a game or VM.
      await dispatcher.stopAppShellObserver(session: session)
    }
  }

  private func writeState(_ state: String) throws {
    guard let binding else { throw GuestAppShellValidationError.invalidResponse }
    var payload = binding.payload
    payload["state"] = state
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try data.write(to: binding.token.stateURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binding.token.stateURL.path)
  }
}
