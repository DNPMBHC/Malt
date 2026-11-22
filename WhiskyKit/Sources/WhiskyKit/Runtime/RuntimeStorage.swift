// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum RuntimeGuestMappingState: String, Codable, Equatable, Sendable {
    case notConfigured
    case configured
    case verified
    case unavailable

    public var localizationKey: String { "runtime.storage.mapping.\(rawValue)" }
}

public enum RuntimeStoragePreflightState: String, Codable, Equatable, Sendable {
    case notChecked
    case notWritable
    case insufficientSpace
    case mappingUnavailable
    case ready

    public var localizationKey: String { "runtime.storage.state.\(rawValue)" }

    var fallback: String {
        switch self {
        case .notChecked: return "The storage check needs a directory, free space, and a local file size."
        case .notWritable: return "The selected storage directory is missing or cannot be written to."
        case .insufficientSpace: return "The selected storage directory has insufficient free space."
        case .mappingUnavailable: return "The storage directory has no usable Windows guest mapping."
        case .ready: return "Storage preflight passed."
        }
    }
}

public struct RuntimeStoragePreflight: Codable, Equatable, Sendable {
    public let targetDirectory: URL?
    public let isWritable: Bool
    public let availableBytes: Int64?
    public let installerBytes: Int64?
    public let reservedBytes: Int64
    public let guestMapping: RuntimeGuestMappingState
    public let state: RuntimeStoragePreflightState

    public init(
        targetDirectory: URL?,
        isWritable: Bool,
        availableBytes: Int64?,
        installerBytes: Int64?,
        reservedBytes: Int64,
        guestMapping: RuntimeGuestMappingState,
        state: RuntimeStoragePreflightState
    ) {
        self.targetDirectory = targetDirectory
        self.isWritable = isWritable
        self.availableBytes = availableBytes
        self.installerBytes = installerBytes
        self.reservedBytes = reservedBytes
        self.guestMapping = guestMapping
        self.state = state
    }

    public var isReady: Bool { state == .ready }

    public var requiredBytes: Int64? {
        guard let installerBytes, installerBytes >= 0, reservedBytes >= 0 else { return nil }
        let (value, overflow) = installerBytes.addingReportingOverflow(reservedBytes)
        return overflow ? nil : value
    }
}

public struct RuntimeStoragePreflightChecker: Sendable {
    public let minimumFreeBytes: Int64
    private let capacityReader: (@Sendable (URL) -> Int64?)?

    public init(
        minimumFreeBytes: Int64 = 4 * 1024 * 1024 * 1024,
        capacityReader: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.capacityReader = capacityReader
    }

    public func check(
        targetDirectory: URL?,
        installerURL: URL? = nil,
        installerBytes: Int64? = nil,
        requiresGuestMapping: Bool = false,
        guestMapping: RuntimeGuestMappingState = .notConfigured
    ) -> RuntimeStoragePreflight {
        let installerSize = installerBytes ?? Self.fileSize(at: installerURL)
        let target = targetDirectory?.standardizedFileURL
        let access = inspectDirectory(target)
        let state = evaluate(
            access: access, installerSize: installerSize,
            requiresGuestMapping: requiresGuestMapping, guestMapping: guestMapping
        )
        return RuntimeStoragePreflight(
            targetDirectory: target, isWritable: access.isWritable, availableBytes: access.availableBytes,
            installerBytes: installerSize, reservedBytes: minimumFreeBytes, guestMapping: guestMapping, state: state
        )
    }

    private struct DirectoryAccess {
        var hasLocalTarget: Bool = false
        var isWritable: Bool = false
        var availableBytes: Int64?
    }

