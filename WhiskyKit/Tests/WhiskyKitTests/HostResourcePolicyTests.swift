// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

final class HostResourcePolicyTests: XCTestCase {
    func testWinePolicyFallbackSwitchDisablesAllOverrides() {
        let snapshot = Self.snapshot(thermal: .critical, lowPower: true)
        let dxvkPolicy = HostWineLaunchPolicy(
            snapshot: snapshot,
            graphicsBackend: .dxvk,
            enabled: false
        )
        XCTAssertFalse(dxvkPolicy.isEnabled)
        XCTAssertEqual(dxvkPolicy.processQualityOfService, .userInitiated)
        XCTAssertTrue(dxvkPolicy.environmentOverrides.isEmpty)
        XCTAssertTrue(dxvkPolicy.environmentDictionary.isEmpty)

        let existing = ["WINEPREFIX": "/tmp/prefix"]
        XCTAssertEqual(dxvkPolicy.applyingNonDestructively(to: existing), existing)
    }

    func testWinePolicyEmitsDocumentedDXVKOverridesOnlyUnderThermalOrPowerPressure() {
        let nominal = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .nominal, lowPower: false),
            graphicsBackend: .dxvk
        )
        XCTAssertEqual(nominal.processQualityOfService, .userInitiated)
        XCTAssertTrue(nominal.environmentOverrides.isEmpty)

        let serious = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .serious, lowPower: false),
            graphicsBackend: .dxvk
        )
        XCTAssertEqual(serious.processQualityOfService, .utility)
        XCTAssertEqual(serious.environmentDictionary["DXVK_FRAME_RATE"], "60")
        XCTAssertEqual(serious.environmentDictionary["DXVK_NUM_COMPILER_THREADS"], "2")
        XCTAssertTrue(serious.environmentOverrides.allSatisfy {
            !$0.consumer.isEmpty && !$0.documentationReference.isEmpty
        })

        let lowPower = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .nominal, lowPower: true),
            graphicsBackend: .dxvk
        )
        XCTAssertEqual(lowPower.processQualityOfService, .utility)
        XCTAssertEqual(lowPower.environmentDictionary["DXVK_FRAME_RATE"], "30")
        XCTAssertEqual(lowPower.environmentDictionary["DXVK_NUM_COMPILER_THREADS"], "1")
    }

    func testWinePolicyPreservesUserSuppliedEnvironmentValues() {
        let policy = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .critical, lowPower: true),
            graphicsBackend: .dxvk
        )
        let merged = policy.applyingNonDestructively(to: [
            "DXVK_FRAME_RATE": "120",
            "WINEPREFIX": "/tmp/custom"
        ])
        XCTAssertEqual(merged["DXVK_FRAME_RATE"], "120")
        XCTAssertEqual(merged["DXVK_NUM_COMPILER_THREADS"], "1")
        XCTAssertEqual(merged["WINEPREFIX"], "/tmp/custom")
    }

    func testWinePolicyEmitsNoSyntheticEnvVarsForD3DMetal() {
        let policy = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .critical, lowPower: true),
            graphicsBackend: .d3dMetal
        )
        XCTAssertTrue(policy.environmentOverrides.isEmpty)
        XCTAssertEqual(policy.processQualityOfService, .utility)
        XCTAssertNotNil(policy.unmanagedDomainNote)
    }

    func testWinePolicyEmitsDocumentedDXMTOverridesAndHonorsFallback() {
        let nominal = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .nominal, lowPower: false),
            graphicsBackend: .dxmt
        )
        XCTAssertEqual(nominal.processQualityOfService, .userInitiated)
        XCTAssertTrue(nominal.environmentOverrides.isEmpty)

        let serious = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .serious, lowPower: false),
            graphicsBackend: .dxmt
        )
        XCTAssertEqual(serious.processQualityOfService, .utility)
        XCTAssertEqual(serious.environmentDictionary["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=60")
        XCTAssertEqual(serious.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")
        XCTAssertTrue(serious.environmentOverrides.allSatisfy {
            !$0.consumer.isEmpty && !$0.documentationReference.isEmpty
        })

        let lowPower = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .nominal, lowPower: true),
            graphicsBackend: .dxmt
        )
        XCTAssertEqual(lowPower.environmentDictionary["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=30")
        XCTAssertEqual(lowPower.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")

        let preserved = lowPower.applyingNonDestructively(to: [
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=120"
        ])
        XCTAssertEqual(preserved["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=120")
        XCTAssertEqual(preserved["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")

        let disabled = HostWineLaunchPolicy(
            snapshot: Self.snapshot(thermal: .critical, lowPower: true),
            graphicsBackend: .dxmt,
            enabled: false
        )
        XCTAssertTrue(disabled.environmentOverrides.isEmpty)
        XCTAssertEqual(disabled.processQualityOfService, .userInitiated)
    }

    func testThreeEngineBackendRouterRoutesByDirectXVersionAndAvailability() {
        let dx12 = HostWineBackendRouter.route(apiRequirement: .directX12)
        XCTAssertEqual(dx12.selectedBackend, .d3dMetal)
        XCTAssertFalse(dx12.usedFallback)
        XCTAssertEqual(dx12.fallbackChain, [.d3dMetal])

        let dx12Unavailable = HostWineBackendRouter.route(
            apiRequirement: .directX12,
            available: HostAvailableWineBackends(hasD3DMetal: false, hasDXMT: true, hasDXVK: true)
        )
        XCTAssertNil(dx12Unavailable.selectedBackend)
        XCTAssertFalse(dx12Unavailable.usedFallback)

        let dx11Perf = HostWineBackendRouter.route(
            apiRequirement: .directX11,
            preference: .performanceFirst
        )
        XCTAssertEqual(dx11Perf.selectedBackend, .dxmt)
        XCTAssertFalse(dx11Perf.usedFallback)
        XCTAssertEqual(dx11Perf.fallbackChain, [.dxmt, .d3dMetal, .dxvk])

        let dx11PerfFallback = HostWineBackendRouter.route(
            apiRequirement: .directX11,
            preference: .performanceFirst,
            available: HostAvailableWineBackends(hasD3DMetal: true, hasDXMT: false, hasDXVK: true)
        )
        XCTAssertEqual(dx11PerfFallback.selectedBackend, .d3dMetal)
        XCTAssertTrue(dx11PerfFallback.usedFallback)

        let dx11Compat = HostWineBackendRouter.route(
            apiRequirement: .directX11,
            preference: .compatibilityFallback
        )
        XCTAssertEqual(dx11Compat.selectedBackend, .dxvk)
        XCTAssertFalse(dx11Compat.usedFallback)
        XCTAssertEqual(dx11Compat.fallbackChain, [.dxvk, .dxmt, .d3dMetal])
    }

    func testMetalHostPolicyRespectsCapabilitiesPressureAndFallback() {
        let capableNominal = Self.snapshot(thermal: .nominal, lowPower: false, spatialFX: true)
        let activeFX = HostMetalHostPolicy(snapshot: capableNominal, preferMetalFXSpatial: true)
        XCTAssertNil(activeFX.targetFrameRateCap)
        XCTAssertTrue(activeFX.allowsMetalFXSpatial)
        XCTAssertEqual(activeFX.receiverQueueQoS, "userInitiated")
        XCTAssertEqual(activeFX.cliArguments, [
            "--resource-policy", "maximum-performance",
            "--metalfx", "spatial"
        ])

        let balanced = HostMetalHostPolicy(
            snapshot: Self.snapshot(thermal: .serious, lowPower: false, spatialFX: true),
            preferMetalFXSpatial: true
        )
        XCTAssertEqual(balanced.targetFrameRateCap, 60)
        XCTAssertFalse(balanced.allowsMetalFXSpatial)
        XCTAssertEqual(balanced.receiverQueueQoS, "utility")
        XCTAssertEqual(balanced.cliArguments, ["--resource-policy", "balanced", "--metalfx", "off"])

        let conserve = HostMetalHostPolicy(
            snapshot: Self.snapshot(thermal: .nominal, lowPower: true, spatialFX: true),
            preferMetalFXSpatial: true
        )
        XCTAssertEqual(conserve.targetFrameRateCap, 30)
        XCTAssertFalse(conserve.allowsMetalFXSpatial)
        XCTAssertEqual(conserve.receiverQueueQoS, "background")

        let disabled = HostMetalHostPolicy(snapshot: capableNominal, preferMetalFXSpatial: true, enabled: false)
        XCTAssertNil(disabled.targetFrameRateCap)
        XCTAssertFalse(disabled.allowsMetalFXSpatial)
        XCTAssertEqual(disabled.cliArguments, ["--resource-policy", "off", "--metalfx", "off"])
    }

    func testGuestLaunchPolicyHonorsFallbackAndPressureLevels() {
        let conserve = HostGuestLaunchPolicy(snapshot: Self.snapshot(thermal: .critical, lowPower: true))
        XCTAssertTrue(conserve.pausesHostOptionalBackgroundWork)
        XCTAssertEqual(conserve.suggestedPresentationFrameRateCap, 30)

        let disabled = HostGuestLaunchPolicy(
            snapshot: Self.snapshot(thermal: .critical, lowPower: true),
            enabled: false
        )
        XCTAssertFalse(disabled.pausesHostOptionalBackgroundWork)
        XCTAssertNil(disabled.suggestedPresentationFrameRateCap)
    }

    private static func snapshot(
        thermal: HostThermalState = .nominal,
        lowPower: Bool = false,
        spatialFX: Bool = false
    ) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: 27, minor: 2, patch: 1),
            architecture: "arm64",
            isAppleSilicon: true,
            gameModePlatformAvailable: true,
            isMacOS27OrLater: true,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            metalDeviceName: "Apple M4",
            metalFXSpatialScalingAvailable: spatialFX,
            metalFXTemporalScalingAvailable: false,
            gpuDeveloperToolsAvailable: true
        )
    }
}
