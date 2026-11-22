// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import WhiskyKit

final class RuntimeStorageTests: XCTestCase, @unchecked Sendable {
    private typealias Metadata = RuntimeStorageTargetSelector.VolumeMetadata

    func testZeroImportantUsageFallsBackToRealAvailableCapacityRegardlessOfOrder() {
        let smaller = URL(fileURLWithPath: "/Volumes/AlphaSmall", isDirectory: true)
        let larger = URL(fileURLWithPath: "/Volumes/ZuluLarge", isDirectory: true)
        let table: [URL: Metadata] = [
            smaller: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0,
                availableCapacity: 20 * 1024 * 1024 * 1024,
                fileSystemFreeSize: nil
            ),
            larger: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0,
                availableCapacity: 120 * 1024 * 1024 * 1024,
                fileSystemFreeSize: nil
            )
        ]

        let forward = RuntimeStorageTargetSelector.preferredTarget(
            volumes: [smaller, larger], folderName: "staging", metadataReader: { table[$0] }
        )
        let reversed = RuntimeStorageTargetSelector.preferredTarget(
            volumes: [larger, smaller], folderName: "staging", metadataReader: { table[$0] }
        )

        XCTAssertEqual(forward, larger.appendingPathComponent("staging", isDirectory: true))
        XCTAssertEqual(reversed, larger.appendingPathComponent("staging", isDirectory: true))
    }

    func testZeroImportantUsageOnLargerVolumeBeatsPositiveImportantUsageOnSmallerVolume() {
        let smaller = URL(fileURLWithPath: "/Volumes/SmallPositive", isDirectory: true)
        let larger = URL(fileURLWithPath: "/Volumes/LargeZeroEstimate", isDirectory: true)
        let table: [URL: Metadata] = [
            smaller: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 15 * 1024 * 1024 * 1024,
                availableCapacity: 15 * 1024 * 1024 * 1024,
                fileSystemFreeSize: 15 * 1024 * 1024 * 1024
            ),
            larger: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0,
                availableCapacity: 80 * 1024 * 1024 * 1024,
                fileSystemFreeSize: 80 * 1024 * 1024 * 1024
            )
        ]

        let selected = RuntimeStorageTargetSelector.preferredTarget(
            volumes: [smaller, larger], folderName: "staging", metadataReader: { table[$0] }
        )
        XCTAssertEqual(selected, larger.appendingPathComponent("staging", isDirectory: true))
    }

    func testFallbackUsesFileSystemFreeSizeWhenVolumeCapacitiesAreMissingOrZero() {
        let smaller = URL(fileURLWithPath: "/Volumes/FSAlpha", isDirectory: true)
        let larger = URL(fileURLWithPath: "/Volumes/FSBeta", isDirectory: true)
        let table: [URL: Metadata] = [
            smaller: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0,
                availableCapacity: nil,
                fileSystemFreeSize: 10_000
            ),
            larger: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: nil,
                availableCapacity: 0,
                fileSystemFreeSize: 90_000
            )
        ]

        let selected = RuntimeStorageTargetSelector.preferredTarget(
            volumes: [smaller, larger], folderName: "staging", metadataReader: { table[$0] }
        )
        XCTAssertEqual(selected, larger.appendingPathComponent("staging", isDirectory: true))
    }

    func testEqualZeroAndEqualPositiveCapacitiesSortDeterministicallyByPath() {
        let first = URL(fileURLWithPath: "/Volumes/DiskA", isDirectory: true)
        let second = URL(fileURLWithPath: "/Volumes/DiskB", isDirectory: true)
        let zeroTable: [URL: Metadata] = [
            first: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0, availableCapacity: 0, fileSystemFreeSize: 0
            ),
            second: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0, availableCapacity: 0, fileSystemFreeSize: 0
            )
        ]

        XCTAssertEqual(
            RuntimeStorageTargetSelector.preferredTarget(
                volumes: [second, first], folderName: "staging", metadataReader: { zeroTable[$0] }
            ),
            first.appendingPathComponent("staging", isDirectory: true)
        )

        let equalPositive: [URL: Metadata] = [
            first: Metadata(
                isInternal: true, isReadOnly: false,
                availableCapacityForImportantUsage: 50_000, availableCapacity: 50_000, fileSystemFreeSize: 50_000
            ),
            second: Metadata(
                isInternal: true, isReadOnly: false,
                availableCapacityForImportantUsage: 50_000, availableCapacity: 50_000, fileSystemFreeSize: 50_000
            )
        ]
        XCTAssertEqual(
            RuntimeStorageTargetSelector.preferredTarget(
                volumes: [second, first], folderName: "staging", metadataReader: { equalPositive[$0] }
            ),
            first.appendingPathComponent("staging", isDirectory: true)
        )
    }

    func testSelectorPrefersExternalWritableKnownCapacityAndIgnoresReadOnlyOrNonFileURLs() throws {
        let readOnlyExternal = URL(fileURLWithPath: "/Volumes/ReadOnlyExt", isDirectory: true)
        let unknownExternal = URL(fileURLWithPath: "/Volumes/UnknownExt", isDirectory: true)
        let knownExternal = URL(fileURLWithPath: "/Volumes/KnownExt", isDirectory: true)
        let hugeInternal = URL(fileURLWithPath: "/", isDirectory: true)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/volume"))
        let table: [URL: Metadata] = [
            readOnlyExternal: Metadata(
                isInternal: false, isReadOnly: true,
                availableCapacityForImportantUsage: 999_999, availableCapacity: 999_999, fileSystemFreeSize: 999_999
            ),
            unknownExternal: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: -1, availableCapacity: nil, fileSystemFreeSize: nil
            ),
            knownExternal: Metadata(
                isInternal: false, isReadOnly: false,
                availableCapacityForImportantUsage: 0, availableCapacity: 1_024, fileSystemFreeSize: 1_024
            ),
            hugeInternal: Metadata(
                isInternal: true, isReadOnly: false,
                availableCapacityForImportantUsage: 500_000_000, availableCapacity: 500_000_000,
                fileSystemFreeSize: 500_000_000
            )
        ]

        let selected = RuntimeStorageTargetSelector.preferredTarget(
            volumes: [remoteURL, readOnlyExternal, hugeInternal, unknownExternal, knownExternal],
            folderName: "staging",
            metadataReader: { table[$0] }
        )
        XCTAssertEqual(selected, knownExternal.appendingPathComponent("staging", isDirectory: true))
    }
}
