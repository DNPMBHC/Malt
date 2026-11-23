// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Scheduling plan for optional host work submitted to a dedicated OperationQueue.
public struct HostResourcePlan: Equatable, Sendable {
    public let performancePolicy: RuntimePerformancePolicy
    public let qualityOfService: QualityOfService
    public let maxConcurrentOperations: Int
    public let pausesQueuedOperations: Bool

    public init(snapshot: RuntimeHostSnapshot) {
        performancePolicy = snapshot.performancePolicy
        switch snapshot.performancePolicy {
        case .maximumPerformance:
            qualityOfService = .utility
            maxConcurrentOperations = 2
            pausesQueuedOperations = false
        case .balanced:
            qualityOfService = .background
            maxConcurrentOperations = 1
            pausesQueuedOperations = false
        case .conserveEnergy:
            qualityOfService = .background
            maxConcurrentOperations = 1
            pausesQueuedOperations = true
        }
    }
}

/// Applies reversible limits only to optional work submitted to its dedicated queue.
public final class HostResourceController: @unchecked Sendable {
    private struct QueueSettings {
        let qualityOfService: QualityOfService
        let maxConcurrentOperationCount: Int
        let isSuspended: Bool
    }

    public let optionalWorkQueue: OperationQueue
    private let baseline: QueueSettings
    private let lock = NSLock()
    private var monitor: HostResourceStateMonitor?
    private var monitoringEnabled = false
    private var monitoringGeneration: UInt64 = 0

    public init(optionalWorkQueue: OperationQueue = OperationQueue()) {
        self.optionalWorkQueue = optionalWorkQueue
        baseline = QueueSettings(
            qualityOfService: optionalWorkQueue.qualityOfService,
            maxConcurrentOperationCount: optionalWorkQueue.maxConcurrentOperationCount,
            isSuspended: optionalWorkQueue.isSuspended
        )
    }

    public func startMonitoring(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        snapshotReader: @escaping HostResourceStateMonitor.SnapshotReader = { HostCapabilityProvider.current() }
    ) {
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        monitoringEnabled = true
        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        let stateMonitor = HostResourceStateMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            snapshotReader: snapshotReader,
            onUpdate: { [weak self] snapshot in
                self?.applyMonitored(snapshot: snapshot, generation: generation)
            }
        )
        monitor = stateMonitor
        apply(plan: HostResourcePlan(snapshot: stateMonitor.snapshot))
        lock.unlock()
    }

    public func apply(snapshot: RuntimeHostSnapshot) {
        lock.lock()
        apply(plan: HostResourcePlan(snapshot: snapshot))
        lock.unlock()
    }

    private func applyMonitored(snapshot: RuntimeHostSnapshot, generation: UInt64) {
        lock.lock()
        guard monitoringEnabled, generation == monitoringGeneration else {
            lock.unlock()
            return
        }
        apply(plan: HostResourcePlan(snapshot: snapshot))
        lock.unlock()
    }

    private func apply(plan: HostResourcePlan) {
        optionalWorkQueue.qualityOfService = plan.qualityOfService
        let baselineLimit = baseline.maxConcurrentOperationCount
        optionalWorkQueue.maxConcurrentOperationCount = baselineLimit > 0
            ? min(baselineLimit, plan.maxConcurrentOperations) : plan.maxConcurrentOperations
        optionalWorkQueue.isSuspended = baseline.isSuspended || plan.pausesQueuedOperations
    }

    public func stopMonitoringAndRestore() {
        lock.lock()
        let stateMonitor = monitor
        monitor = nil
        monitoringEnabled = false
        monitoringGeneration &+= 1
        stateMonitor?.stop()
        restoreBaselineLocked()
        lock.unlock()
    }

    public func restoreBaseline() {
        lock.lock()
        restoreBaselineLocked()
        lock.unlock()
    }

    private func restoreBaselineLocked() {
        optionalWorkQueue.qualityOfService = baseline.qualityOfService
        optionalWorkQueue.maxConcurrentOperationCount = baseline.maxConcurrentOperationCount
        optionalWorkQueue.isSuspended = baseline.isSuspended
    }

    deinit {
        stopMonitoringAndRestore()
    }
}

/// Graphics translation backend selected for a Wine launch.
public enum HostWineGraphicsBackend: String, Codable, CaseIterable, Sendable {
    case dxvk
    case d3dMetal
    case dxmt
}

/// A launch environment override that is explicitly tied to a documented downstream consumer.
public struct HostResourceConsumerBinding: Equatable, Codable, Sendable {
    public let name: String
    public let value: String
    public let consumer: String
    public let documentationReference: String

