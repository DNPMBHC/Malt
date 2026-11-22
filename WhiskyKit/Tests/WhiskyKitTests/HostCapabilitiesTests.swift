// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Metal
import MetalFX
import XCTest
@testable import WhiskyKit

final class HostCapabilitiesTests: XCTestCase, @unchecked Sendable {
    func testExplicitEmptyMetalDeviceListRemainsUnavailable() {
        let snapshot = HostCapabilityProvider.snapshot(processInfo: .processInfo, metalDevices: [])
        XCTAssertNil(snapshot.metalDeviceName)
        XCTAssertFalse(snapshot.metalFXSpatialScalingAvailable)
        XCTAssertFalse(snapshot.metalFXTemporalScalingAvailable)
    }

    func testCurrentProviderPreservesStaticCapabilities() {
        let first = HostCapabilityProvider.current()
        let second = HostCapabilityProvider.current()
        XCTAssertEqual(first.operatingSystemVersion, second.operatingSystemVersion)
        XCTAssertEqual(first.architecture, second.architecture)
        XCTAssertEqual(first.metalDeviceName, second.metalDeviceName)
        XCTAssertEqual(first.metalFXSpatialScalingAvailable, second.metalFXSpatialScalingAvailable)
        XCTAssertEqual(first.metalFXTemporalScalingAvailable, second.metalFXTemporalScalingAvailable)
    }

    func testGameModeEligibilityRequiresAppleSiliconAndSonomaOrLater() {
        XCTAssertFalse(HostCapabilityProvider.gameModePlatformEligibility(
            version: .init(major: 13, minor: 0, patch: 0), isAppleSilicon: true
        ))
        XCTAssertTrue(HostCapabilityProvider.gameModePlatformEligibility(
            version: .init(major: 14, minor: 0, patch: 0), isAppleSilicon: true
        ))
        XCTAssertFalse(HostCapabilityProvider.gameModePlatformEligibility(
            version: .init(major: 27, minor: 0, patch: 0), isAppleSilicon: false
        ))
    }

