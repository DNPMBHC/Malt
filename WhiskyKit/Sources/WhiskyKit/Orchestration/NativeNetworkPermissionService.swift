// SPDX-License-Identifier: GPL-3.0-or-later
// Native system service registration. Owner: @DNPMBHC

import Darwin
import Foundation
import ServiceManagement

public enum NativeNetworkRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum NativeNetworkPermissionState: Equatable, Sendable {
    case helperMissing
    case notRegistered
    case requiresApproval
    case starting
    case ready
    case signingRequired
    case operationFailed(Int)
}

public struct NativeNetworkPermissionSnapshot: Equatable, Sendable {
    public let state: NativeNetworkPermissionState
    public let registrationStatus: NativeNetworkRegistrationStatus
    public let helperPayloadReady: Bool
    public let socketReady: Bool

    public var statusSummary: String {
        switch state {
        case .helperMissing:
            return "当前安装包缺少原生网络组件，请安装完整版本；可继续配置共享网络。"
        case .notRegistered:
            return "原生网络尚未授权；可继续配置共享网络。"
        case .requiresApproval:
            return "请在系统设置的登录项与扩展中，由管理员允许此应用在后台运行。"
        case .starting:
            return "系统服务已获准运行，正在等待原生网络连接入口就绪；可继续配置共享网络。"
        case .ready:
            return "原生网络服务已获准运行且连接入口就绪；启用前仍需确认容器网络配置。"
        case .signingRequired:
            return "此安装包的签名无法注册系统服务；请安装有效签名的完整版本，正式跨机分发还需完成公证。"
        case .operationFailed(let code):
            if code == Int(ETIMEDOUT) {
                return "等待原生网络连接入口超时（错误码 \(code)）。请重试授权并检查系统后台服务；可继续配置共享网络。"
            }
            return "系统服务操作未完成（错误码 \(code)）；可继续配置共享网络。"
        }
    }
}

/// All effects are injected so tests never register a system daemon or show a permission prompt.
@MainActor
public struct NativeNetworkPermissionOperations {
    public var registrationStatus: () -> NativeNetworkRegistrationStatus
    public var register: () throws -> Void
    public var unregister: () async throws -> Void
    public var openSettings: () -> Void

    public init(
        registrationStatus: @escaping () -> NativeNetworkRegistrationStatus,
        register: @escaping () throws -> Void,
        unregister: @escaping () async throws -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.registrationStatus = registrationStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
    }

