// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import Security

/// Observable System Integrity Protection (SIP) status on the macOS host.
public enum RuntimeSIPStatus: String, Codable, Sendable, Equatable {
    case enabled
    case disabled
    case unknown

    public var localizationKey: String {
        switch self {
        case .enabled:
            return "integrity.sip.enabled"
        case .disabled:
            return "integrity.sip.disabled"
        case .unknown:
            return "integrity.sip.unknown"
        }
    }
}

/// Observable code-signature status of the running host executable.
public enum RuntimeCodeSignatureState: String, Codable, Sendable, Equatable {
    case validTeamSigned = "valid_team_signed"
    case adHocOrUnsigned = "adhoc_or_unsigned"
    case invalid
    case unknown

    public var localizationKey: String {
        switch self {
        case .validTeamSigned:
            return "integrity.signature.validTeamSigned"
        case .adHocOrUnsigned:
            return "integrity.signature.adHocOrUnsigned"
        case .invalid:
            return "integrity.signature.invalid"
        case .unknown:
            return "integrity.signature.unknown"
        }
    }
}

/// Honest classification of whether the macOS host itself runs on physical hardware or inside a hypervisor.
public enum RuntimeHostExecutionNature: String, Codable, Sendable, Equatable {
    case physicalHardware = "physical_hardware"
    case virtualMachine = "virtual_machine"
    case unknown

    public var localizationKey: String {
        switch self {
        case .physicalHardware:
            return "integrity.host.physical"
        case .virtualMachine:
            return "integrity.host.virtualMachine"
        case .unknown:
            return "integrity.host.unknown"
        }
    }
}

