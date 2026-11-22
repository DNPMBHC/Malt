// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import MetalFX

/// Support queries only. No field asserts that a renderer created or executed these features.
public struct HostExtendedGraphicsCapabilities: Codable, Equatable, Sendable {
    public let devicePresent: Bool
    public let metal4APIsAvailable: Bool
    public let metal4FamilySupported: Bool
    public let metal4SpatialSupported: Bool
    public let metal4TemporalSupported: Bool
    public let frameInterpolationSupported: Bool
    public let metal4FrameInterpolationSupported: Bool
    public let actualFeatureUse: String
}

public extension HostCapabilityProvider {
    static func extendedGraphicsCapabilities(for device: (any MTLDevice)?) -> HostExtendedGraphicsCapabilities {
        guard let device else {
            return HostExtendedGraphicsCapabilities(
                devicePresent: false, metal4APIsAvailable: false, metal4FamilySupported: false,
                metal4SpatialSupported: false, metal4TemporalSupported: false,
                frameInterpolationSupported: false, metal4FrameInterpolationSupported: false,
                actualFeatureUse: "not-tested"
            )
        }
        let key = MetalDeviceCacheKey(registryID: device.registryID, name: device.name, isLowPower: device.isLowPower)
        return HostExtendedGraphicsCache.shared.value(for: key) {
            if #available(macOS 26.0, *) {
                return HostExtendedGraphicsCapabilities(
                    devicePresent: true, metal4APIsAvailable: true,
                    metal4FamilySupported: device.supportsFamily(.metal4),
                    metal4SpatialSupported: MTLFXSpatialScalerDescriptor.supportsMetal4FX(device),
                    metal4TemporalSupported: MTLFXTemporalScalerDescriptor.supportsMetal4FX(device),
                    frameInterpolationSupported: MTLFXFrameInterpolatorDescriptor.supportsDevice(device),
                    metal4FrameInterpolationSupported: MTLFXFrameInterpolatorDescriptor.supportsMetal4FX(device),
                    actualFeatureUse: "not-tested"
                )
            }
            return HostExtendedGraphicsCapabilities(
                devicePresent: true, metal4APIsAvailable: false, metal4FamilySupported: false,
                metal4SpatialSupported: false, metal4TemporalSupported: false,
                frameInterpolationSupported: false, metal4FrameInterpolationSupported: false,
                actualFeatureUse: "not-tested"
            )
        }
    }
}

private final class HostExtendedGraphicsCache: @unchecked Sendable {
    static let shared = HostExtendedGraphicsCache()
    private let lock = NSLock()
    private var values: [MetalDeviceCacheKey: HostExtendedGraphicsCapabilities] = [:]

    func value(
        for key: MetalDeviceCacheKey, load: () -> HostExtendedGraphicsCapabilities
    ) -> HostExtendedGraphicsCapabilities {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] { return cached }
        let result = load()
        values[key] = result
        return result
    }
}
