// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Five-dimension state snapshot for a regional compatibility matrix record.
public struct BundledMatrixFiveDimensionStates: Codable, Sendable, Equatable {
    public let publisherPermission: String
    public let publisherSupport: String
    public let driverLoad: String
    public let gameStart: String
    public let protectedSession: String

    enum CodingKeys: String, CodingKey {
        case publisherPermission = "publisher_permission"
        case publisherSupport = "publisher_support"
        case driverLoad = "driver_load"
        case gameStart = "game_start"
        case protectedSession = "protected_session"
    }
}

/// A regional game compatibility record compiled from `handoff/module-f/evidence.json`.
public struct BundledCompatibilityRecord: Codable, Sendable, Equatable, Identifiable {
    public let recordID: String
    public let scopeID: String
    public let targetID: String?
    public let productName: String
    public let platform: String
    public let distribution: String
    public let region: String
    public let environment: String
    public let guestCPUArchitecture: String
    public let updatedOn: String
    public let fiveDimensionStates: BundledMatrixFiveDimensionStates
    public let basisClaimIDs: [String]

    public var id: String { recordID }

    enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case scopeID = "scope_id"
        case targetID = "target_id"
        case productName = "product_name"
        case platform
        case distribution
        case region
        case environment
        case guestCPUArchitecture = "guest_cpu_architecture"
        case updatedOn = "updated_on"
        case fiveDimensionStates = "five_dimension_states"
        case basisClaimIDs = "basis_claim_ids"
    }
}

/// Summary of an orthogonal Bare-Metal WoA vs Virtualized ARM64 Guest split claim.
public struct BundledWoAVMSplitClaim: Codable, Sendable, Equatable, Identifiable {
    public let claimID: String
    public let scopeID: String
    public let topic: String
    public let status: String
    public let updatedOn: String
    public let summaryZh: String
    public let limitationZh: String

    public var id: String { claimID }

    enum CodingKeys: String, CodingKey {
        case claimID = "claim_id"
        case scopeID = "scope_id"
        case topic
        case status
        case updatedOn = "updated_on"
        case summaryZh = "summary_zh"
        case limitationZh = "limitation_zh"
    }
}

/// Read-only bundled compatibility matrix compiled from `handoff/module-f/evidence.json`.
public struct BundledCompatibilityMatrix: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let sourceDatasetID: String
    public let sourceSnapshotID: String
    public let sourceEvidenceSHA256: String
    public let asOf: String
    public let timezone: String
    public let sourceCount: Int
    public let claimCount: Int
    public let woaAndVMOrthogonalSplit: [String: BundledWoAVMSplitClaim]
    public let records: [BundledCompatibilityRecord]
    public let consumptionRules: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceDatasetID = "source_dataset_id"
        case sourceSnapshotID = "source_snapshot_id"
        case sourceEvidenceSHA256 = "source_evidence_sha256"
        case asOf = "as_of"
        case timezone
        case sourceCount = "source_count"
        case claimCount = "claim_count"
        case woaAndVMOrthogonalSplit = "woa_and_vm_orthogonal_split"
        case records
        case consumptionRules = "consumption_rules"
    }

    /// Loads `compatibility-matrix.json` from the given bundle or an explicit file URL.
    public static func load(
        from url: URL? = nil,
        bundle: Bundle = .main
    ) throws -> BundledCompatibilityMatrix {
        let resolvedURL: URL
        if let url {
            resolvedURL = url
        } else if let bundleURL = bundle.url(forResource: "compatibility-matrix", withExtension: "json") {
            resolvedURL = bundleURL
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: resolvedURL)
        return try decode(from: data)
    }

    /// Decodes a compiled `compatibility-matrix.json` payload and enforces non-promotion invariants.
    public static func decode(from data: Data) throws -> BundledCompatibilityMatrix {
        let matrix = try JSONDecoder().decode(BundledCompatibilityMatrix.self, from: data)
        guard matrix.schemaVersion == "1.0.0" else {
            throw CocoaError(.coderReadCorrupt)
        }
        for record in matrix.records {
            let states = record.fiveDimensionStates
            if states.driverLoad != "unknown"
                || states.gameStart != "unknown"
                || states.protectedSession != "unknown" {
                throw CocoaError(.coderReadCorrupt)
            }
        }
        return matrix
    }
}
