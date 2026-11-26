// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class ManagedUserNetProxyServiceTests: XCTestCase {
    private var tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appending(path: "malt-net-proxy-tests-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "malt-net-proxy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeFakeProxyBinary() throws -> URL {
        let bin = tempDir.appending(path: "malt-net-proxy")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bin)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.path(percentEncoded: false)
        )
        return bin
    }

    private func makePlayableBundle(name: String, uuid: String, mac: String = "52:54:00:12:34:56") throws -> URL {
        let bundle = tempDir.appending(path: name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "Backend": "QEMU",
            "Information": ["Name": name, "UUID": uuid],
            "Network": [["Hardware": "virtio-net-pci", "MacAddress": mac, "Mode": "Emulated"]],
            "QEMU": ["AdditionalArguments": []]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try data.write(to: bundle.appending(path: "config.plist"), options: .atomic)
        return bundle
    }

    func testProxyLifecycleStartsAndStopsCleanly() async throws {
        let proxyBin = try makeFakeProxyBinary()
        let sockDir = URL(filePath: "/tmp/malt-net-test-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sockDir) }
        let state = MockProxyProcessState()

        let service = ManagedUserNetProxyService(socketDirectory: sockDir) { _, listenTarget in
            state.markStarted(socketPath: listenTarget)
            let handle = ManagedUserNetProxyProcessHandle(
                processIdentifier: 4242,
                isAlive: { state.isAlive },
                terminate: { state.markStopped() }
            )
            return ManagedUserNetSpawnResult(handle: handle, endpoint: listenTarget, qosUserInteractive: true)
        }

        let endpoint = try await service.ensureRunning(
            binaryPath: proxyBin.path(percentEncoded: false),
            vmIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        XCTAssertEqual(endpoint.processIdentifier, 4242)
        XCTAssertTrue(endpoint.qosUserInteractive)
        XCTAssertTrue(endpoint.socketPath.hasSuffix(".sock"))
        let activeBeforeStop = await service.activeEndpoint()
        XCTAssertEqual(activeBeforeStop, endpoint)

        await service.stop()
        let activeAfterStop = await service.activeEndpoint()
        XCTAssertNil(activeAfterStop)
        XCTAssertFalse(state.isAlive)
        XCTAssertEqual(state.stopCount, 1)
    }

    func testConfigRewriterAppliesUnixStreamPreservesMACAndBlocksProtected() throws {
        let vmID = "11111111-2222-3333-4444-555555555555"
        let bundle = try makePlayableBundle(name: "playable-net.utm", uuid: vmID)
        let changed = try ManagedUserNetConfigRewriter.applyUnixSocketStream(
            bundlePath: bundle.path(percentEncoded: false),
            socketPath: "/tmp/malt-net-test/p-11111111.sock"
        )
        XCTAssertTrue(changed)

        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: bundle.appending(path: "config.plist")),
                options: [], format: nil
            ) as? [String: Any]
        )
        let nics = try XCTUnwrap(plist["Network"] as? [[String: Any]])
        XCTAssertTrue(nics.isEmpty)
        let qemu = try XCTUnwrap(plist["QEMU"] as? [String: Any])
        let args = qemu["AdditionalArguments"] as? [String] ?? []
        XCTAssertTrue(args.contains("stream,id=net0,server=off,addr.type=unix,path=/tmp/malt-net-test/p-11111111.sock"))
        XCTAssertTrue(args.contains("virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,ioeventfd=on,rx_queue_size=1024"))

        // Verify loopback endpoint rewriting for sandboxed QEMUHelper.xpc
        let changedInet = try ManagedUserNetConfigRewriter.applyUnixSocketStream(
            bundlePath: bundle.path(percentEncoded: false),
            socketPath: "127.0.0.1:45123"
        )
        XCTAssertTrue(changedInet)
        let plistInet = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: bundle.appending(path: "config.plist")),
                options: [], format: nil
            ) as? [String: Any]
        )
        let inetArgs = (plistInet["QEMU"] as? [String: Any])?["AdditionalArguments"] as? [String] ?? []
        XCTAssertTrue(inetArgs.contains("stream,id=net0,server=off,addr.type=inet,addr.host=127.0.0.1,addr.port=45123"))

        let golden = try makePlayableBundle(name: "golden-win11-arm64-v1.utm", uuid: vmID)
        XCTAssertThrowsError(
            try ManagedUserNetConfigRewriter.applyUnixSocketStream(
                bundlePath: golden.path(percentEncoded: false),
                socketPath: "/tmp/malt-net-test/p-golden.sock"
            )
        )
    }

    private func makeMockAppBundleWithProxy() throws -> URL {
        let app = tempDir.appending(path: "Malt.app")
        let helperMacOS = app.appending(path: "Contents/Helpers/MaltContainerHelper.app/Contents/MacOS")
        let scriptsDir = app.appending(path: "Contents/Resources/RuntimeScripts")
        try FileManager.default.createDirectory(at: helperMacOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let proxyBin = app.appending(path: "Contents/Helpers/malt-net-proxy")
        for file in [helperMacOS.appending(path: "UTM"), helperMacOS.appending(path: "utmctl"), proxyBin] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false)
            )
        }
        try Data("# kiosk".utf8).write(to: scriptsDir.appending(path: "kiosk-app-shell.ps1"))
        return app
    }

    func testOrchestratorPrefersVMNetWhenActiveAndFallsBackToManagedProxy() async throws {
        let vmID = "22222222-3333-4444-5555-666666666666"
        let bundle = try makePlayableBundle(name: "playable-orch.utm", uuid: vmID)
        let app = try makeMockAppBundleWithProxy()
        let config = UnifiedOrchestratorConfiguration(
            defaultPlayableVMBundlePath: bundle.path(percentEncoded: false), appBundleURL: app
        )
        let state = MockProxyProcessState()
        let sockDir = URL(filePath: "/tmp/malt-orch-net-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sockDir) }

        let proxyService = ManagedUserNetProxyService(socketDirectory: sockDir) { _, sock in
            state.markStarted(socketPath: sock)
            let handle = ManagedUserNetProxyProcessHandle(
                processIdentifier: 9001, isAlive: { state.isAlive }, terminate: { state.markStopped() }
            )
            return ManagedUserNetSpawnResult(handle: handle, endpoint: sock, qosUserInteractive: true)
        }

        let vmnetStatus = NativeVMNetStatus(
            daemonInstalled: true, socketActive: true,
            socketPath: "/var/run/malt-vmnet-bridge.sock", activeMode: .vmnetKernelDirect
        )
        let vmnetOrch = UnifiedRuntimeOrchestrator(
            configuration: config, managedUserNetProxy: proxyService, vmnetStatusProbe: { vmnetStatus }
        )
        let health1 = vmnetOrch.healthStatus()
        XCTAssertEqual(health1["managed_user_net_proxy_bundled"], true)
        XCTAssertEqual(health1["non_slirp_network_ready"], true)
        XCTAssertEqual(state.startCount, 0)

        let inactiveStatus = NativeVMNetStatus(
            daemonInstalled: false, socketActive: false, socketPath: nil, activeMode: .notVerified
        )
        let proxyOrch = UnifiedRuntimeOrchestrator(
            configuration: config, managedUserNetProxy: proxyService, vmnetStatusProbe: { inactiveStatus }
        )
        let health2 = proxyOrch.healthStatus()
        XCTAssertEqual(health2["vmnet_kernel_direct_ready"], false)
        XCTAssertEqual(health2["managed_user_net_proxy_bundled"], true)
        XCTAssertEqual(health2["non_slirp_network_ready"], true)
    }
}

private final class MockProxyProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = false
    private var starts = 0
    private var stops = 0
    private var lastSocket = ""

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func markStarted(socketPath: String) {
        lock.lock()
        defer { lock.unlock() }
        alive = true
        starts += 1
        lastSocket = socketPath
    }

    func markStopped() {
        lock.lock()
        defer { lock.unlock() }
        alive = false
        stops += 1
    }
}
