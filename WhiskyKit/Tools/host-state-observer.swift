// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

private struct HostObservationConfiguration: Sendable {
    var duration: TimeInterval = 30
    var runLabel = "sample-001"
    var phase = "control"
    var executionDomain = "host"
    var gameModeObservation = "unknown"

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw HostObservationError.invalidArguments }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, (1...3600).contains(seconds) else {
                    throw HostObservationError.invalidArguments
                }
                duration = seconds
            case "--run-label":
                guard value.range(of: "^sample-[0-9]{3,6}$", options: .regularExpression) != nil else {
                    throw HostObservationError.invalidArguments
                }
                runLabel = value
            case "--phase":
                phase = try Self.option(value, allowed: ["control", "treatment", "recovery"])
            case "--execution-domain":
                executionDomain = try Self.option(value, allowed: ["host", "wine", "guest"])
            case "--game-mode-observation":
                gameModeObservation = try Self.option(value, allowed: ["unknown", "observed-on", "observed-off"])
            default: throw HostObservationError.invalidArguments
            }
            index += 2
        }
    }

    private static func option(_ value: String, allowed: [String]) throws -> String {
        guard allowed.contains(value) else { throw HostObservationError.invalidArguments }
        return value
    }
}

private enum HostObservationError: Error { case invalidArguments }

private final class HostStateEventWriter: @unchecked Sendable {
    private let configuration: HostObservationConfiguration
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var counts: [String: Int] = [
        "thermal_notification": 0, "power_notification": 0, "wake_notification": 0
    ]

    init(configuration: HostObservationConfiguration) {
        self.configuration = configuration
    }

    func write(event: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[event, default: 0] += 1
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        var row: [String: Any] = [
            "schema_version": 1,
            "recorded_at_utc": ISO8601DateFormatter().string(from: Date()),
            "run_label": configuration.runLabel,
            "phase": configuration.phase,
            "execution_domain": configuration.executionDomain,
            "run_start_game_mode_observation": configuration.gameModeObservation,
            "game_mode_observation_source": configuration.gameModeObservation == "unknown"
                ? "none" : "manual-system-ui",
            "game_mode_observation_scope": "start-of-run-only",
            "child_process_benefit": "unmeasured",
            "event": event,
            "elapsed_monotonic_ms": Int((processInfo.systemUptime - started) * 1000),
            "system_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "thermal_state": thermalName(processInfo.thermalState),
            "low_power_mode": processInfo.isLowPowerModeEnabled
        ]
        if event == "observation_complete" {
            row["event_counts"] = counts
            row["no_system_changes_requested"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("event_encoding_failed\n".utf8))
            return
        }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Only records natural notifications while running. It never changes power settings or requests sleep.
@main
private struct HostStateObserver {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let configuration = try? HostObservationConfiguration(arguments: arguments) else {
            let message = "invalid_arguments: use synthetic run labels and documented options\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
        let writer = HostStateEventWriter(configuration: configuration)
        // Read before subscribing to thermal notifications, as required by ProcessInfo.
        writer.write(event: "initial_snapshot")
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let thermal = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in writer.write(event: "thermal_notification") }
        let power = center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { _ in writer.write(event: "power_notification") }
        let wake = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in writer.write(event: "wake_notification") }
        writer.write(event: "observers_registered")
        RunLoop.main.run(until: Date().addingTimeInterval(configuration.duration))
        center.removeObserver(thermal)
        center.removeObserver(power)
        workspaceCenter.removeObserver(wake)
        writer.write(event: "observation_complete")
    }
}
