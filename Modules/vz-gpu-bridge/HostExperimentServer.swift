// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Darwin
import Foundation

@available(macOS 27.0, *)
public enum HostExperimentServer {
    public static func run() throws {
        let validation = VZValidationProbe.runFullProbe()
        guard validation.maxValidatedSharedMemoryMiB > 0 else { throw NSError(domain: "HostServer", code: 1) }
        let renderer = try InProcessZeroCopyRenderer(width: 64, height: 64, maxDraws: 64)
        try renderer.renderFrame(drawCalls: 64, frameIndex: 0, readbackToBuffer: nil)
        try printJSON(["ready": true, "realConfigurationValidated": true,
                       "Metal4GPUCompleted": true, "sharedBufferAliased": renderer.ring.aliasesMetalMemory])
        fflush(stdout)
        let keepAlive = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            _ = ProcessInfo.processInfo.systemUptime
        }
        withExtendedLifetime((renderer, keepAlive)) { RunLoop.current.run() }
    }
}