    public init(
        name: String,
        value: String,
        consumer: String,
        documentationReference: String
    ) {
        self.name = name
        self.value = value
        self.consumer = consumer
        self.documentationReference = documentationReference
    }
}

/// Reversible, consumer-backed execution guidance for Wine process launches.
public struct HostWineLaunchPolicy: Equatable, Sendable {
    public let isEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let graphicsBackend: HostWineGraphicsBackend
    public let processQualityOfService: QualityOfService
    public let environmentOverrides: [HostResourceConsumerBinding]
    public let unmanagedDomainNote: String?

    init(
        isEnabled: Bool, performancePolicy: RuntimePerformancePolicy,
        graphicsBackend: HostWineGraphicsBackend, processQualityOfService: QualityOfService,
        environmentOverrides: [HostResourceConsumerBinding], unmanagedDomainNote: String?
    ) {
        self.isEnabled = isEnabled
        self.performancePolicy = performancePolicy
        self.graphicsBackend = graphicsBackend
        self.processQualityOfService = processQualityOfService
        self.environmentOverrides = environmentOverrides
        self.unmanagedDomainNote = unmanagedDomainNote
    }

    public init(
        snapshot: RuntimeHostSnapshot,
        graphicsBackend: HostWineGraphicsBackend,
        enabled: Bool = true
    ) {
        self.isEnabled = enabled
        self.performancePolicy = snapshot.performancePolicy
        self.graphicsBackend = graphicsBackend
        guard enabled else {
            self.processQualityOfService = .userInitiated
            self.environmentOverrides = []
            self.unmanagedDomainNote = "Policy disabled by fallback switch; baseline launch settings retained."
            return
        }

        switch snapshot.performancePolicy {
        case .maximumPerformance:
            self.processQualityOfService = .userInitiated
        case .balanced, .conserveEnergy:
            self.processQualityOfService = .utility
        }

        switch graphicsBackend {
        case .dxvk:
            self.environmentOverrides = Self.dxvkBindings(for: snapshot.performancePolicy)
            self.unmanagedDomainNote = nil
        case .dxmt:
            self.environmentOverrides = Self.dxmtBindings(for: snapshot.performancePolicy)
            self.unmanagedDomainNote = nil
        case .d3dMetal:
            self.environmentOverrides = []
            self.unmanagedDomainNote = "D3DMetal exposes no public frame-cap or thermal-throttle environment " +
                "variables; host presentation pacing or OS thermal management handles throttling."
        }
    }

    public var environmentDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: environmentOverrides.map { ($0.name, $0.value) })
    }

    /// Merges documented overrides without clobbering keys explicitly supplied by the user or bottle config.
    public func applyingNonDestructively(to existing: [String: String]) -> [String: String] {
        guard isEnabled, !environmentOverrides.isEmpty else { return existing }
        var merged = existing
        for binding in environmentOverrides where merged[binding.name] == nil {
            merged[binding.name] = binding.value
        }
        return merged
    }

    private static func dxvkBindings(for policy: RuntimePerformancePolicy) -> [HostResourceConsumerBinding] {
        let consumer = "DXVK runtime (d3d11.dll / dxgi.dll)"
        let frameRateDoc = "DXVK README / dxvk.conf: DXVK_FRAME_RATE caps swapchain presentation FPS."
        let compilerDoc = "DXVK README / dxvk.conf: DXVK_NUM_COMPILER_THREADS bounds shader compiler worker threads."
        switch policy {
        case .maximumPerformance:
            return []
        case .balanced:
            return [
                HostResourceConsumerBinding(
                    name: "DXVK_FRAME_RATE",
                    value: "60",
                    consumer: consumer,
                    documentationReference: frameRateDoc
                ),
                HostResourceConsumerBinding(
                    name: "DXVK_NUM_COMPILER_THREADS",
                    value: "2",
                    consumer: consumer,
                    documentationReference: compilerDoc
                )
            ]
        case .conserveEnergy:
            return [
                HostResourceConsumerBinding(
                    name: "DXVK_FRAME_RATE",
                    value: "30",
                    consumer: consumer,
                    documentationReference: frameRateDoc
                ),
                HostResourceConsumerBinding(
                    name: "DXVK_NUM_COMPILER_THREADS",
                    value: "1",
                    consumer: consumer,
                    documentationReference: compilerDoc
                )
            ]
        }
    }

    private static func dxmtBindings(for policy: RuntimePerformancePolicy) -> [HostResourceConsumerBinding] {
        let consumer = "DXMT runtime (d3d11.dll / dxgi.dll / winemetal.so)"
        let configDoc = "DXMT configuration (DXMT_CONFIG): d3d11.preferredMaxFrameRate caps presentation rate."
        let metalfxDoc = "DXMT swapchain env (DXMT_METALFX_SPATIAL_SWAPCHAIN): disables MetalFX under pressure."
        switch policy {
        case .maximumPerformance:
            return []
        case .balanced:
            return [
                HostResourceConsumerBinding(
                    name: "DXMT_CONFIG",
                    value: "d3d11.preferredMaxFrameRate=60",
                    consumer: consumer,
                    documentationReference: configDoc
                ),
                HostResourceConsumerBinding(
                    name: "DXMT_METALFX_SPATIAL_SWAPCHAIN",
                    value: "0",
                    consumer: consumer,
                    documentationReference: metalfxDoc
                )
            ]
        case .conserveEnergy:
            return [
                HostResourceConsumerBinding(
                    name: "DXMT_CONFIG",
                    value: "d3d11.preferredMaxFrameRate=30",
                    consumer: consumer,
                    documentationReference: configDoc
                ),
                HostResourceConsumerBinding(
                    name: "DXMT_METALFX_SPATIAL_SWAPCHAIN",
                    value: "0",
                    consumer: consumer,
                    documentationReference: metalfxDoc
                )
            ]
        }
    }
}

