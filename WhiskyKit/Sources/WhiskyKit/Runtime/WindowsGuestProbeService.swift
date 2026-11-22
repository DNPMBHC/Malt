// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

public protocol WindowsGuestProbeReporting: WindowsGuestProvider {
    func collectSelfProbeReport(nonce: String) async throws -> Data
}

public enum WindowsGuestProbeServiceError: Error, Equatable {
    case guestUnavailable(String)
    case providerDoesNotSupportProbe
    case challengeGenerationFailed
}

public struct WindowsGuestProbeService: Sendable {
    private let provider: any WindowsGuestProvider
    private let nonceGenerator: @Sendable () throws -> String

    public init(provider: any WindowsGuestProvider) {
        self.provider = provider
        self.nonceGenerator = Self.generateNonce
    }

    init(
        provider: any WindowsGuestProvider,
        nonceGenerator: @escaping @Sendable () throws -> String
    ) {
        self.provider = provider
        self.nonceGenerator = nonceGenerator
    }

    public func assess(
        now: Date = .now,
        maximumAge: TimeInterval = 120
    ) async throws -> AntiCheatProbeAssessment {
        guard provider.availability.isReady else {
            if case .unavailable(let reason) = provider.availability {
                throw WindowsGuestProbeServiceError.guestUnavailable(reason)
            }
            throw WindowsGuestProbeServiceError.guestUnavailable("Windows guest is not configured.")
        }
        guard let reportingProvider = provider as? any WindowsGuestProbeReporting else {
            throw WindowsGuestProbeServiceError.providerDoesNotSupportProbe
        }

        let nonce: String
        do {
            nonce = try nonceGenerator()
        } catch {
            throw WindowsGuestProbeServiceError.challengeGenerationFailed
        }
        let data = try await reportingProvider.collectSelfProbeReport(nonce: nonce)
        return try AntiCheatProbeReportValidator.assess(
            data,
            expectedNonce: nonce,
            now: now,
            maximumAge: maximumAge
        )
    }

    private static func generateNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw WindowsGuestProbeServiceError.challengeGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension UTMWindowsGuestProvider: WindowsGuestProbeReporting {
    public func collectSelfProbeReport(nonce: String) async throws -> Data {
        guard let config = configuration else {
            throw WindowsGuestProbeServiceError.guestUnavailable("Windows guest is not configured.")
        }
        guard installed else { throw UTMGuestError.utmNotInstalled }
        try GuestConfigurationValidator.validate(config)

        let initial = try await transport.inspect(config.identifier)
        guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
        try validate(initial, config: config)
        let deadline = ContinuousClock.now + .seconds(config.startupTimeoutSeconds)
        let launchedVM = try await prepareVM(initial, config: config, until: deadline)

        do {
            try await waitForAgent(config, until: deadline)
            let target = try await prepareProbeArtifacts(config: config, until: deadline)
            var arguments = ["--nonce", nonce]
            if let driverPath = target.driverGuestPath {
                arguments.append(contentsOf: ["--driver-image", driverPath])
            }
            return try await transport.collectOutput(
                config.identifier,
                executable: target.executableGuestPath,
                arguments: arguments,
                until: deadline,
                pollInterval: pollInterval
            )
        } catch {
            if launchedVM {
                try? await transport.stop(config.identifier)
                await activeGuest.clear(ifMatching: config.identifier)
            }
            throw error
        }
    }

    private func prepareProbeArtifacts(
        config: RuntimeGuestConfiguration,
        until deadline: ContinuousClock.Instant
    ) async throws -> (executableGuestPath: String, driverGuestPath: String?) {
        guard let mapping = config.fileMappings.first else {
            return (#"C:\module-a\module_a_probe.exe"#, nil)
        }
        let guestRoot = mapping.guestDirectory.replacingOccurrences(of: "/", with: "\\")
        let separator = guestRoot.hasSuffix("\\") ? "" : "\\"
        let guestExecutable = guestRoot + separator + "module_a_probe.exe"
        let hostExecutable = mapping.hostDirectory.appendingPathComponent("module_a_probe.exe")
        if FileManager.default.isReadableFile(atPath: hostExecutable.path) {
            try await transport.pushCreatingParentDirectory(
                config.identifier, hostURL: hostExecutable, guestPath: guestExecutable,
                until: deadline, pollInterval: pollInterval
            )
        }
        let hostDriver = mapping.hostDirectory.appendingPathComponent("ModuleAProbe.sys")
        if FileManager.default.isReadableFile(atPath: hostDriver.path) {
            let guestDriver = guestRoot + separator + "ModuleAProbe.sys"
            try await transport.pushCreatingParentDirectory(
                config.identifier, hostURL: hostDriver, guestPath: guestDriver,
                until: deadline, pollInterval: pollInterval
            )
            return (guestExecutable, guestDriver)
        }
        return (guestExecutable, nil)
    }
}