    private func inspectDirectory(_ target: URL?) -> DirectoryAccess {
        guard let target, target.isFileURL else { return DirectoryAccess() }
        let path = target.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return DirectoryAccess(hasLocalTarget: true)
        }
        let currentTarget = URL(fileURLWithPath: path, isDirectory: true)
        let values = try? currentTarget.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityKey])
        let writable = values?.volumeIsReadOnly != true && Self.probeWritableDirectory(at: currentTarget)
        let available: Int64?
        if let capacityReader {
            available = capacityReader(currentTarget).flatMap { $0 >= 0 ? $0 : nil }
        } else {
            available = Self.availableBytes(atPath: path, volumeCapacity: values?.volumeAvailableCapacity)
        }
        return DirectoryAccess(hasLocalTarget: true, isWritable: writable, availableBytes: available)
    }

    private func evaluate(
        access: DirectoryAccess, installerSize: Int64?,
        requiresGuestMapping: Bool, guestMapping: RuntimeGuestMappingState
    ) -> RuntimeStoragePreflightState {
        guard access.hasLocalTarget else { return .notChecked }
        guard access.isWritable else { return .notWritable }
        guard let installerSize, installerSize >= 0, let available = access.availableBytes else { return .notChecked }
        let (required, overflow) = installerSize.addingReportingOverflow(minimumFreeBytes)
        guard !overflow, available >= required else { return .insufficientSpace }
        if requiresGuestMapping && guestMapping != .configured && guestMapping != .verified {
            return .mappingUnavailable
        }
        return .ready
    }

    private static func fileSize(at url: URL?) -> Int64? {
        guard let url, url.isFileURL else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size >= 0 else { return nil }
        return Int64(size)
    }

    fileprivate static func probeWritableDirectory(
        at directory: URL, fileManager: FileManager = .default
    ) -> Bool {
        let probe = directory.appendingPathComponent(
            ".runtime-storage-preflight-\(UUID().uuidString)", isDirectory: false
        )
        guard fileManager.createFile(atPath: probe.path(percentEncoded: false), contents: Data([0])) else {
            return false
        }
        do { try fileManager.removeItem(at: probe) } catch { return false }
        return true
    }

    private static func availableBytes(atPath path: String, volumeCapacity: Int?) -> Int64? {
        if let volumeCapacity, volumeCapacity >= 0 { return Int64(volumeCapacity) }
        let values = try? FileManager.default.attributesOfFileSystem(forPath: path)
        guard let capacity = values?[.systemFreeSize] as? NSNumber, capacity.int64Value >= 0 else { return nil }
        return capacity.int64Value
    }
}

extension RuntimeGuestConfiguration {
    /// Checks only the host declaration. The provider must establish guest-side visibility.
    func storageMapping(for directory: URL?) -> RuntimeGuestMappingState {
        guard let directory, Self.isDirectory(directory) else { return .unavailable }
        return guestPath(for: directory) == nil ? .unavailable : .configured
    }

    var isValidForGuestProvider: Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !identifier.contains("\0")
            && ["x86_64", "aarch64"].contains(Self.canonicalArchitecture(architecture))
            && (1...600).contains(startupTimeoutSeconds)
            && fileMappings.allSatisfy {
                Self.isDirectory($0.hostDirectory) && Self.isAbsoluteGuestDirectory($0.guestDirectory)
            }
    }

    static func canonicalArchitecture(_ value: String) -> String {
        switch value.lowercased() {
        case "x64", "amd64": "x86_64"
        case "arm64": "aarch64"
        default: value.lowercased()
        }
    }

    /// Resolves the longest matching host directory, preserving drive and UNC roots.
    func guestPath(for url: URL, allowsMappingRoot: Bool = true) -> (directory: URL, path: String)? {
        guard url.isFileURL, isValidForGuestProvider else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var match: (directory: URL, path: String)?
        var depth = 0
        for mapping in fileMappings {
            let root = mapping.hostDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let components = root.pathComponents
            guard components.count > depth, path.starts(with: components) else { continue }
            let relative = path.dropFirst(components.count)
            guard allowsMappingRoot || !relative.isEmpty,
                  !relative.contains(where: { $0 == ".." || $0.contains("\\") }) else { continue }
            let guestRoot = mapping.guestDirectory.replacingOccurrences(of: "/", with: "\\")
            let separator = guestRoot.hasSuffix("\\") ? "" : "\\"
            let guestPath = relative.isEmpty ? guestRoot : guestRoot + separator + relative.joined(separator: "\\")
            match = (root, guestPath)
            depth = components.count
        }
        return match
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isAbsoluteGuestDirectory(_ path: String) -> Bool {
        guard !path.contains("\0") else { return false }
        let value = path.replacingOccurrences(of: "/", with: "\\")
        let parts = value.split(separator: "\\")
        let drivePath = value.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
        let uncPath = value.hasPrefix("\\\\") && parts.count >= 3
        return (drivePath || uncPath) && !parts.contains { $0 == "." || $0 == ".." }
    }
}

