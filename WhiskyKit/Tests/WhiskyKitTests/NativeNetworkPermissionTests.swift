// SPDX-License-Identifier: GPL-3.0-or-later
// Permission state tests. Owner: @DNPMBHC

import Darwin
import Foundation
import ServiceManagement
import XCTest
@testable import WhiskyKit

final class NativeNetworkPermissionTests: XCTestCase {
    func testPermissionSummaryDoesNotClaimConfiguredNetworkMode() {
        let states: [NativeNetworkPermissionState] = [
            .helperMissing, .notRegistered, .requiresApproval, .starting, .ready,
            .signingRequired, .operationFailed(77)
        ]
        for state in states {
            let snapshot = NativeNetworkPermissionSnapshot(
                state: state, registrationStatus: .notRegistered,
                helperPayloadReady: true, socketReady: false
            )
            XCTAssertFalse(snapshot.statusSummary.contains("当前使用"))
            if state == .ready {
                XCTAssertTrue(snapshot.statusSummary.contains("容器网络配置"))
            }
        }
    }

    @MainActor
    func testMissingPayloadDoesNotRegisterOrOpenSettings() {
        var effects = 0
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { .notRegistered }, register: { effects += 1 },
            unregister: {}, openSettings: { effects += 1 }
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { false }, socketReady: { false }
        )
        XCTAssertEqual(service.requestAuthorization().state, .helperMissing)
        XCTAssertEqual(effects, 0)
    }

    @MainActor
    func testRegisterRequiresExplicitApprovalAndOpensCorrectSettings() {
        var registration = NativeNetworkRegistrationStatus.notRegistered
        var requests = 0
        var settings = 0
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { registration },
            register: { requests += 1; registration = .requiresApproval },
            unregister: {}, openSettings: { settings += 1 }
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { true }
        )
        XCTAssertEqual(service.status().state, .notRegistered)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(settings, 0)
        XCTAssertEqual(service.requestAuthorization().state, .requiresApproval)
        XCTAssertFalse(service.status().socketReady)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(service.requestAuthorization().state, .requiresApproval)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settings, 2)
    }

    @MainActor
    func testEnabledIsIdempotentAndWaitsForSocket() {
        var socket = false
        var requests = 0
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { .enabled }, register: { requests += 1 },
            unregister: {}, openSettings: { requests += 1 }
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { socket }
        )
        XCTAssertEqual(service.requestAuthorization().state, .starting)
        XCTAssertEqual(requests, 0)
        socket = true
        XCTAssertEqual(service.status().state, .ready)
    }

    @MainActor
    func testSigningFailureIsActionableAndKeepsFallback() {
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { .notRegistered },
            register: { throw NSError(domain: "ServiceManagement", code: Int(kSMErrorInvalidSignature)) },
            unregister: {}, openSettings: { XCTFail("no approval exists") }
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { true }
        )
        let result = service.requestAuthorization()
        XCTAssertEqual(result.state, .signingRequired)
        XCTAssertFalse(result.socketReady)
        XCTAssertTrue(result.statusSummary.contains("签名"))
        XCTAssertEqual(service.status().state, .notRegistered)
    }

    @MainActor
    func testDeniedApprovalDoesNotBecomeEnabled() {
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { .requiresApproval }, register: { XCTFail("already registered") },
            unregister: {}, openSettings: {}
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { true }
        )
        XCTAssertEqual(service.requestAuthorization(openSettings: false).state, .requiresApproval)
        XCTAssertFalse(service.status().socketReady)
    }

    @MainActor
    func testRevokeIsIdempotent() async {
        var registration = NativeNetworkRegistrationStatus.enabled
        var revocations = 0
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { registration }, register: {},
            unregister: { revocations += 1; registration = .notRegistered }, openSettings: {}
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { true }
        )
        let first = await service.revokeAuthorization()
        XCTAssertEqual(first.state, .notRegistered)
        let second = await service.revokeAuthorization()
        XCTAssertEqual(second.state, .notRegistered)
        XCTAssertEqual(revocations, 1)
    }

    @MainActor
    func testRevokeFailureRemainsVisibleAndCanBeRetried() async {
        for initial in [NativeNetworkRegistrationStatus.enabled, .requiresApproval] {
            var registration = initial
            var shouldFail = true
            let operations = NativeNetworkPermissionOperations(
                registrationStatus: { registration }, register: {},
                unregister: {
                    if shouldFail { throw NSError(domain: "ServiceManagement", code: 77) }
                    registration = .notRegistered
                }, openSettings: {}
            )
            let service = NativeNetworkPermissionService(
                operations: operations, payloadReady: { true }, socketReady: { true }
            )
            let failed = await service.revokeAuthorization()
            XCTAssertEqual(failed.state, .operationFailed(77))
            XCTAssertEqual(failed.registrationStatus, initial)
            XCTAssertTrue(failed.statusSummary.contains("77"))
            XCTAssertEqual(service.status().state, initial == .enabled ? .ready : .requiresApproval)
            shouldFail = false
            let retried = await service.revokeAuthorization()
            XCTAssertEqual(retried.state, .notRegistered)
        }
    }

    @MainActor
    func testRegistrationErrorDoesNotLeakLocalizedPaths() {
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { .notRegistered },
            register: { throw NSError(domain: "ServiceManagement", code: 77,
                userInfo: [NSLocalizedDescriptionKey: "/private/demo-app/secret"]) },
            unregister: {}, openSettings: {}
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { false }
        )
        let result = service.requestAuthorization()
        XCTAssertEqual(result.state, .operationFailed(77))
        XCTAssertFalse(result.statusSummary.contains("/private"))
    }

    func testSocketProbeRejectsRegularFileAndSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "socket")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertFalse(NativeNetworkPermissionService.isSocketReady(path: file.path))
        let alias = dir.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertFalse(NativeNetworkPermissionService.isSocketReady(path: alias.path))
    }

    func testSocketProbeChecksTypeModeAndOwner() throws {
        let path = "/tmp/network-\(UUID().uuidString.prefix(12)).sock"
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketDescriptor, 0)
        defer { close(socketDescriptor); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            encoded.withUnsafeBytes { source in target.copyMemory(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(socketDescriptor, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(chmod(path, 0o600), 0)
        XCTAssertEqual(
            NativeNetworkPermissionService.isSocketReady(path: path), getuid() >= 501
        )
        XCTAssertFalse(NativeNetworkPermissionService.isSocketReady(path: path, currentUID: getuid() + 1))
        XCTAssertEqual(chmod(path, 0o666), 0)
        XCTAssertFalse(NativeNetworkPermissionService.isSocketReady(path: path))
    }

    func testPayloadValidationRequiresFixedHelperAndSafePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "network-\(UUID().uuidString)")
        let helper = dir.appending(path: NativeNetworkPermissionService.helperRelativePath)
        let plist = dir.appending(path: "Contents/Library/LaunchDaemons/\(NativeNetworkPermissionService.plistName)")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        var properties: [String: Any] = [
            "Label": NativeNetworkPermissionService.daemonLabel,
            "BundleProgram": NativeNetworkPermissionService.helperRelativePath,
            "UserName": "root",
            "ProgramArguments": ["malt-vmnet-bridge", "--socket",
                                 NativeNetworkPermissionService.socketPath, "--mode", "0600"]
        ]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        XCTAssertTrue(NativeNetworkPermissionService.validatePayload(in: dir))
        properties["BundleProgram"] = "/tmp/untrusted"
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        XCTAssertFalse(NativeNetworkPermissionService.validatePayload(in: dir))
        properties["BundleProgram"] = NativeNetworkPermissionService.helperRelativePath
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: helper.path)
        XCTAssertFalse(NativeNetworkPermissionService.validatePayload(in: dir))
    }
}

