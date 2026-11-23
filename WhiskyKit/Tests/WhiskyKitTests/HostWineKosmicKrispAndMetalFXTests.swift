// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

final class HostWineKosmicKrispAndMetalFXTests: XCTestCase {
    func testVulkanICDRouteSelectsKosmicKrispWhenReadyOnMacOS26PlusAppleSilicon() {
        let snapshot = Self.snapshot(osMajor: 27, appleSilicon: true)
        let available = HostVulkanICDAvailability(
            hasKosmicKrispICD: true,
            kosmicKrispSupportsProcessArchitecture: true,
            kosmicKrispSupportsGeometryShader: true,
            kosmicKrispSupportsFillModeNonSolid: true,
            hasMoltenVK: true,
            kosmicKrispICDManifestPath: "<home>/vulkan/icd.d/kosmickrisp_icd.json",
            vulkanLoaderLibraryPath: "<home>/vulkan/lib/libvulkan.1.dylib",
            moltenVKLibraryPath: "<home>/mvk/libMoltenVK.dylib"
        )

        let route = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: snapshot,
            available: available,
            preferKosmicKrisp: true
        )
        XCTAssertEqual(route.selectedICD, .kosmicKrisp)
        XCTAssertFalse(route.usedFallback)
        XCTAssertEqual(route.fallbackChain, [.kosmicKrisp, .moltenVK])
        XCTAssertEqual(route.environmentDictionary["WINE_SONAME_LIBVULKAN"], "<home>/vulkan/lib/libvulkan.1.dylib")
        XCTAssertEqual(route.environmentDictionary["VK_DRIVER_FILES"], "<home>/vulkan/icd.d/kosmickrisp_icd.json")
        XCTAssertEqual(route.environmentDictionary["VK_ICD_FILENAMES"], "<home>/vulkan/icd.d/kosmickrisp_icd.json")
    }

    func testVulkanICDRouteFallsBackToMoltenVKOnMissingICDOrOlderOS() {
        let mvkPath = "<home>/mvk/libMoltenVK.dylib"
        let missingICD = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: Self.snapshot(osMajor: 27, appleSilicon: true),
            available: HostVulkanICDAvailability(
                hasKosmicKrispICD: false,
                hasMoltenVK: true,
                moltenVKLibraryPath: mvkPath
            )
        )
        XCTAssertEqual(missingICD.selectedICD, .moltenVK)
        XCTAssertTrue(missingICD.usedFallback)
        XCTAssertEqual(missingICD.environmentDictionary["WINE_SONAME_LIBVULKAN"], mvkPath)

        let olderOS = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: Self.snapshot(osMajor: 15, appleSilicon: true),
            available: HostVulkanICDAvailability(hasKosmicKrispICD: true, hasMoltenVK: true)
        )
        XCTAssertEqual(olderOS.selectedICD, .moltenVK)
        XCTAssertTrue(olderOS.usedFallback)
        XCTAssertTrue(olderOS.reason.contains("macOS 26+"))

        let neither = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: Self.snapshot(osMajor: 27, appleSilicon: true),
            available: HostVulkanICDAvailability(hasKosmicKrispICD: false, hasMoltenVK: false)
        )
        XCTAssertNil(neither.selectedICD)
        XCTAssertFalse(neither.usedFallback)
    }

    func testVulkanICDRouteFallsBackToMoltenVKOnSliceOrDXVKFeatureGaps() {
        let archMismatch = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: Self.snapshot(osMajor: 27, appleSilicon: true),
            available: HostVulkanICDAvailability(
                hasKosmicKrispICD: true,
                kosmicKrispSupportsProcessArchitecture: false,
                hasMoltenVK: true
            )
        )
        XCTAssertEqual(archMismatch.selectedICD, .moltenVK)
        XCTAssertTrue(archMismatch.usedFallback)
        XCTAssertTrue(archMismatch.reason.contains("architecture slice"))

        let missingGS = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: Self.snapshot(osMajor: 27, appleSilicon: true),
            available: HostVulkanICDAvailability(
                hasKosmicKrispICD: true,
                kosmicKrispSupportsGeometryShader: false,
                hasMoltenVK: true
            )
        )
        XCTAssertEqual(missingGS.selectedICD, .moltenVK)
        XCTAssertTrue(missingGS.usedFallback)
        XCTAssertTrue(missingGS.reason.contains("geometryShader"))

        let missingFillMode = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: Self.snapshot(osMajor: 27, appleSilicon: true),
            available: HostVulkanICDAvailability(
                hasKosmicKrispICD: true,
                kosmicKrispSupportsFillModeNonSolid: false,
                hasMoltenVK: true
            )
        )
        XCTAssertEqual(missingFillMode.selectedICD, .moltenVK)
        XCTAssertTrue(missingFillMode.usedFallback)
        XCTAssertTrue(missingFillMode.reason.contains("fillModeNonSolid"))
    }

    func testDXMTMetalFXPolicyDefaultsOffAndActivatesOnlyForEligibleHighResNominalRuns() {
        let nominal = Self.snapshot(osMajor: 27, appleSilicon: true, spatialFX: true)

        let defaultOff = HostDXMTMetalFXPolicy(snapshot: nominal)
        XCTAssertEqual(defaultOff.effectivePreset, .off)
        XCTAssertFalse(defaultOff.isActive)
        XCTAssertNil(defaultOff.fallbackReason)
        XCTAssertTrue(defaultOff.environmentOverrides.isEmpty)

        let highResQuality = HostDXMTMetalFXPolicy(
            snapshot: nominal,
            options: HostDXMTMetalFXOptions(preset: .quality, outputWidth: 2560, outputHeight: 1440)
        )
        XCTAssertTrue(highResQuality.isActive)
        XCTAssertEqual(highResQuality.effectivePreset, .quality)
        XCTAssertEqual(highResQuality.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(highResQuality.environmentDictionary["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5")

        let lowResGuarded = HostDXMTMetalFXPolicy(
            snapshot: nominal,
            options: HostDXMTMetalFXOptions(preset: .performance, outputWidth: 1280, outputHeight: 720)
        )
        XCTAssertFalse(lowResGuarded.isActive)
        XCTAssertEqual(lowResGuarded.effectivePreset, .off)
        XCTAssertEqual(lowResGuarded.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")
        XCTAssertNotNil(lowResGuarded.fallbackReason)

        let lowResExplicit = HostDXMTMetalFXPolicy(
            snapshot: nominal,
            options: HostDXMTMetalFXOptions(
                preset: .performance,
                outputWidth: 1280,
                outputHeight: 720,
                allowLowResolutionUpscaling: true
            )
        )
        XCTAssertTrue(lowResExplicit.isActive)
        XCTAssertEqual(lowResExplicit.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(lowResExplicit.environmentDictionary["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2.0")
    }

    func testDXMTMetalFXPolicyFallsBackUnderThermalPressureHardwareGapAndPolicySwitch() {
        let serious = Self.snapshot(osMajor: 27, appleSilicon: true, thermal: .serious, spatialFX: true)
        let throttled = HostDXMTMetalFXPolicy(
            snapshot: serious,
            options: HostDXMTMetalFXOptions(preset: .quality, outputWidth: 2560, outputHeight: 1440)
        )
        XCTAssertFalse(throttled.isActive)
        XCTAssertEqual(throttled.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")
        XCTAssertNotNil(throttled.fallbackReason)

        let noMetalFX = Self.snapshot(osMajor: 27, appleSilicon: true, spatialFX: false)
        let unsupported = HostDXMTMetalFXPolicy(
            snapshot: noMetalFX,
            options: HostDXMTMetalFXOptions(preset: .ultraQuality)
        )
        XCTAssertFalse(unsupported.isActive)
        XCTAssertEqual(unsupported.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")

        let policyDisabled = HostDXMTMetalFXPolicy(
            snapshot: Self.snapshot(osMajor: 27, appleSilicon: true, spatialFX: true),
            options: HostDXMTMetalFXOptions(preset: .quality),
            enabled: false
        )
        XCTAssertFalse(policyDisabled.isActive)
        XCTAssertTrue(policyDisabled.environmentOverrides.isEmpty)
    }

    func testConfiguredWineLaunchPolicyIntegratesMetalFXAndKosmicKrispNonDestructively() {
        let nominal = Self.snapshot(osMajor: 27, appleSilicon: true, spatialFX: true)
        let dxmtPolicy = HostWineLaunchPolicy.configured(
            snapshot: nominal,
            graphicsBackend: .dxmt,
            options: HostWineLaunchOptions(
                dxmtMetalFX: HostDXMTMetalFXOptions(preset: .balanced, outputWidth: 3840, outputHeight: 2160)
            )
        )
        XCTAssertEqual(dxmtPolicy.environmentDictionary["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(dxmtPolicy.environmentDictionary["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.7")

        let preserved = dxmtPolicy.applyingNonDestructively(to: [
            "DXMT_METALFX_SPATIAL_SWAPCHAIN": "0"
        ])
        XCTAssertEqual(preserved["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "0")
        XCTAssertEqual(preserved["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.7")

        let icdRoute = HostWineBackendRouter.routeVulkanICD(
            hostSnapshot: nominal,
            available: HostVulkanICDAvailability(
                hasKosmicKrispICD: true,
                kosmicKrispICDManifestPath: "<home>/kk.json",
                vulkanLoaderLibraryPath: "<home>/libvulkan.1.dylib"
            )
        )
        let dxvkPolicy = HostWineLaunchPolicy.configured(
            snapshot: Self.snapshot(osMajor: 27, appleSilicon: true, thermal: .serious),
            graphicsBackend: .dxvk,
            options: HostWineLaunchOptions(vulkanICDRoute: icdRoute)
        )
        XCTAssertEqual(dxvkPolicy.environmentDictionary["DXVK_FRAME_RATE"], "60")
        XCTAssertEqual(dxvkPolicy.environmentDictionary["VK_DRIVER_FILES"], "<home>/kk.json")
        XCTAssertEqual(dxvkPolicy.environmentDictionary["WINE_SONAME_LIBVULKAN"], "<home>/libvulkan.1.dylib")
    }

    private static func snapshot(
        osMajor: Int = 27,
        appleSilicon: Bool = true,
        thermal: HostThermalState = .nominal,
        lowPower: Bool = false,
        spatialFX: Bool = true
    ) -> RuntimeHostSnapshot {
        RuntimeHostSnapshot(
            operatingSystemVersion: .init(major: osMajor, minor: 0, patch: 0),
            architecture: appleSilicon ? "arm64" : "x86_64",
            isAppleSilicon: appleSilicon,
            gameModePlatformAvailable: appleSilicon,
            isMacOS27OrLater: osMajor >= 27,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            metalDeviceName: appleSilicon ? "Apple M4" : "Intel",
            metalFXSpatialScalingAvailable: spatialFX,
            metalFXTemporalScalingAvailable: false,
            gpuDeveloperToolsAvailable: true
        )
    }
}