    public static var live: Self {
        Self(
            registrationStatus: {
                switch SMAppService.daemon(plistName: NativeNetworkPermissionService.plistName).status {
                case .notRegistered: return .notRegistered
                case .enabled: return .enabled
                case .requiresApproval: return .requiresApproval
                case .notFound: return .notFound
                @unknown default: return .notFound
                }
            },
            register: {
                try SMAppService.daemon(plistName: NativeNetworkPermissionService.plistName).register()
            },
            unregister: {
                try await SMAppService.daemon(plistName: NativeNetworkPermissionService.plistName).unregister()
            },
            openSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
}

/// Uses macOS ServiceManagement; never elevates the GUI or runs user-writable scripts as root.
/// Release distribution of a bundled LaunchDaemon requires a signed, notarized application.
@MainActor
public final class NativeNetworkPermissionService {
    public nonisolated static let daemonLabel = "com.malt.vmnet-bridge"
    public nonisolated static let plistName = "com.malt.vmnet-bridge.plist"
    public nonisolated static let helperRelativePath = "Contents/Library/HelperTools/malt-vmnet-bridge"
    public nonisolated static let socketPath = "/var/run/malt-vmnet-bridge.sock"

    private static var liveWaitStartedAt: [URL: TimeInterval] = [:]

    private let operations: NativeNetworkPermissionOperations
    private let payloadReady: () -> Bool
    private let socketReady: () -> Bool
    private let clock: () -> TimeInterval
    private let readinessTimeout: TimeInterval
    private let liveWaitKey: URL?
    private var localWaitStartedAt: TimeInterval?

    private var waitStartedAt: TimeInterval? {
        get {
            if let liveWaitKey { return Self.liveWaitStartedAt[liveWaitKey] }
            return localWaitStartedAt
        }
        set {
            if let liveWaitKey {
                Self.liveWaitStartedAt[liveWaitKey] = newValue
            } else {
                localWaitStartedAt = newValue
            }
        }
    }

    public init(
        appBundleURL: URL = Bundle.main.bundleURL,
        operations: NativeNetworkPermissionOperations? = nil,
        payloadReady: (() -> Bool)? = nil,
        socketReady: (() -> Bool)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        readinessTimeout: TimeInterval = 15
    ) {
        if let operations {
            self.operations = operations
            liveWaitKey = nil
        } else {
            self.operations = .live
            // Refresh callers may recreate the service; retain only the live waiting timestamp.
            liveWaitKey = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        }
        self.payloadReady = payloadReady ?? { Self.validatePayload(in: appBundleURL) }
        self.socketReady = socketReady ?? { Self.isSocketReady() }
        self.clock = clock
        self.readinessTimeout = readinessTimeout.isFinite ? max(0, readinessTimeout) : 15
    }

    /// Observes service state and socket metadata without connecting to the guest traffic socket.
    public func status() -> NativeNetworkPermissionSnapshot {
        snapshot()
    }

    private func snapshot(operationFailure: NativeNetworkPermissionState? = nil) -> NativeNetworkPermissionSnapshot {
        let registration = operations.registrationStatus()
        let payload = payloadReady()
        let socket = registration == .enabled && socketReady()
        let state: NativeNetworkPermissionState
        if !payload {
            waitStartedAt = nil
            state = .helperMissing
        } else {
            let observed = observedState(registration: registration, socket: socket)
            state = operationFailure ?? observed
        }
        return NativeNetworkPermissionSnapshot(
            state: state, registrationStatus: registration,
            helperPayloadReady: payload, socketReady: socket
        )
    }

    private func observedState(
        registration: NativeNetworkRegistrationStatus, socket: Bool
    ) -> NativeNetworkPermissionState {
        guard registration == .enabled else {
            waitStartedAt = nil
            switch registration {
            case .notRegistered: return .notRegistered
            case .requiresApproval: return .requiresApproval
            case .notFound: return .helperMissing
            case .enabled: return .starting
            }
        }
        if socket {
            waitStartedAt = nil
            return .ready
        }
        let now = clock()
        let started = waitStartedAt ?? now
        waitStartedAt = started
        return now - started >= readinessTimeout ? .operationFailed(Int(ETIMEDOUT)) : .starting
    }

    /// Call only after the user chooses to enable optional native networking.
    @discardableResult
    public func requestAuthorization(openSettings: Bool = true) -> NativeNetworkPermissionSnapshot {
        waitStartedAt = nil
        guard payloadReady() else { return status() }
        let current = operations.registrationStatus()
        if current == .enabled { return status() }
        var failure: NativeNetworkPermissionState?
        if current != .requiresApproval {
            do {
                try operations.register()
            } catch {
                let code = (error as NSError).code
                let observed = operations.registrationStatus()
                if observed != .requiresApproval && observed != .enabled {
                    failure = code == kSMErrorInvalidSignature ? .signingRequired : .operationFailed(code)
                }
            }
        }
        if openSettings && operations.registrationStatus() == .requiresApproval {
            operations.openSettings()
        }
        return snapshot(operationFailure: failure)
    }

    @discardableResult
    public func revokeAuthorization() async -> NativeNetworkPermissionSnapshot {
        waitStartedAt = nil
        guard operations.registrationStatus() != .notRegistered else { return status() }
        var failure: NativeNetworkPermissionState?
        do {
            try await operations.unregister()
        } catch {
            if operations.registrationStatus() != .notRegistered {
                failure = .operationFailed((error as NSError).code)
            }
        }
        return snapshot(operationFailure: failure)
    }

    public func openApprovalSettings() {
        operations.openSettings()
    }

    public nonisolated static func isSocketReady(path: String = socketPath, currentUID: uid_t = getuid()) -> Bool {
        guard currentUID >= 501 else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFSOCK
            && info.st_mode & 0o777 == 0o600
            && info.st_uid == currentUID
    }

    public nonisolated static func validatePayload(in appBundleURL: URL) -> Bool {
        let bundle = appBundleURL.resolvingSymlinksInPath()
        let helper = bundle.appending(path: helperRelativePath)
        let plist = bundle.appending(path: "Contents/Library/LaunchDaemons/\(plistName)")
        guard helper.resolvingSymlinksInPath() == helper.standardizedFileURL,
              plist.resolvingSymlinksInPath() == plist.standardizedFileURL else { return false }
        var info = stat()
        var plistInfo = stat()
        guard lstat(plist.path, &plistInfo) == 0,
              plistInfo.st_mode & S_IFMT == S_IFREG,
              plistInfo.st_mode & 0o022 == 0,
              lstat(helper.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0,
              FileManager.default.isExecutableFile(atPath: helper.path),
              let data = try? Data(contentsOf: plist),
              let properties = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return properties["Program"] == nil
            && properties["EnvironmentVariables"] == nil
            && properties["RootDirectory"] == nil
            && properties["Label"] as? String == daemonLabel
            && properties["BundleProgram"] as? String == helperRelativePath
            && properties["UserName"] as? String == "root"
            && properties["ProgramArguments"] as? [String] == [
                "malt-vmnet-bridge", "--socket", socketPath, "--mode", "0600"
            ]
    }
}
