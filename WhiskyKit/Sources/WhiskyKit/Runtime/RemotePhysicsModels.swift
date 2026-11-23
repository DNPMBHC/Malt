// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Explicit execution domain identifier so remote physical hosts are never confused with Wine or local VMs.
public enum RemotePhysicsExecutionDomain: String, Codable, Equatable, Sendable {
    case remotePhysicalWindows = "remote_physical_windows"
}

/// Supported compliant streaming client transport modes.
public enum RemotePhysicsTransportKind: String, Codable, CaseIterable, Sendable {
    case moonlightClient = "moonlight_client"
    case externalClient = "external_client"
}

/// Target stream display resolution.
public struct RemotePhysicsResolution: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let hd720p = RemotePhysicsResolution(width: 1280, height: 720)
    public static let fullHD1080p = RemotePhysicsResolution(width: 1920, height: 1080)
    public static let qhd1440p = RemotePhysicsResolution(width: 2560, height: 1440)

    public var isValid: Bool {
        (640...7680).contains(width) && (360...4320).contains(height)
    }

    public var cliValue: String { "\(width)x\(height)" }
}

/// User stream preferences that can be adapted reversibly by host thermal/power policy.
public struct RemotePhysicsStreamPreferences: Codable, Equatable, Sendable {
    public let resolution: RemotePhysicsResolution
    public let targetFPS: Int
    public let bitrateKbps: Int
    public let audioEnabled: Bool
    public let adaptiveResourcePolicyEnabled: Bool

    public init(
        resolution: RemotePhysicsResolution = .fullHD1080p,
        targetFPS: Int = 60,
        bitrateKbps: Int = 20_000,
        audioEnabled: Bool = true,
        adaptiveResourcePolicyEnabled: Bool = true
    ) {
        self.resolution = resolution
        self.targetFPS = targetFPS
        self.bitrateKbps = bitrateKbps
        self.audioEnabled = audioEnabled
        self.adaptiveResourcePolicyEnabled = adaptiveResourcePolicyEnabled
    }
}

/// Reversible stream settings derived from RuntimeHostSnapshot.performancePolicy.
public struct RemotePhysicsStreamPolicy: Equatable, Sendable {
    public let isAdaptiveEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let resolution: RemotePhysicsResolution
    public let effectiveFPS: Int
    public let effectiveBitrateKbps: Int
    public let audioEnabled: Bool
    public let processQualityOfService: QualityOfService

    public init(preferences: RemotePhysicsStreamPreferences, snapshot: RuntimeHostSnapshot) {
        self.isAdaptiveEnabled = preferences.adaptiveResourcePolicyEnabled
        self.performancePolicy = snapshot.performancePolicy
        self.resolution = preferences.resolution
        self.audioEnabled = preferences.audioEnabled

        guard preferences.adaptiveResourcePolicyEnabled else {
            self.effectiveFPS = preferences.targetFPS
            self.effectiveBitrateKbps = preferences.bitrateKbps
            self.processQualityOfService = .userInitiated
            return
        }

        switch snapshot.performancePolicy {
        case .maximumPerformance:
            self.effectiveFPS = preferences.targetFPS
            self.effectiveBitrateKbps = preferences.bitrateKbps
            self.processQualityOfService = .userInitiated
        case .balanced:
            self.effectiveFPS = min(preferences.targetFPS, 60)
            self.effectiveBitrateKbps = min(
                preferences.bitrateKbps,
                max(4_000, Int(Double(preferences.bitrateKbps) * 0.70))
            )
            self.processQualityOfService = .utility
        case .conserveEnergy:
            self.effectiveFPS = min(preferences.targetFPS, 30)
            self.effectiveBitrateKbps = min(
                preferences.bitrateKbps,
                max(2_000, Int(Double(preferences.bitrateKbps) * 0.45))
            )
            self.processQualityOfService = .utility
        }
    }

