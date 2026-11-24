// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import Metal
import Virtualization

public struct EFIGuestProbeReport: Encodable {
    public let owner = "@DNPMBHC"
    public let scope = "isolated_UEFI_diagnostic_not_Windows_WDDM_or_Venus"
    public let configurationValidated: Bool
    public let guestStarted: Bool
    public let guestStopped: Bool
    public let driverOkObserved: Bool
    public let controlElements: UInt64
    public let cursorElements: UInt64
    public let guestSharedMemoryWriteObserved: Bool
    public let sameVZAndMetalCommandMemory: Bool
    public let drawCalls: Int
    public let width: Int
    public let height: Int
    public let imageSHA256: String
    public let referenceSHA256: String
    public let pixelsMatchReference: Bool
}

private struct EFIGuestRunState {
    let stopped: Bool
    let negotiated: Bool
    let wrote: Bool
}

@available(macOS 27.0, *)
public enum EFIGuestProbe {
    public static func run(disk: URL, width: Int, height: Int,
                           sharedMemoryBytes: UInt64,
                           onFrame: ((EFIGuestSurfaceLease) -> Void)? = nil) throws -> EFIGuestProbeReport {
        guard (1...8192).contains(width), (1...8192).contains(height) else {
            throw NSError(domain: "EFIGuestBounds", code: 1)
        }
        let renderer = try InProcessZeroCopyRenderer(width: width, height: height, maxDraws: 2048)
        guard sharedMemoryBytes >= UInt64(renderer.ring.buffer.length) else {
            throw NSError(domain: "EFIGuestBounds", code: 2)
        }
        let slot = try renderer.ring.acquire()
        defer { renderer.ring.release() }
        initializeMailbox(renderer: renderer, offset: slot.offset)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = VZVirtioGPUDeviceController(label: "demo-app.efi-device")
        let queue = DispatchQueue(label: "demo-app.efi-machine")
        let machine = try makeMachine(disk: disk, directory: directory, controller: controller, queue: queue,
                                      sharedMemoryBytes: sharedMemoryBytes)
        try start(machine, queue: queue)
        var stopped = false
        defer { if !stopped { _ = stop(machine, queue: queue) } }
        guard let region = controller.deviceQueue.sync(execute: { controller.activeDevice?.sharedMemoryRegions.first })
        else { throw NSError(domain: "EFIGuestDevice", code: 1) }
        guard waitForGuestQueues(controller: controller) else {
            throw NSError(domain: "EFIGuestQueues", code: 1)
        }
        try map(region, renderer: renderer, queue: controller.deviceQueue, removing: false)
        var mapped = true
        defer { if mapped { try? map(region, renderer: renderer, queue: controller.deviceQueue, removing: true) } }
        let wrote = waitForGuestMailbox(renderer: renderer)
        let digests = try renderMailbox(renderer: renderer, offset: slot.offset, guestWrote: wrote)
        Thread.sleep(forTimeInterval: 0.5)
        let negotiated = controller.deviceQueue.sync { controller.driverAccepted }
        let counts = controller.deviceQueue.sync {
            (controller.processedControlElements, controller.processedCursorElements)
        }
        try map(region, renderer: renderer, queue: controller.deviceQueue, removing: true)
        mapped = false
        stopped = stop(machine, queue: queue)
        if wrote, stopped, digests.actual == digests.reference, let onFrame {
            onFrame(EFIGuestSurfaceLease(renderer: renderer))
        }
        let state = EFIGuestRunState(stopped: stopped, negotiated: negotiated, wrote: wrote)
        return makeReport(renderer: renderer, state: state,
                          counts: counts, digests: digests)
    }

    private static func makeReport(renderer: InProcessZeroCopyRenderer,
                                   state: EFIGuestRunState,
                                   counts: (UInt64, UInt64),
                                   digests: (actual: String, reference: String)) -> EFIGuestProbeReport {
        EFIGuestProbeReport(configurationValidated: true, guestStarted: true, guestStopped: state.stopped,
            driverOkObserved: state.negotiated, controlElements: counts.0, cursorElements: counts.1,
            guestSharedMemoryWriteObserved: state.wrote,
            sameVZAndMetalCommandMemory: renderer.ring.aliasesMetalMemory,
            drawCalls: state.wrote ? 2048 : 0, width: renderer.presentBridge.descriptor.width,
            height: renderer.presentBridge.descriptor.height, imageSHA256: digests.actual,
            referenceSHA256: digests.reference,
            pixelsMatchReference: state.wrote && digests.actual == digests.reference)
    }