    func testStaticMetalCapabilityCacheLoadsOncePerDeviceKey() {
        let cache = HostMetalCapabilityCache()
        let key = MetalDeviceCacheKey(registryID: 42, name: "Synthetic GPU", isLowPower: false)
        let expected = MetalDeviceCapabilities(name: "Synthetic GPU", spatialScaling: true, temporalScaling: false)
        let counts = LockedHostTestState(snapshot: Self.snapshot())

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let actual = cache.value(for: key) {
                counts.recordUpdate()
                return expected
            }
            XCTAssertEqual(actual, expected)
        }
        XCTAssertEqual(counts.updateCount, 1)
        let other = MetalDeviceCacheKey(registryID: 43, name: "Other synthetic GPU", isLowPower: true)
        _ = cache.value(for: other) {
            counts.recordUpdate()
            return MetalDeviceCapabilities(name: "Other synthetic GPU", spatialScaling: false, temporalScaling: false)
        }
        XCTAssertEqual(counts.updateCount, 2)
    }

    func testThermalPowerAndWakeNotificationsRefreshDynamicState() async {
        let processNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let state = LockedHostTestState(snapshot: Self.snapshot())
        let monitor = HostResourceStateMonitor(
            notificationCenter: processNotifications,
            workspaceNotificationCenter: workspaceNotifications,
            snapshotReader: { state.get() },
            onUpdate: { _ in state.recordUpdate() }
        )
        defer { monitor.stop() }

        state.set(Self.snapshot(thermal: .serious))
        processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(monitor.snapshot.thermalState, .serious)

        state.set(Self.snapshot(lowPower: true))
        processNotifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await drainMainQueue()
        XCTAssertTrue(monitor.snapshot.isLowPowerModeEnabled)

        state.set(Self.snapshot())
        workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertFalse(monitor.snapshot.isLowPowerModeEnabled)
        XCTAssertEqual(state.updateCount, 3)
    }

    func testNotificationBurstCoalescesAndUnchangedStateDoesNotPublish() async {
        let processNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let state = LockedHostTestState(snapshot: Self.snapshot())
        let monitor = HostResourceStateMonitor(
            notificationCenter: processNotifications,
            workspaceNotificationCenter: workspaceNotifications,
            snapshotReader: { state.get() },
            onUpdate: { _ in state.recordUpdate() }
        )
        defer { monitor.stop() }
        await drainMainQueue()
        let initialReads = state.readCount
        let initialUpdates = state.updateCount

        await MainActor.run {
            state.set(Self.snapshot(thermal: .serious, lowPower: true))
            for _ in 0..<100 {
                processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
                processNotifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
                workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            }
        }
        await drainMainQueue()
        XCTAssertEqual(state.readCount, initialReads + 1)
        XCTAssertEqual(state.updateCount, initialUpdates + 1)

        processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(state.updateCount, initialUpdates + 1)
    }

    func testStopDiscardsScheduledRefreshAndRemovesAllObservers() async {
        let processNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let state = LockedHostTestState(snapshot: Self.snapshot())
        let monitor = HostResourceStateMonitor(
            notificationCenter: processNotifications,
            workspaceNotificationCenter: workspaceNotifications,
            snapshotReader: { state.get() },
            onUpdate: { _ in state.recordUpdate() }
        )
        await MainActor.run {
            state.set(Self.snapshot(thermal: .critical, lowPower: true))
            processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            monitor.stop()
        }
        await drainMainQueue()
        let readsAfterStop = state.readCount
        processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        processNotifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(state.readCount, readsAfterStop)
        XCTAssertEqual(state.updateCount, 0)
        XCTAssertEqual(monitor.snapshot.thermalState, .nominal)
        XCTAssertFalse(monitor.snapshot.isLowPowerModeEnabled)
        monitor.stop()
    }

    // Keep the full pause/resume/restore sequence in one test to verify queued work survives every transition.
    // swiftlint:disable:next function_body_length
    func testOptionalQueueActuallyPausesAndResumesAcrossPowerAndThermalChanges() async {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        let controller = HostResourceController(optionalWorkQueue: queue)
        let processNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let state = LockedHostTestState(snapshot: Self.snapshot())
        controller.startMonitoring(
            notificationCenter: processNotifications,
            workspaceNotificationCenter: workspaceNotifications,
            snapshotReader: { state.get() }
        )
        defer { controller.stopMonitoringAndRestore() }

        let baselineWork = expectation(description: "nominal optional work executes")
        queue.addOperation { baselineWork.fulfill() }
        await fulfillment(of: [baselineWork], timeout: 2)

        state.set(Self.snapshot(lowPower: true))
        processNotifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await drainMainQueue()
        XCTAssertTrue(queue.isSuspended)
        let powerWork = expectation(description: "queued low-power work resumes")
        let powerOperation = BlockOperation { powerWork.fulfill() }
        queue.addOperation(powerOperation)
        await drainMainQueue()
        XCTAssertFalse(powerOperation.isExecuting)
        XCTAssertFalse(powerOperation.isFinished)

        state.set(Self.snapshot())
        processNotifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await drainMainQueue()
        await fulfillment(of: [powerWork], timeout: 2)
        XCTAssertFalse(queue.isSuspended)

        state.set(Self.snapshot(thermal: .critical))
        processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await drainMainQueue()
        XCTAssertTrue(queue.isSuspended)
        let thermalWork = expectation(description: "queued thermal work resumes")
        let thermalOperation = BlockOperation { thermalWork.fulfill() }
        queue.addOperation(thermalOperation)
        await drainMainQueue()
        XCTAssertFalse(thermalOperation.isFinished)

        state.set(Self.snapshot(thermal: .serious))
        processNotifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await drainMainQueue()
        await fulfillment(of: [thermalWork], timeout: 2)
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(queue.qualityOfService, .background)
        XCTAssertEqual(queue.maxConcurrentOperationCount, 1)

        controller.stopMonitoringAndRestore()
        XCTAssertEqual(queue.qualityOfService, .utility)
        XCTAssertEqual(queue.maxConcurrentOperationCount, 4)
        XCTAssertFalse(queue.isSuspended)
        state.set(Self.snapshot(lowPower: true))
        processNotifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await drainMainQueue()
        XCTAssertFalse(queue.isSuspended)
    }

    func testPolicyPreservesConsumerPauseAndConcurrencyLimit() async {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        let controller = HostResourceController(optionalWorkQueue: queue)
        controller.apply(snapshot: Self.snapshot())
        XCTAssertEqual(queue.maxConcurrentOperationCount, 1)
        XCTAssertTrue(queue.isSuspended)
        let resumed = expectation(description: "consumer resumes its own pause")
        let operation = BlockOperation { resumed.fulfill() }
        queue.addOperation(operation)
        controller.stopMonitoringAndRestore()
        XCTAssertTrue(queue.isSuspended)
        XCTAssertFalse(operation.isFinished)
        queue.isSuspended = false
        await fulfillment(of: [resumed], timeout: 2)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func snapshot(
        thermal: HostThermalState = .nominal,
        lowPower: Bool = false
    ) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 27, minor: 0, patch: 0),
            architecture: "arm64",
            isAppleSilicon: true,
            gameModePlatformAvailable: true,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            metalDeviceName: nil,
            metalFXSpatialScalingAvailable: false,
            metalFXTemporalScalingAvailable: false,
            gpuDeveloperToolsAvailable: false
        )
    }
}

private final class LockedHostTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RuntimeHostSnapshot
    private var reads = 0
    private var updates = 0

    init(snapshot: RuntimeHostSnapshot) { value = snapshot }

    func get() -> RuntimeHostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return value
    }

    func set(_ snapshot: RuntimeHostSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    func recordUpdate() {
        lock.lock()
        updates += 1
        lock.unlock()
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var updateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}
