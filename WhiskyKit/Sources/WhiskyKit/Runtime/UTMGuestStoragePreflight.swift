// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum UTMGuestStorageTargetState: String, Codable, Equatable, Sendable {
  case notChecked
  case writable
  case creatable
  case notWritable
}

public enum UTMGuestFileVisibility: String, Codable, Equatable, Sendable {
  case notChecked
  case visible
  case notVisible
}

/// Storage checks associated with a host target and its configured guest path.
/// canExecuteGuestFile becomes true only after the provider verifies the pushed file.
public struct UTMGuestStoragePreflight: Sendable, Equatable {
  public let storage: RuntimeStoragePreflight
  public let hostTargetState: UTMGuestStorageTargetState
  public let guestFileVisibility: UTMGuestFileVisibility
  public let guestTargetDirectory: String?

  public var canStartGuest: Bool {
    (hostTargetState == .writable || hostTargetState == .creatable) && storage.isReady
  }

  public var canExecuteGuestFile: Bool {
    canStartGuest && storage.guestMapping == .verified && guestFileVisibility == .visible
  }

  func validateHostReadiness() throws {
    guard !canStartGuest else { return }
    if hostTargetState == .notWritable { throw UTMGuestError.storageNotWritable }
    switch storage.state {
    case .insufficientSpace: throw UTMGuestError.insufficientHostSpace
    case .mappingUnavailable: throw UTMGuestError.fileMappingUnavailable
    default: throw UTMGuestError.storagePreflightUnavailable
    }
  }

  func recordingGuestFileVisibility(_ visibility: UTMGuestFileVisibility) -> Self {
    let mapping: RuntimeGuestMappingState
    let state: RuntimeStoragePreflightState
    switch visibility {
    case .notChecked:
      mapping = storage.guestMapping
      state = storage.state
    case .visible:
      mapping = .verified
      state = storage.state
    case .notVisible:
      mapping = .unavailable
      state = .mappingUnavailable
    }
    let updatedStorage = RuntimeStoragePreflight(
      targetDirectory: storage.targetDirectory,
      isWritable: storage.isWritable,
      availableBytes: storage.availableBytes,
      installerBytes: storage.installerBytes,
      reservedBytes: storage.reservedBytes,
      guestMapping: mapping,
      state: state
    )
    return Self(
      storage: updatedStorage,
      hostTargetState: hostTargetState,
      guestFileVisibility: visibility,
      guestTargetDirectory: guestTargetDirectory
    )
  }

  init(
    storage: RuntimeStoragePreflight,
    hostTargetState: UTMGuestStorageTargetState,
    guestFileVisibility: UTMGuestFileVisibility = .notChecked,
    guestTargetDirectory: String?
  ) {
    self.storage = storage
    self.hostTargetState = hostTargetState
    self.guestFileVisibility = guestFileVisibility
    self.guestTargetDirectory = guestTargetDirectory
  }
}

/// Task-02 preflight API for callers that select a storage target before download or install.
public struct UTMGuestStoragePreflightChecker: Sendable {
  private let storageChecker: RuntimeStoragePreflightChecker

  public init(minimumFreeBytes: Int64 = 4 * 1024 * 1024 * 1024) {
    storageChecker = RuntimeStoragePreflightChecker(minimumFreeBytes: minimumFreeBytes)
  }

  public func check(
    targetDirectory: URL?,
    installerURL: URL? = nil,
    installerBytes: Int64? = nil,
    configuration: RuntimeGuestConfiguration?
  ) -> UTMGuestStoragePreflight {
    let target = targetDirectory?.standardizedFileURL
    let guestTargetDirectory = target.flatMap { configuration?.guestPath(for: $0)?.path }
    let mapping: RuntimeGuestMappingState
    if configuration == nil {
      mapping = .notConfigured
    } else {
      mapping = guestTargetDirectory == nil ? .unavailable : .configured
    }
    let probe = target.flatMap(Self.nearestExistingDirectory)
    let checked = storageChecker.check(
      targetDirectory: probe ?? target, installerURL: installerURL, installerBytes: installerBytes,
      requiresGuestMapping: true, guestMapping: mapping
    )
    let hostState: UTMGuestStorageTargetState
    if let target, target.isFileURL {
      hostState =
        checked.isWritable ? (target.path == probe?.path ? .writable : .creatable) : .notWritable
    } else {
      hostState = .notChecked
    }
    let storage = RuntimeStoragePreflight(
      targetDirectory: target,
      isWritable: checked.isWritable,
      availableBytes: checked.availableBytes,
      installerBytes: checked.installerBytes,
      reservedBytes: checked.reservedBytes,
      guestMapping: checked.guestMapping,
      state: checked.state
    )
    return UTMGuestStoragePreflight(
      storage: storage, hostTargetState: hostState, guestTargetDirectory: guestTargetDirectory
    )
  }

  private static func nearestExistingDirectory(to target: URL) -> URL? {
    var candidate = target.standardizedFileURL
    while candidate.isFileURL {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(
        atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory
      ) {
        return isDirectory.boolValue ? candidate : nil
      }
      let parent = candidate.deletingLastPathComponent()
      guard parent != candidate else { return nil }
      candidate = parent
    }
    return nil
  }
}

actor UTMGuestStorageStatus {
  private var latest: UTMGuestStoragePreflight?

  func update(_ value: UTMGuestStoragePreflight) { latest = value }
  func value() -> UTMGuestStoragePreflight? { latest }
}