public enum RuntimeStorageTargetSelector {
    struct VolumeMetadata: Sendable {
        let isInternal: Bool
        let isReadOnly: Bool
        let availableCapacityForImportantUsage: Int64?
        let availableCapacity: Int64?
        let fileSystemFreeSize: Int64?
    }

    private struct Candidate {
        let target: URL
        let isInternal: Bool
        let available: Int64?
    }

    public static func preferredTarget(
        volumes: [URL] = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeIsInternalKey, .volumeIsReadOnlyKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? [],
        folderName: String = "my-project-downloads"
    ) -> URL? {
        preferredTarget(volumes: volumes, folderName: folderName, metadataReader: Self.readVolumeMetadata)
    }

    static func preferredTarget(
        volumes: [URL],
        folderName: String = "my-project-downloads",
        metadataReader: (URL) -> VolumeMetadata?
    ) -> URL? {
        let candidates = volumes.compactMap { volume -> Candidate? in
            guard volume.isFileURL, let metadata = metadataReader(volume), !metadata.isReadOnly else {
                return nil
            }
            let available = effectiveAvailableBytes(from: metadata)
            return Candidate(
                target: volume.appendingPathComponent(folderName, isDirectory: true),
                isInternal: metadata.isInternal,
                available: available
            )
        }
        return candidates.sorted(by: ranksBefore).first?.target
    }

    static func effectiveAvailableBytes(from metadata: VolumeMetadata) -> Int64? {
        let sources = [
            metadata.availableCapacityForImportantUsage,
            metadata.availableCapacity,
            metadata.fileSystemFreeSize
        ]
        if let positive = sources.compactMap({ $0 }).first(where: { $0 > 0 }) {
            return positive
        }
        if sources.contains(where: { $0 == 0 }) {
            return 0
        }
        return nil
    }

    private static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.isInternal != rhs.isInternal { return !lhs.isInternal && rhs.isInternal }
        switch (lhs.available, rhs.available) {
        case let (left?, right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.target.path(percentEncoded: false) < rhs.target.path(percentEncoded: false)
        }
    }

    private static func readVolumeMetadata(for volume: URL) -> VolumeMetadata? {
        let values = try? volume.resourceValues(forKeys: [
            .volumeIsInternalKey, .volumeIsReadOnlyKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        let path = volume.path(percentEncoded: false)
        let fsAttrs = try? FileManager.default.attributesOfFileSystem(forPath: path)
        let systemFreeSize = (fsAttrs?[.systemFreeSize] as? NSNumber)?.int64Value
        return VolumeMetadata(
            isInternal: values?.volumeIsInternal ?? true,
            isReadOnly: values?.volumeIsReadOnly == true,
            availableCapacityForImportantUsage: values?.volumeAvailableCapacityForImportantUsage,
            availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
            fileSystemFreeSize: systemFreeSize
        )
    }

    public static func prepareDirectory(on target: URL, fileManager: FileManager = .default) throws -> URL {
        guard target.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        let directory = target.standardizedFileURL
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue,
              RuntimeStoragePreflightChecker.probeWritableDirectory(at: directory, fileManager: fileManager) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory
    }
}
