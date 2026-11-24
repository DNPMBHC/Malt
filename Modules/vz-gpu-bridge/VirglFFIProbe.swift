// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import AppKit
import CryptoKit
import Darwin
import Foundation

public struct VirglSymbolStatus: Encodable {
    public let symbol: String
    public let resolved: Bool
}

public struct VirglFFIProbeReport: Encodable {
    public let owner: String
    public let dylibLoaded: Bool
    public let dylibLogicalSource: String
    public let librarySHA256: String?
    public let kosmicKrispIcdPresent: Bool
    public let requiredSymbolsTotal: Int
    public let requiredSymbolsResolved: Int
    public let symbols: [VirglSymbolStatus]
    public let loadError: String?
    public let runtime: VirglRuntimeStatus?
    public let rendererInitializationTested: Bool
    public let venusNeptuneSubmissionTested = false
    public let iosurfaceExportTested = false
    public let embeddingAssessment: String
}

public enum VirglFFIProbe {
    private static let requiredSymbols = [
        "virgl_renderer_init", "virgl_renderer_cleanup", "virgl_renderer_get_cap_set",
        "virgl_renderer_context_create_with_flags", "virgl_renderer_resource_create_blob",
        "virgl_renderer_resource_map", "virgl_renderer_resource_map_fixed",
        "virgl_renderer_resource_unmap", "virgl_renderer_resource_export_blob",
        "virgl_renderer_submit_cmd", "virgl_renderer_submit_cmd2", "virgl_renderer_context_create_fence",
        "virgl_renderer_export_fence", "virgl_renderer_poll",
        "virgl_renderer_create_handle_for_scanout", "virgl_renderer_release_handle_for_scanout"
    ]

    private static func referenceApplication() -> URL? {
        if let path = ProcessInfo.processInfo.environment["DEMO_RENDERER_BUNDLE"] {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.utmapp.UTM")
    }

    public static func runProbe() -> VirglFFIProbeReport {
        guard let application = referenceApplication() else {
            return report(loaded: false, librarySHA256: nil, icd: false,
                          symbols: [], outcome: ("Reference renderer application unavailable", nil))
        }
        let contents = application.appendingPathComponent("Contents")
        let binary = contents.appendingPathComponent("Frameworks/virglrenderer.1.framework/virglrenderer.1")
        let icd = contents.appendingPathComponent("Resources/vulkan/icd.d/kosmickrisp_mesa_icd.json")
        let digest = (try? Data(contentsOf: binary)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        let icdPresent = FileManager.default.fileExists(atPath: icd.path)
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            let rawError = dlerror().map { String(cString: $0) } ?? "Dynamic loader rejected library"
            return report(loaded: false, librarySHA256: digest, icd: icdPresent,
                          symbols: [], outcome: (sanitize(rawError, application: application), nil))
        }
        defer { dlclose(handle) }
        let symbols = requiredSymbols.map { VirglSymbolStatus(symbol: $0, resolved: dlsym(handle, $0) != nil) }
        if icdPresent { setenv("VK_ICD_FILENAMES", icd.path, 1) }
        let runtime = VirglRuntimeStatus(demo_renderer_ffi_probe(handle))
        return report(loaded: true, librarySHA256: digest, icd: icdPresent,
                      symbols: symbols, outcome: (nil, runtime))
    }

    private static func report(loaded: Bool, librarySHA256: String?, icd: Bool,
                               symbols: [VirglSymbolStatus], outcome: (error: String?, runtime: VirglRuntimeStatus?)
                               ) -> VirglFFIProbeReport {
        let missing = requiredSymbols.map { VirglSymbolStatus(symbol: $0, resolved: false) }
        let complete = symbols.isEmpty ? missing : symbols
        return VirglFFIProbeReport(owner: "@DNPMBHC", dylibLoaded: loaded,
            dylibLogicalSource: "reference-app-renderer-framework", librarySHA256: librarySHA256,
            kosmicKrispIcdPresent: icd, requiredSymbolsTotal: requiredSymbols.count,
            requiredSymbolsResolved: complete.filter { $0.resolved }.count,
            symbols: complete, loadError: outcome.error, runtime: outcome.runtime,
            rendererInitializationTested: outcome.runtime?.initializationAttempted ?? false,
            embeddingAssessment: loaded
                ? "Initialization/blob probes recorded; typed scanout interoperability remains unproven"
                : "Loader boundary blocks embedding; inspect signing and dependency evidence")
    }

    private static func sanitize(_ text: String, application: URL) -> String {
        let clean = text.replacingOccurrences(of: application.path, with: "<reference-app>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        return clean.replacingOccurrences(of: #"/(?:Users|Volumes|private|var)/[^\s"']+"#,
                                         with: "<local-path>", options: .regularExpression)
    }
}
