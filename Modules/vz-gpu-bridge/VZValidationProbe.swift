// SPDX-License-Identifier: GPL-3.0-or-later
// Real VZVirtualMachineConfiguration.validate() boundary probe on macOS 27.
// Owner: @DNPMBHC

import Foundation
import Virtualization

public struct VZCaseResult: Encodable {
    public let sharedMemoryMiB: UInt64?
    public let validated: Bool
    public let errorDomain: String?
    public let errorCode: Int
    public let errorSummary: String?
}

public struct VZPCISpecSummary: Encodable {
    public let vendorID: String
    public let deviceID: String
    public let virtioDeviceID: UInt16
    public let pciClass: String
    public let pciSubclass: String
    public let virtioQueues: Int
}

public struct VZSecureBootProbe: Encodable {
    public let apiAvailable: Bool
    public let className: String
    public let initialKEKCount: Int
    public let initialDBCount: Int
    public let initialDBXCount: Int
}

public struct VZEntitlementProbe: Encodable {
    public let codesignExit: Int32
    public let hasVirtualizationEntitlement: Bool
    public let hardenedRuntimeFlag: Bool
}

public struct VZValidationReport: Encodable {
    public let owner: String
    public let hostPageSizeBytes: Int
    public let maxAllowedSharedMemoryRegions: Int
    public let pciModernSpec: VZPCISpecSummary
    public let maxValidatedSharedMemoryMiB: UInt64
    public let sharedMemoryLadder: [VZCaseResult]
    public let unaligned4KCase: VZCaseResult
    public let twoRegionsCase: VZCaseResult
    public let efiSecureBootAPI: VZSecureBootProbe
    public let nativeVtpmApiInSDK: Bool
    public let entitlementProbe: VZEntitlementProbe
}

public enum VZValidationProbe {
    public static func runFullProbe() -> VZValidationReport {
        guard #available(macOS 27.0, *) else {
            return makeUnsupportedReport()
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vz-gpu-bridge-validate-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nvramURL = tempDir.appendingPathComponent("efi-nvram.bin")
        let (maxMiB, ladder) = runSharedMemoryLadder(nvramURL: nvramURL)
        let unaligned = validateSingleCase(
            nvramURL: nvramURL,
            sizeMiB: nil,
            options: VZVirtioGPUConfigOptions(sharedMemoryBytes: 64 * 1024 * 1024 + 4096, sharedMemoryRegionCount: 1)
        )
        let twoRegions = validateSingleCase(
            nvramURL: nvramURL,
            sizeMiB: 64,
            options: VZVirtioGPUConfigOptions(sharedMemoryBytes: 64 * 1024 * 1024, sharedMemoryRegionCount: 2)
        )
        return VZValidationReport(
            owner: "@DNPMBHC",
            hostPageSizeBytes: Int(getpagesize()),
            maxAllowedSharedMemoryRegions: VZCustomVirtioDeviceConfiguration.maximumAllowedSharedMemoryRegionCount,
            pciModernSpec: VZPCISpecSummary(
                vendorID: "0x1af4",
                deviceID: "0x1050",
                virtioDeviceID: VirtioGPUSpec.virtioDeviceID,
                pciClass: "0x03",
                pciSubclass: "0x80",
                virtioQueues: Int(VirtioGPUSpec.queueCount)
            ),
            maxValidatedSharedMemoryMiB: maxMiB,
            sharedMemoryLadder: ladder,
            unaligned4KCase: unaligned,
            twoRegionsCase: twoRegions,
            efiSecureBootAPI: probeEFISecureBootCapability(),
            nativeVtpmApiInSDK: false,
            entitlementProbe: probeCurrentProcessEntitlements()
        )
    }

    @available(macOS 27.0, *)
    private static func runSharedMemoryLadder(nvramURL: URL) -> (UInt64, [VZCaseResult]) {
        let sizeLadderMiB: [UInt64] = [64, 256, 1024, 2048, 4096, 8192, 16384, 65536, 1048576]
        var results: [VZCaseResult] = []
        var maxValidated: UInt64 = 0
        for sizeMiB in sizeLadderMiB {
            let bytes = sizeMiB * 1024 * 1024
            let res = validateSingleCase(
                nvramURL: nvramURL,
                sizeMiB: sizeMiB,
                options: VZVirtioGPUConfigOptions(sharedMemoryBytes: bytes, sharedMemoryRegionCount: 1)
            )
            if res.validated {
                maxValidated = sizeMiB
            }
            results.append(res)
        }
        return (maxValidated, results)
    }

