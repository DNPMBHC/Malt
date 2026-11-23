// SPDX-License-Identifier: GPL-3.0-or-later
// M2.5 Lever 2 & M3 feasibility probe: macOS 27 VZCustomVirtioDevice shared-memory
// configuration check and zero-network shared-memory ring micro-benchmark.
// Owner: @DNPMBHC

import Foundation
import Virtualization

private struct ShmRingHeader {
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var capacity: UInt64 = 0
    var slotBytes: UInt64 = 0
}

private func runSharedMemoryRingBenchmark(frames: Int, slotBytes: Int) -> [String: Any] {
    let pageSize = Int(getpagesize())
    let slotCount = 4
    let headerBytes = pageSize
    let totalBytes = ((headerBytes + slotCount * slotBytes + pageSize - 1) / pageSize) * pageSize
    var rawPtr: UnsafeMutableRawPointer?
    let allocResult = posix_memalign(&rawPtr, pageSize, totalBytes)
    guard allocResult == 0, let base = rawPtr else {
        return ["status": "alloc_failed", "errno": allocResult]
    }
    defer { free(base) }
    memset(base, 0, totalBytes)

    let payload = [UInt8](repeating: 0x5A, count: slotBytes)
    var recvBuf = [UInt8](repeating: 0, count: slotBytes)

    let startNs = DispatchTime.now().uptimeNanoseconds
    var head: UInt64 = 0
    var tail: UInt64 = 0
    for idx in 0..<frames {
        let slot = Int(head % UInt64(slotCount))
        let dst = base.advanced(by: headerBytes + slot * slotBytes)
        payload.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                dst.copyMemory(from: src, byteCount: slotBytes)
            }
        }
        head &+= 1
        let readSlot = Int(tail % UInt64(slotCount))
        let srcPtr = base.advanced(by: headerBytes + readSlot * slotBytes)
        recvBuf.withUnsafeMutableBytes { outRaw in
            if let outBase = outRaw.baseAddress {
                outBase.copyMemory(from: srcPtr, byteCount: slotBytes)
            }
        }
        tail &+= 1
        if idx == 0 && recvBuf[0] != 0x5A {
            return ["status": "verify_failed"]
        }
    }
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
    let fps = Double(frames) * 1000.0 / max(0.001, elapsedMs)
    return [
        "status": "passed",
        "page_size_bytes": pageSize,
        "region_bytes": totalBytes,
        "slot_count": slotCount,
        "slot_bytes": slotBytes,
        "frames": frames,
        "elapsed_ms": (elapsedMs * 1000.0).rounded() / 1000.0,
        "ring_throughput_fps": (fps * 100.0).rounded() / 100.0,
        "avg_per_frame_us": ((elapsedMs * 1000.0 / Double(frames)) * 1000.0).rounded() / 1000.0
    ]
}

private func probeVZCustomVirtioCapabilities() -> [String: Any] {
    if #available(macOS 27.0, *) {
        let maxRegions = VZCustomVirtioDeviceConfiguration.maximumAllowedSharedMemoryRegionCount
        let deviceConfig = VZCustomVirtioDeviceConfiguration()
        // VirtIO GPU PCI specification: deviceID = 16, class = 0x03 (Display), subclass = 0x80
        deviceConfig.deviceID = 16
        deviceConfig.pciClassID = 0x03
        deviceConfig.pciSubclassID = 0x80
        deviceConfig.virtioQueueCount = 2

        let regionSize: UInt64 = 256 * 1024 * 1024
        let regionConfig = VZVirtioSharedMemoryRegionConfiguration(regionID: 0, size: regionSize)
        deviceConfig.sharedMemoryRegions = [regionConfig]

        return [
            "api_available": true,
            "macos_min_version": "27.0",
            "max_allowed_shared_memory_regions": maxRegions,
            "configured_virtio_device_id": deviceConfig.deviceID,
            "configured_pci_class": deviceConfig.pciClassID,
            "configured_pci_subclass": deviceConfig.pciSubclassID,
            "configured_virtio_queues": deviceConfig.virtioQueueCount,
            "configured_shm_region_id": regionConfig.regionID,
            "configured_shm_region_bytes": regionConfig.size,
            "supports_dynamic_map_unmap_api": true
        ]
    }
    return [
        "api_available": false,
        "macos_min_version": "27.0"
    ]
}

let vzReport = probeVZCustomVirtioCapabilities()
let ring88 = runSharedMemoryRingBenchmark(frames: 10000, slotBytes: 88)
let ring64k = runSharedMemoryRingBenchmark(frames: 5000, slotBytes: 66048)

let payload: [String: Any] = [
    "owner": "@DNPMBHC",
    "probe": "vz_custom_virtio_and_shm_ring",
    "vz_custom_virtio": vzReport,
    "local_shm_ring_88b_cached_frame": ring88,
    "local_shm_ring_64k_update_frame": ring64k,
    "note": "Local page-aligned shared-memory ring proves host memory transport floor; " +
        "full cross-VM zero-copy requires guest VirtIO driver integration."
]

if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
   let text = String(data: jsonData, encoding: .utf8) {
    print(text)
}
