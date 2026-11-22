// SPDX-License-Identifier: GPL-3.0-or-later
// Host capability collection, dynamic state observation, and reversible scheduling.

import Darwin
import Foundation
import Metal
import MetalFX

struct MetalDeviceCacheKey: Hashable, Sendable {
    let registryID: UInt64
    let name: String
    let isLowPower: Bool
}

struct MetalDeviceCapabilities: Equatable, Sendable {
    let name: String
    let spatialScaling: Bool
    let temporalScaling: Bool
}

final class HostMetalCapabilityCache: @unchecked Sendable {
    static let shared = HostMetalCapabilityCache()

    private let lock = NSLock()
    private var values: [MetalDeviceCacheKey: MetalDeviceCapabilities] = [:]

    func value(
        for key: MetalDeviceCacheKey,
        load: () -> MetalDeviceCapabilities
    ) -> MetalDeviceCapabilities {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] { return cached }
        let result = load()
        values[key] = result
        return result
    }
}

public enum HostCapabilityProvider {
    private struct StaticFacts {
        let operatingSystemVersion: RuntimeHostSnapshot.OSVersion
        let architecture: String
        let isAppleSilicon: Bool
        let gameModePlatformAvailable: Bool
        let isMacOS27OrLater: Bool
        let metalDeviceName: String?
        let metalFXSpatialScalingAvailable: Bool
        let metalFXTemporalScalingAvailable: Bool
        let gpuDeveloperToolsAvailable: Bool
    }

    private static let currentHostFacts = loadCurrentHostFacts()

    public static func current() -> RuntimeHostSnapshot {
        let processInfo = ProcessInfo.processInfo
        let facts = currentHostFacts
        return RuntimeHostSnapshot(
            operatingSystemVersion: facts.operatingSystemVersion,
            architecture: facts.architecture,
            isAppleSilicon: facts.isAppleSilicon,
            gameModePlatformAvailable: facts.gameModePlatformAvailable,
            isMacOS27OrLater: facts.isMacOS27OrLater,
            thermalState: HostThermalState(processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            metalDeviceName: facts.metalDeviceName,
            metalFXSpatialScalingAvailable: facts.metalFXSpatialScalingAvailable,
            metalFXTemporalScalingAvailable: facts.metalFXTemporalScalingAvailable,
            gpuDeveloperToolsAvailable: facts.gpuDeveloperToolsAvailable
        )
    }

    public static func snapshot(
        processInfo: ProcessInfo,
        metalDevices: [any MTLDevice]
    ) -> RuntimeHostSnapshot {
        let version = processInfo.operatingSystemVersion
        let versionInfo = RuntimeHostSnapshot.OSVersion(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion
        )
        let architecture = currentArchitecture()
        let appleSilicon = isAppleSilicon(architecture: architecture)
        let facts = makeStaticFacts(
            operatingSystemVersion: versionInfo,
            architecture: architecture,
            isAppleSilicon: appleSilicon,
            metalDevices: metalDevices
        )
        return RuntimeHostSnapshot(
            operatingSystemVersion: facts.operatingSystemVersion,
            architecture: facts.architecture,
            isAppleSilicon: facts.isAppleSilicon,
            gameModePlatformAvailable: facts.gameModePlatformAvailable,
            isMacOS27OrLater: facts.isMacOS27OrLater,
            thermalState: HostThermalState(processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            metalDeviceName: facts.metalDeviceName,
            metalFXSpatialScalingAvailable: facts.metalFXSpatialScalingAvailable,
            metalFXTemporalScalingAvailable: facts.metalFXTemporalScalingAvailable,
            gpuDeveloperToolsAvailable: facts.gpuDeveloperToolsAvailable
        )
    }

    private static func loadCurrentHostFacts() -> StaticFacts {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        let versionInfo = RuntimeHostSnapshot.OSVersion(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion
        )
        let architecture = currentArchitecture()
        return makeStaticFacts(
            operatingSystemVersion: versionInfo,
            architecture: architecture,
            isAppleSilicon: isAppleSilicon(architecture: architecture),
            metalDevices: MTLCopyAllDevices()
        )
    }

    private static func makeStaticFacts(
        operatingSystemVersion: RuntimeHostSnapshot.OSVersion,
        architecture: String,
        isAppleSilicon: Bool,
        metalDevices: [any MTLDevice]
    ) -> StaticFacts {
        let device = metalDevices.first(where: { !$0.isLowPower }) ?? metalDevices.first
        let metalCapabilities = device.map(capabilities(for:))
        return StaticFacts(
            operatingSystemVersion: operatingSystemVersion,
            architecture: architecture,
            isAppleSilicon: isAppleSilicon,
            // This is platform eligibility only; it does not report that Game Mode is active.
            gameModePlatformAvailable: gameModePlatformEligibility(
                version: operatingSystemVersion,
                isAppleSilicon: isAppleSilicon
            ),
            isMacOS27OrLater: operatingSystemVersion.major >= 27,
            metalDeviceName: metalCapabilities?.name,
            metalFXSpatialScalingAvailable: metalCapabilities?.spatialScaling ?? false,
            metalFXTemporalScalingAvailable: metalCapabilities?.temporalScaling ?? false,
            gpuDeveloperToolsAvailable: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        )
    }

    static func gameModePlatformEligibility(
        version: RuntimeHostSnapshot.OSVersion,
        isAppleSilicon: Bool
    ) -> Bool {
        isAppleSilicon && version.major >= 14
    }

    private static func capabilities(for device: any MTLDevice) -> MetalDeviceCapabilities {
        let key = MetalDeviceCacheKey(
            registryID: device.registryID,
            name: device.name,
            isLowPower: device.isLowPower
        )
        return HostMetalCapabilityCache.shared.value(for: key) {
            MetalDeviceCapabilities(
                name: device.name,
                spatialScaling: MTLFXSpatialScalerDescriptor.supportsDevice(device),
                temporalScaling: MTLFXTemporalScalerDescriptor.supportsDevice(device)
            )
        }
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func isAppleSilicon(architecture: String) -> Bool {
        if architecture == "arm64" { return true }
        guard architecture == "x86_64" else { return false }
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        return result == 0 && arm64 == 1
    }
}