/// Reversible presentation policy consumed directly by graphics-lab/metal_host.swift.
public struct HostMetalHostPolicy: Equatable, Codable, Sendable {
    public let isEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let targetFrameRateCap: Int?
    public let allowsMetalFXSpatial: Bool
    public let receiverQueueQoS: String

    public init(
        snapshot: RuntimeHostSnapshot,
        preferMetalFXSpatial: Bool = false,
        enabled: Bool = true
    ) {
        self.isEnabled = enabled
        self.performancePolicy = snapshot.performancePolicy
        guard enabled else {
            self.targetFrameRateCap = nil
            self.allowsMetalFXSpatial = false
            self.receiverQueueQoS = "userInitiated"
            return
        }
        switch snapshot.performancePolicy {
        case .maximumPerformance:
            self.targetFrameRateCap = nil
            self.allowsMetalFXSpatial = preferMetalFXSpatial && snapshot.metalFXSpatialScalingAvailable
            self.receiverQueueQoS = "userInitiated"
        case .balanced:
            self.targetFrameRateCap = 60
            self.allowsMetalFXSpatial = false
            self.receiverQueueQoS = "utility"
        case .conserveEnergy:
            self.targetFrameRateCap = 30
            self.allowsMetalFXSpatial = false
            self.receiverQueueQoS = "background"
        }
    }

    public var cliArguments: [String] {
        guard isEnabled else {
            return ["--resource-policy", "off", "--metalfx", "off"]
        }
        let policyArg: String
        switch performancePolicy {
        case .maximumPerformance: policyArg = "maximum-performance"
        case .balanced: policyArg = "balanced"
        case .conserveEnergy: policyArg = "conserve-energy"
        }
        return [
            "--resource-policy", policyArg,
            "--metalfx", allowsMetalFXSpatial ? "spatial" : "off"
        ]
    }
}

/// Non-invasive host-side guidance for Windows Guest launch and offload presentation.
public struct HostGuestLaunchPolicy: Equatable, Codable, Sendable {
    public let isEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let pausesHostOptionalBackgroundWork: Bool
    public let suggestedPresentationFrameRateCap: Int?
    public let note: String

    public init(snapshot: RuntimeHostSnapshot, enabled: Bool = true) {
        self.isEnabled = enabled
        self.performancePolicy = snapshot.performancePolicy
        guard enabled else {
            self.pausesHostOptionalBackgroundWork = false
            self.suggestedPresentationFrameRateCap = nil
            self.note = "Policy disabled by fallback switch; no host-side guest adjustments applied."
            return
        }
        let plan = HostResourcePlan(snapshot: snapshot)
        self.pausesHostOptionalBackgroundWork = plan.pausesQueuedOperations
        switch snapshot.performancePolicy {
        case .maximumPerformance:
            self.suggestedPresentationFrameRateCap = nil
        case .balanced:
            self.suggestedPresentationFrameRateCap = 60
        case .conserveEnergy:
            self.suggestedPresentationFrameRateCap = 30
        }
        self.note = "Applies only to host optional work and host offload presentation; " +
            "does not alter guest protection boundaries or VM identity."
    }
}