/// Read-only, honest host & build integrity report reserved for local diagnostics and future vendor attestation.
/// Never spoofs hardware identifiers, SIP status, code signatures, or virtualization flags.
public struct RuntimeIntegrityReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = "1.1.0"
    public static let defaultBoundaryDisclosure =
        "Hardened Runtime protects official signed builds only while macOS SIP is enabled; "
        + "cryptographic remote attestation with anti-cheat servers is required to verify unmodified clients."

    public let schemaVersion: String
    public let hostSIPStatus: RuntimeSIPStatus
    public let codeSignatureState: RuntimeCodeSignatureState
    public let hasValidCodeSignature: Bool
    public let teamIdentifier: String?
    public let hasHardenedRuntime: Bool
    public let isTrustedOfficialTeam: Bool
    public let isOfficialBuild: Bool
    public let hostExecutionNature: RuntimeHostExecutionNature
    public let singleSidedOpenSourceBoundaryNote: String

    /// Legacy alias preserved for backward compatibility with existing callers.
    public var sipStatus: RuntimeSIPStatus { hostSIPStatus }
    /// Legacy alias preserved for backward compatibility with existing callers.
    public var hardenedRuntimeEnabled: Bool { hasHardenedRuntime }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case hostSIPStatus = "host_sip_status"
        case sipStatus = "sip_status"
        case codeSignatureState = "code_signature_state"
        case hasValidCodeSignature = "has_valid_code_signature"
        case teamIdentifier = "team_identifier"
        case hasHardenedRuntime = "has_hardened_runtime"
        case hardenedRuntimeEnabled = "hardened_runtime_enabled"
        case isTrustedOfficialTeam = "is_trusted_official_team"
        case isOfficialBuild = "is_official_build"
        case hostExecutionNature = "host_execution_nature"
        case singleSidedOpenSourceBoundaryNote = "single_sided_open_source_boundary_note"
    }

    public init(
        schemaVersion: String = RuntimeIntegrityReport.currentSchemaVersion,
        hostSIPStatus: RuntimeSIPStatus,
        codeSignatureState: RuntimeCodeSignatureState,
        hasValidCodeSignature: Bool,
        teamIdentifier: String?,
        hasHardenedRuntime: Bool,
        isTrustedOfficialTeam: Bool,
        isOfficialBuild: Bool,
        hostExecutionNature: RuntimeHostExecutionNature,
        singleSidedOpenSourceBoundaryNote: String = RuntimeIntegrityReport.defaultBoundaryDisclosure
    ) {
        self.schemaVersion = schemaVersion
        self.hostSIPStatus = hostSIPStatus
        self.codeSignatureState = codeSignatureState
        self.hasValidCodeSignature = hasValidCodeSignature
        self.teamIdentifier = teamIdentifier
        self.hasHardenedRuntime = hasHardenedRuntime
        self.isTrustedOfficialTeam = isTrustedOfficialTeam
        self.isOfficialBuild = isOfficialBuild
        self.hostExecutionNature = hostExecutionNature
        self.singleSidedOpenSourceBoundaryNote = singleSidedOpenSourceBoundaryNote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        hostSIPStatus = try container.decodeIfPresent(RuntimeSIPStatus.self, forKey: .hostSIPStatus)
            ?? container.decode(RuntimeSIPStatus.self, forKey: .sipStatus)
        codeSignatureState = try container.decode(RuntimeCodeSignatureState.self, forKey: .codeSignatureState)
        teamIdentifier = try container.decodeIfPresent(String.self, forKey: .teamIdentifier)
        hasValidCodeSignature = try container.decodeIfPresent(Bool.self, forKey: .hasValidCodeSignature)
            ?? (codeSignatureState == .validTeamSigned && teamIdentifier?.isEmpty == false)
        hasHardenedRuntime = try container.decodeIfPresent(Bool.self, forKey: .hasHardenedRuntime)
            ?? container.decode(Bool.self, forKey: .hardenedRuntimeEnabled)
        isTrustedOfficialTeam = try container.decodeIfPresent(Bool.self, forKey: .isTrustedOfficialTeam) ?? false
        isOfficialBuild = try container.decode(Bool.self, forKey: .isOfficialBuild)
        hostExecutionNature = try container.decode(RuntimeHostExecutionNature.self, forKey: .hostExecutionNature)
        singleSidedOpenSourceBoundaryNote = try container.decodeIfPresent(
            String.self, forKey: .singleSidedOpenSourceBoundaryNote
        ) ?? Self.defaultBoundaryDisclosure
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(hostSIPStatus, forKey: .hostSIPStatus)
        try container.encode(hostSIPStatus, forKey: .sipStatus)
        try container.encode(codeSignatureState, forKey: .codeSignatureState)
        try container.encode(hasValidCodeSignature, forKey: .hasValidCodeSignature)
        try container.encodeIfPresent(teamIdentifier, forKey: .teamIdentifier)
        try container.encode(hasHardenedRuntime, forKey: .hasHardenedRuntime)
        try container.encode(hasHardenedRuntime, forKey: .hardenedRuntimeEnabled)
        try container.encode(isTrustedOfficialTeam, forKey: .isTrustedOfficialTeam)
        try container.encode(isOfficialBuild, forKey: .isOfficialBuild)
        try container.encode(hostExecutionNature, forKey: .hostExecutionNature)
        try container.encode(singleSidedOpenSourceBoundaryNote, forKey: .singleSidedOpenSourceBoundaryNote)
    }
}

/// Collects honest, read-only host and application integrity facts without elevating privileges or spoofing state.
public enum RuntimeIntegrityAttestor {
    /// Open-source builds do not ship a hardcoded official publisher anchor unless explicitly injected at release time.
    public static let defaultTrustedOfficialTeamIdentifiers: Set<String> = []

