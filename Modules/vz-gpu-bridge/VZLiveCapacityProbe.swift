// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Darwin
import Foundation
import Virtualization

public struct VZLiveCapacityReport: Encodable {
    public let owner = "@DNPMBHC"
    public let scope = "isolated_EFI_live_aperture_and_lazy_mapping_not_physical_commit_limit"
    public let requestedBytes: UInt64
    public var configurationValidated = false
    public var deviceCreated = false
    public var guestStarted = false
    public var guestStopped = false
    public var mappedAndUnmapped = false
    public var runningBeforeMap = false
    public var machineStateBeforeStop: String?
    public var guestStoppedNaturally = false
    public var stopRequested = false
    public var stopSkippedBecauseUnavailable = false
    public var machineStateAfterStop: String?
    public var guestErrorDomain: String?
    public var guestErrorCode: Int?
    public var stopErrorDomain: String?
    public var stopErrorCode: Int?
    public var mapping: VZMappingCase?
    public var errorDomain: String?
    public var errorCode: Int?
    public let physicalPagesFullyTouched = false
}

private final class CapacityLifecycleObserver: NSObject, VZVirtualMachineDelegate {
    var failure: NSError?
    var stoppedNaturally = false

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stoppedNaturally = true
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        failure = error as NSError
    }
}

@available(macOS 27.0, *)
extension VZRuntimeProbe {
    public static func runCapacityCase(bytes: UInt64) -> VZLiveCapacityReport {
        var result = VZLiveCapacityReport(requestedBytes: bytes)
        guard bytes >= UInt64(getpagesize()), bytes <= (1 << 46) else {
            result.errorDomain = "LiveCapacityInputBounds"
            result.errorCode = 1
            return result
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = VZVirtioGPUDeviceController()
        let queue = DispatchQueue(label: "demo-app.capacity-machine")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let machine = try makeMachine(directory: directory, controller: controller,
                                          queue: queue, regionBytes: bytes)
            result.configurationValidated = true
            let observer = CapacityLifecycleObserver()
            queue.sync { machine.delegate = observer }
            guard let region = controller.deviceQueue.sync(execute: {
                controller.activeDevice?.sharedMemoryRegions.first
            }) else {
                result.errorDomain = "LiveCapacityDevice"
                result.errorCode = 1
                return result
            }
            result.deviceCreated = true
            if let error = startMachine(machine, queue: queue) {
                result.errorDomain = error.domain
                result.errorCode = error.code
                return result
            }
            result.guestStarted = true
            result.runningBeforeMap = queue.sync { machine.state == .running }
            let mapping = mapCase(region: region, queue: controller.deviceQueue,
                                  request: MappingRequest(name: "full_aperture_lazy_mapping", bytes: bytes))
            result.mapping = mapping
            result.mappedAndUnmapped = mapping.succeeded
            result.errorDomain = mapping.errorDomain
            result.errorCode = mapping.errorCode
            result = finishCapacity(machine, queue: queue, observer: observer, result: result)
        } catch {
            let error = error as NSError
            result.errorDomain = error.domain
            result.errorCode = error.code
        }
        return result
    }

    private static func finishCapacity(_ machine: VZVirtualMachine, queue: DispatchQueue,
                                       observer: CapacityLifecycleObserver,
                                       result initial: VZLiveCapacityReport) -> VZLiveCapacityReport {
        var result = initial
        let state = queue.sync { (machine.state, machine.canStop) }
        result.machineStateBeforeStop = String(describing: state.0)
        if state.0 == .stopped {
            result.guestStopped = true
        } else if !state.1 {
            result.stopSkippedBecauseUnavailable = true
        } else {
            result.stopRequested = true
            let wait = DispatchSemaphore(value: 0)
            var failure: NSError?
            queue.sync {
                machine.stop { error in
                    failure = error as NSError?
                    wait.signal()
                }
            }
            if wait.wait(timeout: .now() + 15) != .success {
                failure = NSError(domain: "LiveCapacityStopTimeout", code: 1)
            }
            result.stopErrorDomain = failure?.domain
            result.stopErrorCode = failure?.code
            result.guestStopped = queue.sync { machine.state == .stopped }
        }
        result.machineStateAfterStop = queue.sync { String(describing: machine.state) }
        let failure = queue.sync { observer.failure }
        result.guestStoppedNaturally = queue.sync { observer.stoppedNaturally }
        result.guestErrorDomain = failure?.domain
        result.guestErrorCode = failure?.code
        return result
    }

}
