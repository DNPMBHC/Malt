// SPDX-License-Identifier: GPL-3.0-or-later
// VirtIO-GPU 1.3 modern PCI constants, feature bits, device config, and control headers.
// Owner: @DNPMBHC

import Foundation

public enum VirtioGPUSpec {
    public static let pciVendorID: UInt16 = 0x1AF4
    public static let pciModernDeviceID: UInt16 = 0x1050
    public static let virtioDeviceID: UInt16 = 16
    public static let pciClassDisplay: UInt8 = 0x03
    public static let pciSubclassOther: UInt8 = 0x80
    public static let controlQueueIndex: UInt16 = 0
    public static let cursorQueueIndex: UInt16 = 1
    public static let queueCount: UInt16 = 2
    public static let hostVisibleShmRegionID: UInt8 = 1

    // VirtIO-GPU feature bits (subset0: bits 0..31)
    public static let featureVirgl: UInt32 = 1 << 0
    public static let featureEDID: UInt32 = 1 << 1
    public static let featureResourceUUID: UInt32 = 1 << 2
    public static let featureResourceBlob: UInt32 = 1 << 3
    public static let featureContextInit: UInt32 = 1 << 4

    public static let defaultOptionalFeatures: UInt32 =
        0 // Enable features only after their backend operations pass integration tests.

    // VirtIO-GPU control command types (subset)
    public static let cmdGetDisplayInfo: UInt32 = 0x0100
    public static let cmdResourceCreateBlob: UInt32 = 0x010C
    public static let cmdCtxCreate: UInt32 = 0x0200
    public static let cmdSubmit3D: UInt32 = 0x0207
    public static let respOkNoData: UInt32 = 0x1100
    public static let respOkDisplayInfo: UInt32 = 0x1101
    public static let respErrInvalidParameter: UInt32 = 0x1205
    public static let respErrUnspec: UInt32 = 0x1200
}

public struct VirtioGPUDeviceConfig: Equatable {
    public var eventsRead: UInt32
    public var eventsClear: UInt32
    public var numScanouts: UInt32
    public var numCapsets: UInt32

    public init(eventsRead: UInt32 = 0, eventsClear: UInt32 = 0, numScanouts: UInt32 = 1, numCapsets: UInt32 = 0) {
        self.eventsRead = eventsRead
        self.eventsClear = eventsClear
        self.numScanouts = numScanouts
        self.numCapsets = numCapsets
    }

    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(16)
        appendLE(eventsRead, to: &data)
        appendLE(eventsClear, to: &data)
        appendLE(numScanouts, to: &data)
        appendLE(numCapsets, to: &data)
        return data
    }
}

public struct VirtioGPUCtrlHeader: Equatable {
    public static let byteSize = 24

    public let type: UInt32
    public let flags: UInt32
    public let fenceID: UInt64
    public let ctxID: UInt32
    public let ringIdx: UInt8

    public init(type: UInt32, flags: UInt32 = 0, fenceID: UInt64 = 0, ctxID: UInt32 = 0, ringIdx: UInt8 = 0) {
        self.type = type
        self.flags = flags
        self.fenceID = fenceID
        self.ctxID = ctxID
        self.ringIdx = ringIdx
    }

    public static func decode(_ data: Data) -> VirtioGPUCtrlHeader? {
        guard data.count >= byteSize else { return nil }
        return VirtioGPUCtrlHeader(
            type: readLE32(data, at: 0),
            flags: readLE32(data, at: 4),
            fenceID: readLE64(data, at: 8),
            ctxID: readLE32(data, at: 16),
            ringIdx: data[data.startIndex + 20]
        )
    }

    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(Self.byteSize)
        appendLE(type, to: &data)
        appendLE(flags, to: &data)
        appendLE(fenceID, to: &data)
        appendLE(ctxID, to: &data)
        data.append(ringIdx)
        data.append(contentsOf: [0, 0, 0])
        return data
    }
}

private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    let byte0 = UInt32(data[data.startIndex + offset])
    let byte1 = UInt32(data[data.startIndex + offset + 1]) << 8
    let byte2 = UInt32(data[data.startIndex + offset + 2]) << 16
    let byte3 = UInt32(data[data.startIndex + offset + 3]) << 24
    return byte0 | byte1 | byte2 | byte3
}

private func readLE64(_ data: Data, at offset: Int) -> UInt64 {
    let low = UInt64(readLE32(data, at: offset))
    let high = UInt64(readLE32(data, at: offset + 4)) << 32
    return low | high
}