    /// Pure evaluation function for deterministic testing and honest attestation derivation.
    public static func evaluate(
        csrutilOutput: String?,
        signatureState: RuntimeCodeSignatureState,
        teamIdentifier: String?,
        hardenedRuntimeEnabled: Bool,
        hvVmmPresent: Int32?,
        trustedOfficialTeamIdentifiers: Set<String> = defaultTrustedOfficialTeamIdentifiers
    ) -> RuntimeIntegrityReport {
        let hostSIPStatus = parseSIPStatus(from: csrutilOutput)
        let normalizedTeam = teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validTeam = (normalizedTeam?.isEmpty == false) ? normalizedTeam : nil
        let trustedAnchors = Set(
            trustedOfficialTeamIdentifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let hasValidSignature = (signatureState == .validTeamSigned) && (validTeam != nil)
        let isTrustedTeam = validTeam.map { trustedAnchors.contains($0) } ?? false
        let isOfficial = hasValidSignature && hardenedRuntimeEnabled && isTrustedTeam

        let hostNature: RuntimeHostExecutionNature
        if let vmm = hvVmmPresent {
            hostNature = (vmm == 0) ? .physicalHardware : .virtualMachine
        } else {
            hostNature = .unknown
        }

        return RuntimeIntegrityReport(
            hostSIPStatus: hostSIPStatus,
            codeSignatureState: signatureState,
            hasValidCodeSignature: hasValidSignature,
            teamIdentifier: validTeam,
            hasHardenedRuntime: hardenedRuntimeEnabled,
            isTrustedOfficialTeam: isTrustedTeam,
            isOfficialBuild: isOfficial,
            hostExecutionNature: hostNature
        )
    }

    /// Parses standard `/usr/bin/csrutil status` output without guessing when output is missing or ambiguous.
    public static func parseSIPStatus(from output: String?) -> RuntimeSIPStatus {
        guard let text = output?.lowercased() else {
            return .unknown
        }
        let hasEnabled = text.contains("system integrity protection status: enabled")
            || text.contains("status: enabled")
        let hasDisabled = text.contains("system integrity protection status: disabled")
            || text.contains("status: disabled")
        if hasEnabled && !hasDisabled {
            return .enabled
        }
        if hasDisabled && !hasEnabled {
            return .disabled
        }
        return .unknown
    }

    /// Captures a live, read-only integrity report of the running host process.
    public static func currentReport(
        trustedOfficialTeamIdentifiers: Set<String> = defaultTrustedOfficialTeamIdentifiers
    ) -> RuntimeIntegrityReport {
        let csrutilText = readCSRUtilStatus()
        let sigInfo = inspectCurrentProcessSignature()
        let vmmPresent = readSysctlInt32("kern.hv_vmm_present")
        return evaluate(
            csrutilOutput: csrutilText,
            signatureState: sigInfo.state,
            teamIdentifier: sigInfo.teamID,
            hardenedRuntimeEnabled: sigInfo.hardenedRuntime,
            hvVmmPresent: vmmPresent,
            trustedOfficialTeamIdentifiers: trustedOfficialTeamIdentifiers
        )
    }

    private static func readCSRUtilStatus() -> String? {
        let url = URL(fileURLWithPath: "/usr/bin/csrutil")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private struct SignatureObservation {
        let state: RuntimeCodeSignatureState
        let teamID: String?
        let hardenedRuntime: Bool
    }

    private static func readSysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let resultCode = sysctlbyname(name, &value, &size, nil, 0)
        guard resultCode == 0 else { return nil }
        return value
    }

    private static func inspectCurrentProcessSignature() -> SignatureObservation {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return SignatureObservation(state: .unknown, teamID: nil, hardenedRuntime: false)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return SignatureObservation(state: .unknown, teamID: nil, hardenedRuntime: false)
        }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        var infoDictRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoDictRef
        )
        guard infoStatus == errSecSuccess, let info = infoDictRef as? [String: Any] else {
            if validityStatus == errSecCSUnsigned {
                return SignatureObservation(state: .adHocOrUnsigned, teamID: nil, hardenedRuntime: false)
            }
            let fallbackState: RuntimeCodeSignatureState = (validityStatus == errSecSuccess)
                ? .adHocOrUnsigned : .invalid
            return SignatureObservation(state: fallbackState, teamID: nil, hardenedRuntime: false)
        }

        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        // 0x00010000 corresponds to CS_RUNTIME (Hardened Runtime) and 0x00000002 to CS_ADHOC.
        let isHardened = (flags & 0x0001_0000) != 0
        let isAdHoc = (flags & 0x0000_0002) != 0
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String

        if validityStatus == errSecCSUnsigned || isAdHoc {
            return SignatureObservation(state: .adHocOrUnsigned, teamID: teamID, hardenedRuntime: isHardened)
        }
        if validityStatus != errSecSuccess {
            return SignatureObservation(state: .invalid, teamID: teamID, hardenedRuntime: isHardened)
        }
        if let teamID, !teamID.isEmpty {
            return SignatureObservation(state: .validTeamSigned, teamID: teamID, hardenedRuntime: isHardened)
        }
        return SignatureObservation(state: .adHocOrUnsigned, teamID: nil, hardenedRuntime: isHardened)
    }
}
