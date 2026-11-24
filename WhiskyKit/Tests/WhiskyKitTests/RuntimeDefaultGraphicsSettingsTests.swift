// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC

import XCTest
@testable import WhiskyKit

final class RuntimeDefaultGraphicsSettingsTests: XCTestCase {
    func testProbeOverridesDecodeThroughProductionProgramSettings() throws {
        let fixture: [String: Any] = [
            "locale": "", "arguments": "",
            "environment": ["DXMT_SHADER_CACHE_PATH": "/isolated/cache"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0)
        let settings = try PropertyListDecoder().decode(ProgramSettings.self, from: data)
        XCTAssertEqual(settings.environment["DXMT_SHADER_CACHE_PATH"], "/isolated/cache")
        XCTAssertEqual(settings.locale, .auto)
        XCTAssertEqual(settings.arguments, "")
    }

    func testNewConfigurationUsesIsolatedAppDefaults() throws {
        let domain = "demo-app.defaults-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let initial = BottleDXVKConfig(defaults: defaults)
        XCTAssertEqual(initial.dxmtMetalFXPreset, .off)
        XCTAssertEqual(initial.dxmtMetalFXOutputHeight, 1080)
        XCTAssertTrue(initial.dxvkPreferKosmicKrisp)

        defaults.set("quality", forKey: "runtime.defaultMetalFXPreset")
        defaults.set(1440, forKey: "runtime.defaultMetalFXOutputHeight")
        defaults.set(false, forKey: "runtime.defaultPreferVulkanDriver")
        let configured = BottleDXVKConfig(defaults: defaults)
        XCTAssertEqual(configured.dxmtMetalFXPreset, .quality)
        XCTAssertEqual(configured.dxmtMetalFXOutputHeight, 1440)
        XCTAssertFalse(configured.dxvkPreferKosmicKrisp)
        XCTAssertEqual(initial.dxmtMetalFXPreset, .off)
    }

    func testInvalidDefaultsAndOldConfigurationKeepSafeValues() throws {
        let domain = "demo-app.defaults-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("unknown-preset", forKey: "runtime.defaultMetalFXPreset")
        defaults.set(-1, forKey: "runtime.defaultMetalFXOutputHeight")
        defaults.set(false, forKey: "runtime.defaultPreferVulkanDriver")
        let invalid = BottleDXVKConfig(defaults: defaults)
        XCTAssertEqual(invalid.dxmtMetalFXPreset, .off)
        XCTAssertEqual(invalid.dxmtMetalFXOutputHeight, 1)
        let old = try JSONDecoder().decode(BottleDXVKConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old.dxmtMetalFXPreset, .off)
        XCTAssertEqual(old.dxmtMetalFXOutputHeight, 1080)
        XCTAssertTrue(old.dxvkPreferKosmicKrisp)
        let oldBottle = try JSONDecoder().decode(BottleSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(oldBottle.dxmtMetalFXPreset, .off)
        XCTAssertEqual(oldBottle.dxmtMetalFXOutputHeight, 1080)
        XCTAssertTrue(oldBottle.dxvkPreferKosmicKrisp)
    }
}
