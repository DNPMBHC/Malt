// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Reads thermal and power state on change. Multiple notifications in one main-loop turn coalesce.
public final class HostResourceStateMonitor: @unchecked Sendable {
    public typealias SnapshotReader = @Sendable () -> RuntimeHostSnapshot
    public typealias UpdateHandler = @Sendable (RuntimeHostSnapshot) -> Void

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let snapshotReader: SnapshotReader
    private let updateHandler: UpdateHandler
    private let lock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var workspaceObserverToken: NSObjectProtocol?
    private var storedSnapshot: RuntimeHostSnapshot
    private var refreshScheduled = false
    private var stopped = false

    public var snapshot: RuntimeHostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    public init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        snapshotReader: @escaping SnapshotReader = { HostCapabilityProvider.current() },
        onUpdate: @escaping UpdateHandler = { _ in }
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.snapshotReader = snapshotReader
        // Read thermalState before registering, as required by ProcessInfo's notification contract.
        self.storedSnapshot = snapshotReader()
        self.updateHandler = onUpdate
        self.observerTokens = [
            notificationCenter.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.scheduleRefresh() },
            notificationCenter.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.scheduleRefresh() }
        ]
        self.workspaceObserverToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.scheduleRefresh() }
        // Close the gap between the initial read and observer registration.
        scheduleRefresh()
    }

    public func refresh() {
        scheduleRefresh()
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let tokens = observerTokens
        observerTokens.removeAll()
        let workspaceToken = workspaceObserverToken
        workspaceObserverToken = nil
        lock.unlock()
        tokens.forEach(notificationCenter.removeObserver)
        if let workspaceToken { workspaceNotificationCenter.removeObserver(workspaceToken) }
    }

    private func scheduleRefresh() {
        lock.lock()
        guard !stopped, !refreshScheduled else {
            lock.unlock()
            return
        }
        refreshScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.publishIfChanged() }
    }

    private func publishIfChanged() {
        lock.lock()
        guard !stopped else {
            refreshScheduled = false
            lock.unlock()
            return
        }
        refreshScheduled = false
        lock.unlock()

        let next = snapshotReader()
        lock.lock()
        let changed = !stopped && next != storedSnapshot
        if changed { storedSnapshot = next }
        lock.unlock()
        if changed { updateHandler(next) }
    }

    deinit {
        stop()
    }
}
