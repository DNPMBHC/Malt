// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class RuntimeGraphicsRoutingTests: XCTestCase, @unchecked Sendable {
    private let stressedHost = RuntimeHostSnapshot(
        operatingSystemVersion: .init(major: 27, minor: 0, patch: 0),
        architecture: "arm64",
        isAppleSilicon: true,
        gameModePlatformAvailable: true,
        thermalState: .serious,
        isLowPowerModeEnabled: false,
        metalDeviceName: "Test GPU",
        metalFXSpatialScalingAvailable: true,
        metalFXTemporalScalingAvailable: true,
        gpuDeveloperToolsAvailable: true
    )

    func testLegacyDXVKBoooleanPlistDecodesToCompatibleGraphicsBackendMode() throws {
        let legacyTruePlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>dxvkConfig</key>
            <dict>
                <key>dxvk</key>
                <true/>
            </dict>
        </dict>
        </plist>
        """
        let decodedTrue = try PropertyListDecoder().decode(BottleSettings.self, from: Data(legacyTruePlist.utf8))
        XCTAssertEqual(decodedTrue.wineGraphicsBackendMode, .dxvk)
        XCTAssertTrue(decodedTrue.dxvk)

        let legacyFalsePlist = legacyTruePlist.replacingOccurrences(of: "<true/>", with: "<false/>")
        var decodedFalse = try PropertyListDecoder().decode(BottleSettings.self, from: Data(legacyFalsePlist.utf8))
        XCTAssertEqual(decodedFalse.wineGraphicsBackendMode, .auto)
        XCTAssertFalse(decodedFalse.dxvk)

        decodedFalse.dxvk = true
        XCTAssertEqual(decodedFalse.wineGraphicsBackendMode, .dxvk)
        decodedFalse.dxvk = false
        XCTAssertEqual(decodedFalse.wineGraphicsBackendMode, .d3dMetal)
    }

    func testAutoRoutingAndExplicitPinningRespectAPIAndAvailability() {
        var settings = BottleSettings()
        settings.wineGraphicsBackendMode = .auto
        settings.directXAPIRequirement = .directX11
        settings.graphicsRoutingPreference = .performanceFirst

        let dx11Auto = settings.resolveGraphicsBackendRoute(available: .all)
        XCTAssertEqual(dx11Auto.selectedBackend, .dxmt)
        XCTAssertFalse(dx11Auto.usedFallback)

        let noDXMT = HostAvailableWineBackends(hasD3DMetal: true, hasDXMT: false, hasDXVK: true)
        let dx11Fallback = settings.resolveGraphicsBackendRoute(available: noDXMT)
        XCTAssertEqual(dx11Fallback.selectedBackend, .d3dMetal)
        XCTAssertTrue(dx11Fallback.usedFallback)

        // DX12 never misroutes to DXMT or DXVK when D3DMetal is absent.
        settings.directXAPIRequirement = .directX12
        let noD3DMetal = HostAvailableWineBackends(hasD3DMetal: false, hasDXMT: true, hasDXVK: true)
        let dx12Unavailable = settings.resolveGraphicsBackendRoute(available: noD3DMetal)
        XCTAssertNil(dx12Unavailable.selectedBackend)

        settings.wineGraphicsBackendMode = .dxmt
        let pinnedDXMT = settings.resolveGraphicsBackendRoute(available: noD3DMetal)
        XCTAssertEqual(pinnedDXMT.selectedBackend, .dxmt)
        XCTAssertFalse(pinnedDXMT.usedFallback)
    }

    func testDXMTEnvironmentIsolatesPerBottleCacheAndAppliesAdaptivePolicyNonDestructively() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appending(path: "game.exe")
        try Data().write(to: executable)

        let bottle = Bottle(bottleUrl: dir)
        bottle.settings.wineGraphicsBackendMode = .dxmt
        bottle.settings.adaptiveResourcePolicyEnabled = true

        var env: [String: String] = ["WINEDLLPATH": "/existing/wine"]
        let dxmtWine = dir.appending(path: "DXMT/wine")
        bottle.settings.environmentVariables(
            wineEnv: &env,
            bottleURL: dir,
            hostSnapshot: stressedHost,
            availableBackends: .all,
            dxmtWinePath: dxmtWine
        )
        XCTAssertEqual(env["DXMT_SHADER_CACHE"], "1")
        XCTAssertEqual(env["DXMT_SHADER_CACHE_PATH"], dir.appending(path: "dxmt_shader_cache").path)
        XCTAssertEqual(env["WINEDLLPATH"], "\(dxmtWine.path):/existing/wine")
        XCTAssertEqual(env["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=60")
        XCTAssertEqual(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")

        // User-supplied DXMT_CONFIG and cache path must never be clobbered.
        let backend = WineRuntimeBackend(isAvailable: { true })
        let customRequest = RuntimeLaunchRequest(
            executableURL: executable,
            bottle: bottle,
            environment: [
                "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=144",
                "DXMT_SHADER_CACHE_PATH": "/custom/cache"
            ],
            host: stressedHost
        )
        let resolved = backend.resolvedRequest(for: customRequest, availableBackends: .all)
        XCTAssertEqual(resolved.environment["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=144")
        XCTAssertEqual(resolved.environment["DXMT_SHADER_CACHE_PATH"], "/custom/cache")
        XCTAssertEqual(resolved.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")
    }

    func testAvailableGraphicsBackendsAndEnableDXMTSyncDLLsAndCacheDir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let library = root.appending(path: "Libraries")
        let dxmtWin64 = library.appending(path: "DXMT/wine/x86_64-windows")
        let dxmtUnix64 = library.appending(path: "DXMT/wine/x86_64-unix")
        let dxvkX64 = library.appending(path: "DXVK/x64")
        let d3dmExt = library.appending(path: "Wine/lib/external")
        for dir in [dxmtWin64, dxmtUnix64, dxvkX64, d3dmExt] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
            try Data("dxmt-\(dll)".utf8).write(to: dxmtWin64.appending(path: dll))
        }
        try Data("so".utf8).write(to: dxmtUnix64.appending(path: "winemetal.so"))
        try Data("dxvk".utf8).write(to: dxvkX64.appending(path: "d3d11.dll"))
        try Data("dylib".utf8).write(to: d3dmExt.appending(path: "libd3dshared.dylib"))

        let probed = WhiskyWineInstaller.availableGraphicsBackends(fileManager: fileManager, libraryFolder: library)
        XCTAssertEqual(probed, .all)

        let bottleDir = root.appending(path: "Bottle")
        try fileManager.createDirectory(at: bottleDir, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: bottleDir)
        try Wine.enableDXMT(bottle: bottle, dxmtFolder: library.appending(path: "DXMT"), fileManager: fileManager)

        let system32 = bottleDir.appending(path: "drive_c/windows/system32")
        for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
            let copied = try Data(contentsOf: system32.appending(path: dll))
            XCTAssertEqual(String(bytes: copied, encoding: .utf8), "dxmt-\(dll)")
        }
        var isDir: ObjCBool = false
        let cachePath = BottleSettings.dxmtShaderCacheDirectory(for: bottleDir).path
        XCTAssertTrue(fileManager.fileExists(atPath: cachePath, isDirectory: &isDir) && isDir.boolValue)
    }

    func testRuntimePlanBackendResourcePolicyOverloadAndRouteDiagnostic() {
        let plan = RuntimeCoordinator(wineAvailable: { true })
            .plan(for: URL(fileURLWithPath: "/tmp/app.exe"), host: stressedHost)
        let dxmtPolicy = plan.wineResourcePolicy(backend: .dxmt, enabled: true)
        XCTAssertEqual(dxmtPolicy.graphicsBackend, .dxmt)
        XCTAssertEqual(dxmtPolicy.processQualityOfService, .utility)
        XCTAssertEqual(dxmtPolicy.environmentDictionary["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=60")

        var settings = BottleSettings()
        settings.wineGraphicsBackendMode = .auto
        settings.directXAPIRequirement = .directX11
        let route = plan.wineGraphicsRoute(for: settings, available: .all)
        XCTAssertEqual(route.selectedBackend, .dxmt)
    }
}