extension NativeNetworkPermissionTests {
    @MainActor
    func testEnabledSocketWaitHasStableTimeout() {
        let fixture = PermissionWaitFixture()
        fixture.now = 50
        let service = fixture.service(timeout: 5)
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 54.99
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 55
        let timedOut = service.status()
        XCTAssertEqual(timedOut.state, .operationFailed(Int(ETIMEDOUT)))
        XCTAssertEqual(timedOut.registrationStatus, .enabled)
        XCTAssertFalse(timedOut.socketReady)
        XCTAssertTrue(timedOut.statusSummary.contains("超时"))
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
    }

    @MainActor
    func testTimedOutServiceRecoversWhenSocketAppears() {
        let fixture = PermissionWaitFixture()
        let service = fixture.service(timeout: 1)
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 1
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
        fixture.socket = true
        XCTAssertEqual(service.status().state, .ready)
        fixture.now = 3
        fixture.socket = false
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 4
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
    }

    @MainActor
    func testTimedOutWaitResetsWhenRegistrationChanges() {
        for next in [NativeNetworkRegistrationStatus.notRegistered, .requiresApproval, .notFound] {
            let fixture = PermissionWaitFixture()
            let service = fixture.service(timeout: 1)
            XCTAssertEqual(service.status().state, .starting)
            fixture.now = 1
            XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
            fixture.registration = next
            let expected: NativeNetworkPermissionState = next == .notRegistered
                ? .notRegistered : (next == .requiresApproval ? .requiresApproval : .helperMissing)
            XCTAssertEqual(service.status().state, expected)
            fixture.now = 100
            fixture.registration = .enabled
            XCTAssertEqual(service.status().state, .starting)
            fixture.now = 101
            XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
        }
    }

