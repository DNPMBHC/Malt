// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import IOSurface
import Metal

@available(macOS 27.0, *)
public final class EFIGuestSurfaceLease: @unchecked Sendable {
    public let origin = "uefi_diagnostic_guest_commands_not_Windows_application_scanout"
    public let surface: IOSurfaceRef
    public let readyEvent: MTLSharedEvent
    public let readyValue: UInt64
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    private let lock = NSLock()
    private var renderer: InProcessZeroCopyRenderer?
    private var released = false

    init(renderer: InProcessZeroCopyRenderer) {
        self.renderer = renderer
        surface = renderer.presentBridge.surface
        readyEvent = renderer.presentBridge.sharedEvent
        readyValue = renderer.presentBridge.signalValue
        width = renderer.presentBridge.descriptor.width
        height = renderer.presentBridge.descriptor.height
        bytesPerRow = renderer.presentBridge.descriptor.bytesPerRow
    }

    @discardableResult
    public func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return false }
        released = true
        renderer = nil
        return true
    }
}
