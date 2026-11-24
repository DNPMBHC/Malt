// SPDX-License-Identifier: GPL-3.0-or-later
// macOS 27 VZCustomVirtioDevice VirtIO-GPU configuration and dual-VirtQueue delegate.
// Owner: @DNPMBHC

import Foundation
import Virtualization

public struct VZVirtioGPUConfigOptions {
    public var sharedMemoryBytes: UInt64
    public var sharedMemoryRegionCount: Int
    public var numScanouts: UInt32
    public var numCapsets: UInt32

    public init(
        sharedMemoryBytes: UInt64 = 256 * 1024 * 1024,
        sharedMemoryRegionCount: Int = 1,
        numScanouts: UInt32 = 1,
        numCapsets: UInt32 = 0
    ) {
        self.sharedMemoryBytes = sharedMemoryBytes
        self.sharedMemoryRegionCount = sharedMemoryRegionCount
        self.numScanouts = numScanouts
        self.numCapsets = numCapsets
    }
}

@available(macOS 27.0, *)
public final class VZVirtioGPUDeviceController: NSObject,
    VZCustomVirtioDeviceConfigurationDelegate,
    VZCustomVirtioDeviceDelegate {
    public let deviceQueue: DispatchQueue
    public private(set) var activeDevice: VZCustomVirtioDevice?
    public private(set) var driverAccepted = false
    public private(set) var processedControlElements: UInt64 = 0
    public private(set) var processedCursorElements: UInt64 = 0

    public init(label: String = "demo-app.device") {
        self.deviceQueue = DispatchQueue(label: label, qos: .userInteractive)
        super.init()
    }

    public func makeConfiguration(options: VZVirtioGPUConfigOptions) -> VZCustomVirtioDeviceConfiguration {
        let config = VZCustomVirtioDeviceConfiguration()
        config.deviceID = VirtioGPUSpec.virtioDeviceID
        config.pciClassID = VirtioGPUSpec.pciClassDisplay
        config.pciSubclassID = VirtioGPUSpec.pciSubclassOther
        config.virtioQueueCount = VirtioGPUSpec.queueCount
        config.optionalFeatures.subset0 = VirtioGPUSpec.defaultOptionalFeatures

        let gpuConfig = VirtioGPUDeviceConfig(
            numScanouts: options.numScanouts,
            numCapsets: options.numCapsets
        )
        config.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: gpuConfig.encode()
        )
        config.provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: deviceQueue,
            delegate: self
        )

        var regions: [VZVirtioSharedMemoryRegionConfiguration] = []
        if options.sharedMemoryRegionCount > 0 && options.sharedMemoryBytes > 0 {
            for idx in 0..<options.sharedMemoryRegionCount {
                let region = VZVirtioSharedMemoryRegionConfiguration(
                    regionID: VirtioGPUSpec.hostVisibleShmRegionID + UInt8(idx),
                    size: options.sharedMemoryBytes
                )
                regions.append(region)
            }
        }
        config.sharedMemoryRegions = regions
        return config
    }

    public func customVirtioConfiguration(
        _ deviceConfiguration: VZCustomVirtioDeviceConfiguration,
        didCreateDevice device: VZCustomVirtioDevice
    ) {
        activeDevice = device
        device.delegate = self
    }

    public func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        driverAccepted = true
    }

    public func customVirtioDevice(
        _ device: VZCustomVirtioDevice,
        didReceiveNotificationFor queue: VZVirtioQueue
    ) {
        while let element = queue.nextElement() {
            if queue.queueIndex == VirtioGPUSpec.controlQueueIndex {
                handleControlElement(element)
                processedControlElements &+= 1
            } else if queue.queueIndex == VirtioGPUSpec.cursorQueueIndex {
                processedCursorElements &+= 1
            }
            element.returnToQueue()
        }
    }

    public func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        driverAccepted = false
    }

    public func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        driverAccepted = false
    }

    private func handleControlElement(_ element: VZVirtioQueueElement) {
        let bytes = element.readBuffersAvailableByteCount
        guard bytes >= VirtioGPUCtrlHeader.byteSize, bytes <= 65536,
              let snapshot = try? element.readBytes(withExactLength: bytes) else {
            return
        }
        let reply = VirtioGPUCommandProcessor.response(to: snapshot)
        guard element.writeBuffersAvailableByteCount >= reply.count else { return }
        try? element.write(reply)
    }
}