    @MainActor
    func testAuthorizationRetryResetsTimeoutWithoutRegisteringEnabledService() {
        let fixture = PermissionWaitFixture()
        let service = fixture.service()
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 15
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
        fixture.now = 100
        XCTAssertEqual(service.requestAuthorization().state, .starting)
        fixture.now = 114.99
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 115
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
        XCTAssertEqual(fixture.effects, 0)
    }

    @MainActor
    func testMissingPayloadResetsReadinessDeadline() {
        let fixture = PermissionWaitFixture()
        let service = fixture.service(timeout: 1)
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 1
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
        fixture.payload = false
        XCTAssertEqual(service.status().state, .helperMissing)
        fixture.now = 100
        fixture.payload = true
        XCTAssertEqual(service.status().state, .starting)
    }

    @MainActor
    func testInjectedServicesKeepIndependentReadinessWindows() {
        let fixture = PermissionWaitFixture()
        let first = fixture.service(timeout: 1)
        XCTAssertEqual(first.status().state, .starting)
        fixture.now = 100
        let second = fixture.service(timeout: 1)
        XCTAssertEqual(first.status().state, .operationFailed(Int(ETIMEDOUT)))
        XCTAssertEqual(second.status().state, .starting)
    }

    @MainActor
    func testRevokeAndNewEnableStartFreshReadinessWindow() async {
        let fixture = PermissionWaitFixture()
        let service = fixture.service(timeout: 1)
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 1
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
        let revoked = await service.revokeAuthorization()
        XCTAssertEqual(revoked.state, .notRegistered)
        fixture.now = 100
        XCTAssertEqual(service.requestAuthorization().state, .starting)
        fixture.now = 100.99
        XCTAssertEqual(service.status().state, .starting)
        fixture.now = 101
        XCTAssertEqual(service.status().state, .operationFailed(Int(ETIMEDOUT)))
    }

    @MainActor
    func testObservedSystemStateWinsAfterOperationThrows() async {
        var registration = NativeNetworkRegistrationStatus.notRegistered
        let operations = NativeNetworkPermissionOperations(
            registrationStatus: { registration },
            register: {
                registration = .enabled
                throw NSError(domain: "ServiceManagement", code: 77)
            },
            unregister: {
                registration = .notRegistered
                throw NSError(domain: "ServiceManagement", code: 77)
            }, openSettings: {}
        )
        let service = NativeNetworkPermissionService(
            operations: operations, payloadReady: { true }, socketReady: { true }
        )
        XCTAssertEqual(service.requestAuthorization().state, .ready)
        let revoked = await service.revokeAuthorization()
        XCTAssertEqual(revoked.state, .notRegistered)
    }

}

@MainActor
private final class PermissionWaitFixture {
    var now: TimeInterval = 0
    var registration = NativeNetworkRegistrationStatus.enabled
    var socket = false
    var payload = true
    var effects = 0

    func service(timeout: TimeInterval = 15) -> NativeNetworkPermissionService {
        NativeNetworkPermissionService(operations: NativeNetworkPermissionOperations(
                registrationStatus: { self.registration },
                register: { self.effects += 1; self.registration = .enabled },
                unregister: { self.effects += 1; self.registration = .notRegistered },
                openSettings: { self.effects += 1 }
            ),
            payloadReady: { self.payload }, socketReady: { self.socket },
            clock: { self.now }, readinessTimeout: timeout
        )
    }
}
