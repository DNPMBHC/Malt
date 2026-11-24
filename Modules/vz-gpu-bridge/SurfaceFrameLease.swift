// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import IOSurface
import Metal

public struct SurfaceFrameMetadata: Encodable, Sendable {
    public let frameID: UInt64
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let readyValue: UInt64
    public let refreshRateMilliHz: Int
    public let origin = "host_synthetic_not_guest_scanout"
    public let pixelFormat = "BGRA8Unorm"
    public let colorSpace = "linear_srgb"
    public let alphaMode = "opaque"
}

// Immutable frame objects cross threads; release state is protected by the lock.
public final class SurfaceFrameLease: @unchecked Sendable {
    public let metadata: SurfaceFrameMetadata
    public let surface: IOSurfaceRef
    public let readyEvent: MTLSharedEvent
    private let releaseAction: () -> Void
    private let lock = NSLock()
    private var returned = false

    public init(metadata: SurfaceFrameMetadata, surface: IOSurfaceRef,
                readyEvent: MTLSharedEvent, onRelease: @escaping () -> Void) {
        self.metadata = metadata
        self.surface = surface
        self.readyEvent = readyEvent
        releaseAction = onRelease
    }

    @discardableResult
    public func release() -> Bool {
        lock.lock()
        guard !returned else {
            lock.unlock()
            return false
        }
        returned = true
        lock.unlock()
        releaseAction()
        return true
    }
}
