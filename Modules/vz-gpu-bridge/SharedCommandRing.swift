// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Darwin
import Foundation
import Metal

public final class SharedCommandRing {
    public let buffer: MTLBuffer
    public let pageSize: Int
    public let slotBytes: Int
    public let slotCount = 4
    private let allocation: UnsafeMutableRawPointer
    public private(set) var submitted: UInt64 = 0
    public private(set) var consumed: UInt64 = 0
    private var leased = false

    public init(device: MTLDevice, maxDraws: Int) throws {
        guard maxDraws > 0, maxDraws <= 65536 else {
            throw NSError(domain: "CommandRing", code: 1)
        }
        pageSize = Int(getpagesize())
        let bytes = maxDraws * MemoryLayout<DrawBatchCommand>.stride
        slotBytes = ((bytes + pageSize - 1) / pageSize) * pageSize
        let total = pageSize + slotBytes * slotCount
        let memory = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0)
        guard let pointer = memory, pointer != MAP_FAILED else {
            throw NSError(domain: "CommandRing", code: 2)
        }
        memset(pointer, 0, total)
        guard let shared = device.makeBuffer(bytesNoCopy: pointer, length: total,
            options: .storageModeShared, deallocator: { memory, length in munmap(memory, length) }) else {
            munmap(pointer, total)
            throw NSError(domain: "CommandRing", code: 3)
        }
        allocation = pointer
        buffer = shared
    }

    public func acquire() throws -> (pointer: UnsafeMutableRawPointer, offset: Int) {
        guard !leased, submitted - consumed < UInt64(slotCount) else {
            throw NSError(domain: "CommandRing", code: 4)
        }
        leased = true
        let offset = pageSize + Int(submitted % UInt64(slotCount)) * slotBytes
        return (allocation.advanced(by: offset), offset)
    }

    public func publish() {
        precondition(leased)
        submitted &+= 1
        allocation.storeBytes(of: submitted, as: UInt64.self)
    }

    public func release() {
        precondition(leased)
        consumed = submitted
        allocation.advanced(by: 8).storeBytes(of: consumed, as: UInt64.self)
        leased = false
    }

    public var aliasesMetalMemory: Bool {
        buffer.contents() == allocation
    }
}
