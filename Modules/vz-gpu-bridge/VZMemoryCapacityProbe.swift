// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import Virtualization

public struct VZMemoryCapacityResult: Encodable {
    public let owner = "@DNPMBHC"
    public let requestedBytes: UInt64
    public let validated: Bool
    public let errorDomain: String?
    public let errorCode: Int?
    public let physicalAllocationAttempted = false
    public let scope = "configuration_aperture_not_committed_physical_RAM"
}

@available(macOS 27.0, *)
public enum VZMemoryCapacityProbe {
    public static func run(bytes: UInt64) -> VZMemoryCapacityResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let boot = VZEFIBootLoader()
            boot.variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: directory.appendingPathComponent("nvram")
            )
            let config = VZVirtualMachineConfiguration()
            config.platform = VZGenericPlatformConfiguration()
            config.bootLoader = boot
            config.cpuCount = 2
            config.memorySize = 512 * 1024 * 1024
            let controller = VZVirtioGPUDeviceController()
            config.customVirtioDevices = [controller.makeConfiguration(
                options: VZVirtioGPUConfigOptions(sharedMemoryBytes: bytes)
            )]
            try config.validate()
            return VZMemoryCapacityResult(requestedBytes: bytes, validated: true, errorDomain: nil, errorCode: nil)
        } catch {
            let native = error as NSError
            return VZMemoryCapacityResult(requestedBytes: bytes, validated: false,
                                          errorDomain: native.domain, errorCode: native.code)
        }
    }
}
