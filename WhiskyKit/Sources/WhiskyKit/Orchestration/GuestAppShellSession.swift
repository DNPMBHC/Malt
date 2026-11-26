// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct GuestAppShellSession: Equatable, Sendable {
  let id: UUID
  let vmIdentifier: String
  let targetExecutable: String
  let expectedGameProcessNames: Set<String>
  let createdAt: Date

  init(
    vmIdentifier: String,
    targetExecutable: String,
    expectedGameProcessNames: Set<String> = [],
    id: UUID = UUID(),
    createdAt: Date = .now
  ) {
    self.id = id
    self.vmIdentifier = vmIdentifier
    self.targetExecutable = targetExecutable
    self.expectedGameProcessNames = Set(expectedGameProcessNames.map { $0.lowercased() })
    self.createdAt = createdAt
  }

  var guestRoot: String { #"C:\ProgramData\RuntimeAppShell\Sessions\"# + id.uuidString }
  var signalPath: String { guestRoot + #"\bridge-signal.json"# }
  var observerPath: String { guestRoot + #"\observer.ps1"# }
  var contextPath: String { guestRoot + #"\context.json"# }
  var stopPath: String { guestRoot + #"\observer.stop"# }

  static func normalizedPath(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: #"\"#).lowercased()
  }

  static func processName(for path: String) -> String {
    let name = path.replacingOccurrences(of: #"\"#, with: "/").split(separator: "/").last.map(String.init) ?? ""
    return name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)).lowercased() : ""
  }
}

struct GuestAppShellProcessIdentity: Equatable, Sendable {
  let pid: Int
  let creationTicks: String
  let path: String
}

/// One verified read-only node in the Win32_Process ParentProcessId lineage chain.
struct GuestAppShellLineageNode: Decodable, Equatable, Sendable {
  let pid: Int
  let parentPID: Int
  let creationTicks: String
  let createdAt: Double
  let processName: String
  let processPath: String
}

struct GuestAppShellSignal: Decodable, Equatable, Sendable {
  let schemaVersion: Int
  let sessionID: String
  let vmIdentifier: String
  let targetExecutable: String
  let sequence: Int
  let event: String
  let observedAt: Double
  let sessionStartedAt: Double
  let rootPID: Int
  let processCreationTicks: String
  let processCreatedAt: Double
  let processPath: String
  let processName: String
  let foregroundPID: Int
  let sourceEvent: String
  let sourceAction: String
  let sourcePID: Int
  let sourceObservedAt: Double
  let foregroundProcessName: String?
  let foregroundProcessPath: String?
  let foregroundCreationTicks: String?
  let foregroundCreatedAt: Double?
  let foregroundWindowFullscreen: Bool?
  let lineageChain: [GuestAppShellLineageNode]?

  var identity: GuestAppShellProcessIdentity? {
    guard rootPID > 0 else { return nil }
    return .init(pid: rootPID, creationTicks: processCreationTicks, path: processPath)
  }

  var isTerminal: Bool { event == "exited" || event == "failed" }
}

struct GuestAppShellEnvelope: Decodable, Sendable {
  let schemaVersion: Int
  let challenge: String
  let guestNow: Double
  let signal: GuestAppShellSignal?
}

enum GuestAppShellValidationError: Error {
  case invalidResponse
}

enum GuestAppShellSignalValidator {
  // This is the existing guest script's diagnostic allowlist, not a compatibility claim.
  static let knownGameProcessNames: Set<String> = [
    "valorant-win64-shipping", "deltaforceclient-win64-shipping", "d3d11_probe"
  ]

  static let excludedUtilityProcessNames: Set<String> = [
    "explorer", "cmd", "powershell", "pwsh", "conhost", "msiexec", "taskmgr",
    "rundll32", "svchost", "searchhost", "shellexperiencehost", "startmenuexperiencehost",
    "applicationframehost", "werfault", "notepad"
  ]

  static func validate(
    _ data: Data, session: GuestAppShellSession, challenge: String,
    previous: GuestAppShellSignal? = nil, verifiedSourceTime: Double? = nil
  ) throws -> GuestAppShellSignal? {
    guard data.count <= 16_384 else { throw GuestAppShellValidationError.invalidResponse }
    var scanner = JSONKeyUniquenessScanner(data: data)
    try scanner.validate()
    let envelope = try JSONDecoder().decode(GuestAppShellEnvelope.self, from: data)
    guard envelope.schemaVersion == 1, envelope.challenge == challenge,
      UUID(uuidString: challenge) != nil, envelope.guestNow.isFinite, envelope.guestNow > 0
    else { throw GuestAppShellValidationError.invalidResponse }
    guard let signal = envelope.signal else { return nil }
    try validateBinding(signal, session: session, guestNow: envelope.guestNow)
    if let previous {
      guard signal.sequence >= previous.sequence,
        signal.sessionStartedAt == previous.sessionStartedAt,
        signal.sequence != previous.sequence || signal == previous,
        previous.identity == nil || previous.identity == signal.identity
      else { throw GuestAppShellValidationError.invalidResponse }
    }
    if signal.rootPID > 0 { try validateIdentity(signal, session: session) }
    if signal.event == "game_foreground" {
      try validateForeground(
        signal, session: session, guestNow: envelope.guestNow, verifiedSourceTime: verifiedSourceTime)
    } else if !["waiting", "compact", "exited", "failed"].contains(signal.event) {
      throw GuestAppShellValidationError.invalidResponse
    }
    return signal
  }

  private static func validateBinding(
    _ signal: GuestAppShellSignal, session: GuestAppShellSession, guestNow: Double
  ) throws {
    guard signal.schemaVersion == 1, UUID(uuidString: signal.sessionID) == session.id,
      UUID(uuidString: signal.vmIdentifier) == UUID(uuidString: session.vmIdentifier),
      UUID(uuidString: signal.vmIdentifier) != nil,
      GuestAppShellSession.normalizedPath(signal.targetExecutable)
        == GuestAppShellSession.normalizedPath(session.targetExecutable),
      signal.sequence > 0, signal.observedAt.isFinite, signal.sessionStartedAt.isFinite,
      signal.sessionStartedAt > 0, signal.observedAt >= signal.sessionStartedAt,
      signal.observedAt <= guestNow + 1, guestNow - signal.observedAt <= 3
    else { throw GuestAppShellValidationError.invalidResponse }
  }

  private static func validateIdentity(
    _ signal: GuestAppShellSignal, session: GuestAppShellSession
  ) throws {
    guard let ticks = UInt64(signal.processCreationTicks), ticks > 0,
      signal.processCreatedAt.isFinite, signal.processCreatedAt >= signal.sessionStartedAt - 2,
      signal.processCreatedAt <= signal.observedAt,
      GuestAppShellSession.normalizedPath(signal.processPath)
        == GuestAppShellSession.normalizedPath(session.targetExecutable),
      signal.processName.lowercased() == GuestAppShellSession.processName(for: session.targetExecutable)
    else { throw GuestAppShellValidationError.invalidResponse }
  }

  private static func validateForeground(
    _ signal: GuestAppShellSignal, session: GuestAppShellSession, guestNow: Double,
    verifiedSourceTime: Double?
  ) throws {
    let allowedNames = knownGameProcessNames.union(session.expectedGameProcessNames)
    guard signal.rootPID > 0,
      signal.sourceEvent == "game_foreground_detected",
      signal.sourceAction == "enter_fullscreen_gamemode",
      signal.sourceObservedAt.isFinite,
      signal.sourceObservedAt >= signal.sessionStartedAt,
      signal.sourceObservedAt <= signal.observedAt + 1
    else { throw GuestAppShellValidationError.invalidResponse }

    let minProcessCreatedAt: Double
    if signal.foregroundPID == signal.rootPID {
      guard signal.sourcePID == signal.rootPID,
        allowedNames.contains(GuestAppShellSession.processName(for: session.targetExecutable))
      else { throw GuestAppShellValidationError.invalidResponse }
      minProcessCreatedAt = signal.processCreatedAt
    } else {
      let leaf = try validateDescendantLineage(signal, session: session, allowedNames: allowedNames)
      minProcessCreatedAt = leaf.createdAt
    }

    guard signal.sourceObservedAt >= minProcessCreatedAt - 1 else {
      throw GuestAppShellValidationError.invalidResponse
    }
    if let verifiedSourceTime {
      guard signal.sourceObservedAt == verifiedSourceTime else {
        throw GuestAppShellValidationError.invalidResponse
      }
    } else if guestNow - signal.sourceObservedAt > 10 {
      throw GuestAppShellValidationError.invalidResponse
    }
  }

  private static func validateDescendantLineage(
    _ signal: GuestAppShellSignal, session: GuestAppShellSession, allowedNames: Set<String>
  ) throws -> GuestAppShellLineageNode {
    guard signal.foregroundPID > 0,
      signal.sourcePID == signal.foregroundPID,
      let chain = signal.lineageChain,
      (2...12).contains(chain.count),
      let rootNode = chain.first,
      let leafNode = chain.last
    else { throw GuestAppShellValidationError.invalidResponse }

    guard rootNode.pid == signal.rootPID,
      rootNode.creationTicks == signal.processCreationTicks,
      GuestAppShellSession.normalizedPath(rootNode.processPath)
        == GuestAppShellSession.normalizedPath(session.targetExecutable)
    else { throw GuestAppShellValidationError.invalidResponse }

    var seenPIDs: Set<Int> = [rootNode.pid]
    for index in 1..<chain.count {
      let parent = chain[index - 1]
      let child = chain[index]
      guard child.pid > 0, seenPIDs.insert(child.pid).inserted,
        child.parentPID == parent.pid,
        let childTicks = UInt64(child.creationTicks), childTicks > 0,
        child.createdAt.isFinite,
        child.createdAt >= parent.createdAt - 1,
        child.createdAt <= signal.observedAt + 1
      else { throw GuestAppShellValidationError.invalidResponse }
    }

    guard leafNode.pid == signal.foregroundPID else {
      throw GuestAppShellValidationError.invalidResponse
    }
    try validateDescendantLeafMetadata(signal, leaf: leafNode, allowedNames: allowedNames)
    return leafNode
  }

  private static func validateDescendantLeafMetadata(
    _ signal: GuestAppShellSignal, leaf: GuestAppShellLineageNode, allowedNames: Set<String>
  ) throws {
    let leafName = leaf.processName.lowercased()
    let pathName = GuestAppShellSession.processName(for: leaf.processPath)
    guard !leafName.isEmpty, leafName == pathName,
      !excludedUtilityProcessNames.contains(leafName),
      ContainerGuestDispatcher.isWindowsExecutablePath(leaf.processPath),
      leaf.processPath.lowercased().hasSuffix(".exe")
    else { throw GuestAppShellValidationError.invalidResponse }

    if let fgTicks = signal.foregroundCreationTicks, fgTicks != leaf.creationTicks {
      throw GuestAppShellValidationError.invalidResponse
    }
    if let fgName = signal.foregroundProcessName, fgName.lowercased() != leafName {
      throw GuestAppShellValidationError.invalidResponse
    }
    if let fgPath = signal.foregroundProcessPath,
       GuestAppShellSession.normalizedPath(fgPath) != GuestAppShellSession.normalizedPath(leaf.processPath) {
      throw GuestAppShellValidationError.invalidResponse
    }
    if let fgCreated = signal.foregroundCreatedAt, abs(fgCreated - leaf.createdAt) > 1 {
      throw GuestAppShellValidationError.invalidResponse
    }

    let isAllowedGame = allowedNames.contains(leafName)
    let isFullscreenProof = signal.foregroundWindowFullscreen == true
    guard isAllowedGame || isFullscreenProof else {
      throw GuestAppShellValidationError.invalidResponse
    }
  }
}