    /// Official Moonlight CLI stream arguments with zero shell interpolation.
    public func moonlightStreamArguments(
        host: String,
        port: UInt16 = RemotePhysicsConfiguration.defaultControlPort,
        applicationName: String
    ) -> [String] {
        var args = [
            "stream",
            "--resolution", resolution.cliValue,
            "--fps", "\(effectiveFPS)",
            "--bitrate", "\(effectiveBitrateKbps)"
        ]
        if !audioEnabled {
            args.append("--no-audio")
        }
        args.append(RemotePhysicsConfiguration.formatMoonlightHostTarget(host: host, port: port))
        args.append(applicationName)
        return args
    }
}

/// Availability states matching Phase 3-C specification plus honest pre-probe unverified state.
public enum RemotePhysicsAvailability: Equatable, Sendable {
    case unconfigured
    case unverified
    case clientMissing(String)
    case hostUnreachable(String)
    case ready

    public var isReady: Bool { self == .ready }
}

/// Typed errors for configuration safety, availability, and session lifecycle.
public enum RemotePhysicsError: LocalizedError, Equatable, Sendable {
    case unconfigured
    case forbiddenPlaintextCredential(String)
    case invalidConfiguration(String)
    case forbiddenShellClient(String)
    case clientMissing(String)
    case hostUnreachable(String)
    case connectionTimedOut(Double)

    public var errorDescription: String? {
        switch self {
        case .unconfigured:
            return "Remote physical Windows host is not configured."
        case .forbiddenPlaintextCredential(let field):
            return "Plaintext credential field '\(field)' is forbidden in remote host configuration."
        case .invalidConfiguration(let detail):
            return "Invalid remote physical host configuration: \(detail)"
        case .forbiddenShellClient(let name):
            return "Shell or scripting interpreter '\(name)' is not permitted as a streaming client."
        case .clientMissing(let detail):
            return "Streaming client executable is missing or not executable: \(detail)"
        case .hostUnreachable(let detail):
            return "Remote physical Windows host is unreachable: \(detail)"
        case .connectionTimedOut(let seconds):
            return "Timed out after \(seconds)s while connecting to the remote physical Windows host."
        }
    }
}

/// Sanitized, credential-free configuration for a compliant physical Windows streaming host.
public struct RemotePhysicsConfiguration: Codable, Equatable, Sendable {
    public static let defaultControlPort: UInt16 = 47984