    @available(macOS 27.0, *)
    private static func validateSingleCase(
        nvramURL: URL,
        sizeMiB: UInt64?,
        options: VZVirtioGPUConfigOptions
    ) -> VZCaseResult {
        do {
            try? FileManager.default.removeItem(at: nvramURL)
            let store = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = store
            let config = VZVirtualMachineConfiguration()
            config.bootLoader = bootLoader
            config.platform = VZGenericPlatformConfiguration()
            config.cpuCount = max(2, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
            config.memorySize = max(
                2 * 1024 * 1024 * 1024,
                VZVirtualMachineConfiguration.minimumAllowedMemorySize
            )
            let controller = VZVirtioGPUDeviceController()
            config.customVirtioDevices = [controller.makeConfiguration(options: options)]
            try config.validate()
            return VZCaseResult(
                sharedMemoryMiB: sizeMiB,
                validated: true,
                errorDomain: nil,
                errorCode: 0,
                errorSummary: nil
            )
        } catch {
            let nsErr = error as NSError
            return VZCaseResult(
                sharedMemoryMiB: sizeMiB,
                validated: false,
                errorDomain: nsErr.domain,
                errorCode: nsErr.code,
                errorSummary: sanitizeError(nsErr.localizedDescription)
            )
        }
    }

    @available(macOS 27.0, *)
    private static func probeEFISecureBootCapability() -> VZSecureBootProbe {
        let sigDB = VZEFISignatureDatabaseConfiguration(
            keyExchangeKeys: [],
            dbSignatures: [],
            dbxSignatures: []
        )
        return VZSecureBootProbe(
            apiAvailable: true,
            className: "VZEFISignatureDatabaseConfiguration",
            initialKEKCount: sigDB.keyExchangeKeys.count,
            initialDBCount: sigDB.dbSignatures.count,
            initialDBXCount: sigDB.dbxSignatures.count
        )
    }

    private static func probeCurrentProcessEntitlements() -> VZEntitlementProbe {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", "--entitlements", ":-", CommandLine.arguments[0]]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return VZEntitlementProbe(
                codesignExit: task.terminationStatus,
                hasVirtualizationEntitlement: out.contains("com.apple.security.virtualization"),
                hardenedRuntimeFlag: err.contains("runtime")
            )
        } catch {
            return VZEntitlementProbe(
                codesignExit: -1,
                hasVirtualizationEntitlement: false,
                hardenedRuntimeFlag: false
            )
        }
    }

    private static func makeUnsupportedReport() -> VZValidationReport {
        let empty = VZCaseResult(
            sharedMemoryMiB: nil,
            validated: false,
            errorDomain: "OSVersion",
            errorCode: -1,
            errorSummary: "macOS 27.0+ required"
        )
        return VZValidationReport(
            owner: "@DNPMBHC",
            hostPageSizeBytes: Int(getpagesize()),
            maxAllowedSharedMemoryRegions: 0,
            pciModernSpec: VZPCISpecSummary(
                vendorID: "0x1af4",
                deviceID: "0x1050",
                virtioDeviceID: VirtioGPUSpec.virtioDeviceID,
                pciClass: "0x03",
                pciSubclass: "0x80",
                virtioQueues: Int(VirtioGPUSpec.queueCount)
            ),
            maxValidatedSharedMemoryMiB: 0,
            sharedMemoryLadder: [],
            unaligned4KCase: empty,
            twoRegionsCase: empty,
            efiSecureBootAPI: VZSecureBootProbe(
                apiAvailable: false,
                className: "VZEFISignatureDatabaseConfiguration",
                initialKEKCount: 0,
                initialDBCount: 0,
                initialDBXCount: 0
            ),
            nativeVtpmApiInSDK: false,
            entitlementProbe: probeCurrentProcessEntitlements()
        )
    }

    private static func sanitizeError(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "\n", with: " ")
        return String(trimmed.prefix(180))
    }
}