    private static func initializeMailbox(renderer: InProcessZeroCopyRenderer, offset: Int) {
        let pointer = renderer.ring.buffer.contents()
        pointer.advanced(by: 16).storeBytes(of: UInt32(2048), as: UInt32.self)
        pointer.advanced(by: 32).storeBytes(of: UInt64(offset), as: UInt64.self)
        pointer.advanced(by: 48).storeBytes(of: UInt32(0x44454D4F), as: UInt32.self)
    }

    private static func waitForGuestQueues(controller: VZVirtioGPUDeviceController) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let ready = controller.deviceQueue.sync {
                controller.driverAccepted && controller.processedCursorElements > 0
            }
            if ready { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private static func waitForGuestMailbox(renderer: InProcessZeroCopyRenderer) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if renderer.ring.buffer.contents().advanced(by: 56).load(as: UInt32.self) == 0x444F4E45 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static func renderMailbox(renderer: InProcessZeroCopyRenderer, offset: Int,
                                      guestWrote: Bool) throws -> (actual: String, reference: String) {
        guard guestWrote else { return ("", "") }
        renderer.ring.publish()
        let bridge = renderer.presentBridge
        let engine = try Metal4Engine(device: renderer.device, ring: renderer.ring.buffer, texture: bridge.texture)
        let signal = bridge.nextSignalValue()
        try engine.submit(ring: renderer.ring.buffer, offset: offset, draws: 2048,
                          texture: bridge.texture, fence: (bridge.sharedEvent, signal))
        guard bridge.sharedEvent.wait(untilSignaledValue: signal, timeoutMS: 10000) else {
            throw NSError(domain: "EFIGuestGPU", code: 1)
        }
        let reference = try InProcessZeroCopyRenderer(width: bridge.descriptor.width,
                                                     height: bridge.descriptor.height, maxDraws: 2048)
        try reference.renderFrame(drawCalls: 2048, frameIndex: 77, readbackToBuffer: nil)
        return (renderer.imageSHA256(), reference.imageSHA256())
    }

    private static func makeMachine(disk: URL, directory: URL, controller: VZVirtioGPUDeviceController,
                                    queue: DispatchQueue, sharedMemoryBytes: UInt64) throws -> VZVirtualMachine {
        let boot = VZEFIBootLoader()
        boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: directory.appendingPathComponent("nvram"))
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.bootLoader = boot
        config.cpuCount = 2
        config.memorySize = 512 * 1024 * 1024
        let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        config.customVirtioDevices = [controller.makeConfiguration(
            options: VZVirtioGPUConfigOptions(sharedMemoryBytes: sharedMemoryBytes)
        )]
        try config.validate()
        return queue.sync { VZVirtualMachine(configuration: config, queue: queue) }
    }

    private static func start(_ machine: VZVirtualMachine, queue: DispatchQueue) throws {
        let wait = DispatchSemaphore(value: 0)
        var failure: NSError?
        queue.sync {
            machine.start { result in
                if case .failure(let error) = result { failure = error as NSError }
                wait.signal()
            }
        }
        guard wait.wait(timeout: .now() + 15) == .success else {
            throw NSError(domain: "EFIGuestStart", code: 1)
        }
        if let failure { throw failure }
    }

    private static func stop(_ machine: VZVirtualMachine, queue: DispatchQueue) -> Bool {
        let wait = DispatchSemaphore(value: 0)
        var succeeded = false
        queue.sync { machine.stop { error in succeeded = error == nil; wait.signal() } }
        return wait.wait(timeout: .now() + 15) == .success && succeeded
    }

    private static func map(_ region: VZVirtioSharedMemoryRegion, renderer: InProcessZeroCopyRenderer,
                            queue: DispatchQueue, removing: Bool) throws {
        let wait = DispatchSemaphore(value: 0)
        var failure: NSError?
        let completion: (Error?) -> Void = { error in failure = error as NSError?; wait.signal() }
        let bytes = UInt64(renderer.ring.buffer.length)
        queue.sync {
            if removing { region.unmapMemory(atOffset: 0, size: bytes, completionHandler: completion) } else {
                region.mapMemory(renderer.ring.buffer.contents(), atOffset: 0, size: bytes,
                                 completionHandler: completion)
            }
        }
        guard wait.wait(timeout: .now() + 10) == .success else {
            throw NSError(domain: "EFIGuestMapping", code: 1)
        }
        if let failure { throw failure }
    }
}