    public static func formatMoonlightHostTarget(host: String, port: UInt16) -> String {
        guard port != defaultControlPort else { return host }
        if host.contains(":"), !host.hasPrefix("["), !host.hasSuffix("]") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    public var moonlightHostTarget: String {
        Self.formatMoonlightHostTarget(host: hostIdentifier, port: controlPort)
    }

    private static let forbiddenCredentialKeys: Set<String> = [
        "password", "passwd", "passphrase", "pin", "token", "accesstoken", "access_token",
        "secret", "apikey", "api_key", "privatekey", "private_key", "credential", "credentials",
        "auth", "authorization"
    ]

    private static let forbiddenShellExecutables: Set<String> = [
        "sh", "bash", "zsh", "dash", "csh", "tcsh", "ksh", "fish",
        "osascript", "python", "python3", "perl", "ruby", "node", "expect"
    ]

    public let hostIdentifier: String
    public let controlPort: UInt16
    public let transport: RemotePhysicsTransportKind
    public let applicationName: String
    public let clientExecutableURL: URL?
    public let externalArguments: [String]
    public let connectionTimeoutSeconds: Double
    public let streamPreferences: RemotePhysicsStreamPreferences

    public init(
        hostIdentifier: String,
        controlPort: UInt16 = 47984,
        transport: RemotePhysicsTransportKind = .moonlightClient,
        applicationName: String,
        clientExecutableURL: URL? = nil,
        externalArguments: [String] = [],
        connectionTimeoutSeconds: Double = 10,
        streamPreferences: RemotePhysicsStreamPreferences = .init()
    ) {
        self.hostIdentifier = hostIdentifier
        self.controlPort = controlPort
        self.transport = transport
        self.applicationName = applicationName
        self.clientExecutableURL = clientExecutableURL
        self.externalArguments = externalArguments
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.streamPreferences = streamPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case hostIdentifier
        case controlPort
        case transport
        case applicationName
        case clientExecutableURL
        case externalArguments
        case connectionTimeoutSeconds
        case streamPreferences
    }

    private struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: RawKey.self)
        for key in rawContainer.allKeys {
            let normalized = key.stringValue.lowercased()
            if Self.forbiddenCredentialKeys.contains(normalized) {
                throw RemotePhysicsError.forbiddenPlaintextCredential(key.stringValue)
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostIdentifier = try container.decode(String.self, forKey: .hostIdentifier)
        self.controlPort = try container.decodeIfPresent(UInt16.self, forKey: .controlPort) ?? 47984
        self.transport = try container.decodeIfPresent(RemotePhysicsTransportKind.self, forKey: .transport)
            ?? .moonlightClient
        self.applicationName = try container.decode(String.self, forKey: .applicationName)
        self.clientExecutableURL = try container.decodeIfPresent(URL.self, forKey: .clientExecutableURL)
        self.externalArguments = try container.decodeIfPresent([String].self, forKey: .externalArguments) ?? []
        self.connectionTimeoutSeconds = try container.decodeIfPresent(
            Double.self, forKey: .connectionTimeoutSeconds
        ) ?? 10
        self.streamPreferences = try container.decodeIfPresent(
            RemotePhysicsStreamPreferences.self, forKey: .streamPreferences
        ) ?? .init()
    }

    /// Validates all configuration bounds and rejects embedded credentials or shell injection vectors.
    public func validate() throws {
        try validateEndpoint()
        try validateStreamSettings()
        try validateClientExecutable()
    }

    private func validateEndpoint() throws {
        let trimmedHost = hostIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, trimmedHost == hostIdentifier else {
            throw RemotePhysicsError.invalidConfiguration("hostIdentifier must be non-empty without outer whitespace.")
        }
        let forbiddenHostTokens = ["@", "://", "?", "&"]
        if forbiddenHostTokens.contains(where: { trimmedHost.contains($0) }) {
            throw RemotePhysicsError.forbiddenPlaintextCredential("hostIdentifier")
        }
        guard !trimmedHost.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
            throw RemotePhysicsError.invalidConfiguration("hostIdentifier contains invalid whitespace or null bytes.")
        }
        guard controlPort > 0 else {
            throw RemotePhysicsError.invalidConfiguration("controlPort must be in 1...65535.")
        }
        let trimmedApp = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApp.isEmpty, !applicationName.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw RemotePhysicsError.invalidConfiguration("applicationName must be non-empty without control chars.")
        }
    }

    private func validateStreamSettings() throws {
        guard connectionTimeoutSeconds.isFinite,
              connectionTimeoutSeconds > 0,
              connectionTimeoutSeconds <= 120 else {
            throw RemotePhysicsError.invalidConfiguration("connectionTimeoutSeconds must be in (0, 120].")
        }
        guard streamPreferences.resolution.isValid else {
            throw RemotePhysicsError.invalidConfiguration("stream resolution is out of supported bounds.")
        }
        guard (24...240).contains(streamPreferences.targetFPS) else {
            throw RemotePhysicsError.invalidConfiguration("targetFPS must be in 24...240.")
        }
        guard (1_000...150_000).contains(streamPreferences.bitrateKbps) else {
            throw RemotePhysicsError.invalidConfiguration("bitrateKbps must be in 1000...150000.")
        }
    }

    private func validateClientExecutable() throws {
        guard externalArguments.allSatisfy({ !$0.contains("\0") }) else {
            throw RemotePhysicsError.invalidConfiguration("externalArguments must not contain null bytes.")
        }
        if let executableURL = clientExecutableURL {
            guard executableURL.isFileURL else {
                throw RemotePhysicsError.invalidConfiguration("clientExecutableURL must be a local file URL.")
            }
            let binaryName = executableURL.lastPathComponent.lowercased()
            if Self.forbiddenShellExecutables.contains(binaryName) {
                throw RemotePhysicsError.forbiddenShellClient(binaryName)
            }
        } else if transport == .externalClient {
            throw RemotePhysicsError.invalidConfiguration("externalClient transport requires clientExecutableURL.")
        }
    }
}
