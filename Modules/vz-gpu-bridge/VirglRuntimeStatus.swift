// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

public struct VirglRuntimeStatus: Encodable {
    public let callbacksVersion: Int
    public let rendererFlags: Int
    public let renderServerFlagEnabled: Bool
    public let initializationAttempted: Bool
    public let initializationResult: Int
    public let initializationMs: Double
    public let venusCapsetBytes: UInt32
    public let contextCreationResult: Int
    public let guestBlobCreationResult: Int
    public let guestBlobMapResult: Int
    public let guestBlobMappedBytes: UInt64
    public let mappedPointerAliasesInput: Bool
    public let blobExportResult: Int
    public let typedScanoutAndIOSurfaceTested = false

    public init(_ report: DemoRendererFFIReport) {
        callbacksVersion = Int(report.callbacks_version)
        rendererFlags = Int(report.renderer_flags)
        renderServerFlagEnabled = report.renderer_flags & (1 << 9) != 0
        initializationAttempted = report.init_attempted != 0
        initializationResult = Int(report.init_result)
        initializationMs = report.init_ms
        venusCapsetBytes = report.venus_capset_bytes
        contextCreationResult = Int(report.context_result)
        guestBlobCreationResult = Int(report.blob_create_result)
        guestBlobMapResult = Int(report.blob_map_result)
        guestBlobMappedBytes = report.mapped_bytes
        mappedPointerAliasesInput = report.mapped_pointer_aliases_input != 0
        blobExportResult = Int(report.blob_export_result)
    }
}
