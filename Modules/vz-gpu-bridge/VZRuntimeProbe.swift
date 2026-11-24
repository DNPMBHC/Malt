// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Darwin
import Foundation
import Virtualization

public struct VZMappingCase: Encodable {
    public let name: String
    public let bytes: UInt64
    public let succeeded: Bool
    public let errorDomain: String?
    public let errorCode: Int?
}

public struct VZRuntimeReport: Encodable {
    public let owner: String
    public let configurationValidated: Bool
    public let deviceCreated: Bool
    public let driverNegotiated: Bool
    public let guestStarted: Bool
    public let guestStopped: Bool
    public let allocationScope = "virtual_address_mapping_not_fully_committed_RAM"
    public let regionApertureBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public let guestScope = "isolated_diskless_EFI_fixture_not_Windows"
    public let regionCount: Int
    public let pageSize: Int
    public let mappings: [VZMappingCase]
    public let error: String?
}

struct MappingRequest {
    let name: String
    let bytes: UInt64
    var pointerOffset: UInt64 = 0
    var offset: UInt64 = 0
}

@available(macOS 27.0, *)
public enum VZRuntimeProbe {
    public static func run(caseIndex: Int? = nil) -> VZRuntimeReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var mappings: [VZMappingCase] = []
        let controller = VZVirtioGPUDeviceController()
        let vmQueue = DispatchQueue(label: "demo-app.virtual-machine")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let machine = try makeMachine(directory: directory, controller: controller, queue: vmQueue)
            let device = controller.deviceQueue.sync { controller.activeDevice }
            guard let region = device?.sharedMemoryRegions.first else {
                return report(created: false, mappings: [], error: "Device creation callback unavailable")
            }
            if let failure = startMachine(machine, queue: vmQueue) {
                let message = failure.localizedDescription.replacingOccurrences(of: directory.path, with: "<fixture>")
                    .replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
                return report(created: true, mappings: [], error: "\(failure.domain):\(failure.code):\(message)")
            }
            let cases = mappingRequests(regionSize: region.size)
            let selected = caseIndex.map { [$0] } ?? [0, 5, 6, 7, 8, 9, 10]
            for index in selected where cases.indices.contains(index) {
                mappings.append(mapCase(region: region, queue: controller.deviceQueue, request: cases[index]))
            }
            if caseIndex == nil { mappings.append(mapMetalRing(region: region, queue: controller.deviceQueue)) }
            let negotiated = controller.deviceQueue.sync { controller.driverAccepted }
            let stopped = stopMachine(machine, queue: vmQueue)
            return report(created: true, lifecycle: (true, stopped), negotiated: negotiated,
                          mappings: mappings, error: stopped ? nil : "Native EFI fixture stop failed")
        } catch {
            let native = error as NSError
            return report(created: false, mappings: mappings,
                          error: "\(native.domain):\(native.code)")
        }
    }

    static func makeMachine(
        directory: URL,
        controller: VZVirtioGPUDeviceController,
        queue: DispatchQueue,
        regionBytes: UInt64 = 16 * 1024 * 1024 * 1024
    ) throws -> VZVirtualMachine {
        let store = try VZEFIVariableStore(creatingVariableStoreAt: directory.appendingPathComponent("nvram"))
        let boot = VZEFIBootLoader()
        boot.variableStore = store
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.bootLoader = boot
        config.cpuCount = 2
        config.memorySize = 512 * 1024 * 1024
        config.customVirtioDevices = [controller.makeConfiguration(
            options: VZVirtioGPUConfigOptions(sharedMemoryBytes: regionBytes)
        )]
        try config.validate()
        return queue.sync { VZVirtualMachine(configuration: config, queue: queue) }
    }

    static func startMachine(_ machine: VZVirtualMachine, queue: DispatchQueue) -> NSError? {
        let wait = DispatchSemaphore(value: 0)
        var failure: NSError?
        queue.sync {
            machine.start { result in
                if case .failure(let error) = result { failure = error as NSError }
                wait.signal()
            }
        }
        guard wait.wait(timeout: .now() + 15) == .success else {
            return NSError(domain: "NativeStartTimeout", code: 1)
        }
        return failure
    }

    private static func stopMachine(_ machine: VZVirtualMachine, queue: DispatchQueue) -> Bool {
        let wait = DispatchSemaphore(value: 0)
        var succeeded = false
        queue.sync {
            machine.stop { error in
                succeeded = error == nil
                wait.signal()
            }
        }
        return wait.wait(timeout: .now() + 15) == .success && succeeded
    }

    private static func mappingRequests(regionSize: UInt64) -> [MappingRequest] {
        let page = UInt64(getpagesize())
        return [
            MappingRequest(name: "aligned_page", bytes: page),
            MappingRequest(name: "unaligned_pointer", bytes: page, pointerOffset: 1),
            MappingRequest(name: "unaligned_offset", bytes: page, offset: 1),
            MappingRequest(name: "unaligned_length", bytes: page - 1),
            MappingRequest(name: "outside_region", bytes: page, offset: regionSize),
            MappingRequest(name: "aligned_256MiB", bytes: 256 * 1024 * 1024),
            MappingRequest(name: "aligned_1GiB", bytes: 1024 * 1024 * 1024),
            MappingRequest(name: "aligned_2GiB", bytes: 2 * 1024 * 1024 * 1024),
            MappingRequest(name: "aligned_4GiB", bytes: 4 * 1024 * 1024 * 1024),
            MappingRequest(name: "aligned_8GiB", bytes: 8 * 1024 * 1024 * 1024),
            MappingRequest(name: "aligned_16GiB", bytes: 16 * 1024 * 1024 * 1024)
        ]
    }

    private static func mapMetalRing(region: VZVirtioSharedMemoryRegion, queue: DispatchQueue) -> VZMappingCase {
        let name = "VZ_and_Metal4_same_command_ring"
        do {
            let renderer = try InProcessZeroCopyRenderer(width: 1280, height: 720, maxDraws: 2048)
            let buffer = renderer.ring.buffer
            let wait = DispatchSemaphore(value: 0)
            var failure: NSError?
            queue.sync {
                region.mapMemory(buffer.contents(), atOffset: 0, size: UInt64(buffer.length)) { error in
                    failure = error as NSError?
                    wait.signal()
                }
            }
            guard wait.wait(timeout: .now() + 10) == .success, failure == nil else {
                return VZMappingCase(name: name, bytes: UInt64(buffer.length), succeeded: false,
                                     errorDomain: failure?.domain ?? "Timeout", errorCode: failure?.code ?? 1)
            }
            try renderer.renderFrame(drawCalls: 2048, frameIndex: 0, readbackToBuffer: nil)
            queue.sync {
                region.unmapMemory(atOffset: 0, size: UInt64(buffer.length)) { error in
                    failure = error as NSError?
                    wait.signal()
                }
            }
            let completed = wait.wait(timeout: .now() + 10) == .success
            return VZMappingCase(name: name, bytes: UInt64(buffer.length),
                succeeded: completed && failure == nil && renderer.ring.aliasesMetalMemory,
                errorDomain: failure?.domain, errorCode: failure?.code)
        } catch {
            let native = error as NSError
            return VZMappingCase(name: name, bytes: 0, succeeded: false,
                                 errorDomain: native.domain, errorCode: native.code)
        }
    }

    static func mapCase(
        region: VZVirtioSharedMemoryRegion,
        queue: DispatchQueue,
        request: MappingRequest
    ) -> VZMappingCase {
        let allocationBytes = Int(request.bytes + UInt64(getpagesize()))
        let pointer = mmap(nil, allocationBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let pointer, pointer != MAP_FAILED else {
            return VZMappingCase(name: request.name, bytes: request.bytes, succeeded: false,
                                 errorDomain: "POSIX", errorCode: Int(errno))
        }
        defer { munmap(pointer, allocationBytes) }
        let wait = DispatchSemaphore(value: 0)
        var failure: NSError?
        queue.sync {
            region.mapMemory(pointer.advanced(by: Int(request.pointerOffset)),
                             atOffset: request.offset, size: request.bytes) { error in
                failure = error as NSError?
                wait.signal()
            }
        }
        guard wait.wait(timeout: .now() + 10) == .success else {
            return VZMappingCase(name: request.name, bytes: request.bytes, succeeded: false,
                                 errorDomain: "ProbeTimeout", errorCode: 1)
        }
        if failure == nil {
            queue.sync {
                region.unmapMemory(atOffset: request.offset, size: request.bytes) { error in
                    failure = error as NSError?
                    wait.signal()
                }
            }
            guard wait.wait(timeout: .now() + 10) == .success else {
                return VZMappingCase(name: request.name, bytes: request.bytes, succeeded: false,
                                     errorDomain: "UnmapTimeout", errorCode: 1)
            }
        }
        return VZMappingCase(name: request.name, bytes: request.bytes, succeeded: failure == nil,
                             errorDomain: failure?.domain, errorCode: failure?.code)
    }

    private static func report(created: Bool, lifecycle: (started: Bool, stopped: Bool) = (false, false),
                               negotiated: Bool = false, mappings: [VZMappingCase], error: String?) -> VZRuntimeReport {
        VZRuntimeReport(owner: "@DNPMBHC", configurationValidated: error == nil || created,
                        deviceCreated: created, driverNegotiated: negotiated,
                        guestStarted: lifecycle.started, guestStopped: lifecycle.stopped,
                        regionCount: created ? 1 : 0, pageSize: Int(getpagesize()), mappings: mappings, error: error)
    }
}
