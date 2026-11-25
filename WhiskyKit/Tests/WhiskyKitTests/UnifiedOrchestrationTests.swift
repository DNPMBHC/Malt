// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for Phase 13A unified game library, hardware auto-tuner, and runtime orchestrator.

import Foundation
import XCTest
@testable import WhiskyKit

private actor RecordedCommands {
    private(set) var invocations: [(executable: String, arguments: [String])] = []

    func record(executable: String, arguments: [String]) {
        invocations.append((executable, arguments))
    }

    func count() -> Int {
        invocations.count
    }

    func first() -> (executable: String, arguments: [String])? {
        invocations.first
    }
}

final class UnifiedOrchestrationTests: XCTestCase {
    private var tempDir: URL?

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "whisky-p13a-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testUnifiedGameLibraryStorePersistsUpsertAndRemove() throws {
        let dir = try XCTUnwrap(tempDir)
        let storeURL = dir.appending(path: "UnifiedGameLibrary.json")
        let store = UnifiedGameLibraryStore(storageURL: storeURL)

        let wineEntry = UnifiedGameEntry(
            name: "Hades II",
            executablePath: "/Games/Hades2.exe",
            engineKind: .nativeWine,
            presetTier: .balancedRecommended,
            bottleURL: dir.appending(path: "Bottles/Main")
        )
        let vmEntry = UnifiedGameEntry(
            name: "Valorant",
            executablePath: "C:\\Riot Games\\VALORANT\\live\\VALORANT.exe",
            engineKind: .antiCheatVM,
            presetTier: .competitiveHighFPS,
            vmBundlePath: "/Volumes/External/playable.utm"
        )

        store.upsert(wineEntry)
        store.upsert(vmEntry)
        XCTAssertEqual(store.entries.count, 2)

        var updatedWine = wineEntry
        updatedWine.presetTier = .nativeQuality
        store.upsert(updatedWine)
        XCTAssertEqual(store.entries.count, 2)

        let reloaded = UnifiedGameLibraryStore(storageURL: storeURL)
        reloaded.load()
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(
            reloaded.entries.first(where: { $0.id == wineEntry.id })?.presetTier,
            .nativeQuality
        )

        reloaded.remove(id: vmEntry.id)
        let afterRemove = UnifiedGameLibraryStore(storageURL: storeURL)
        afterRemove.load()
        XCTAssertEqual(afterRemove.entries.count, 1)
        XCTAssertEqual(afterRemove.entries.first?.id, wineEntry.id)
    }

    func testClassifyInstallerRecommendsAntiCheatVMOrNativeWine() throws {
        let dir = try XCTUnwrap(tempDir)
        let store = UnifiedGameLibraryStore(storageURL: dir.appending(path: "lib.json"))

        let valorantURL = dir.appending(path: "Install VALORANT.exe")
        XCTAssertEqual(store.classifyInstaller(url: valorantURL), .antiCheatVM)

        let deltaForceURL = dir.appending(path: "DeltaForce_WeGame_Setup.exe")
        XCTAssertEqual(store.classifyInstaller(url: deltaForceURL), .antiCheatVM)

        let indieURL = dir.appending(path: "HollowKnightSetup.exe")
        try Data("standard unity installer payload".utf8).write(to: indieURL)
        XCTAssertEqual(store.classifyInstaller(url: indieURL), .nativeWine)

        let embeddedACURL = dir.appending(path: "GenericLauncher.exe")
        try Data("MZ...AntiCheatExpertService...".utf8).write(to: embeddedACURL)
        XCTAssertEqual(store.classifyInstaller(url: embeddedACURL), .antiCheatVM)
    }

    func testHardwareAutoTunerRecommendationsAcrossMemoryTiers() {
        let profile16 = HardwareProfileSnapshot(
            chipName: "Apple M4",
            totalCores: 10,
            performanceCores: 4,
            efficiencyCores: 6,
            physicalMemoryGiB: 16,
            displayRefreshRateHz: 120,
            recommendedStoragePath: "/Volumes/FastSSD/whisky-phase2-guest"
        )
        let rec16 = HardwareAutoTuner.recommend(
            for: profile16,
            benchmarkScore: 72.0,
            durationSeconds: 11.2
        )
        XCTAssertEqual(rec16.recommendedVCPU, 8)
        XCTAssertEqual(rec16.recommendedRAMMiB, 10240)
        XCTAssertEqual(rec16.recommendedTier, .balancedRecommended)
        XCTAssertTrue(rec16.enableGameMode)
        XCTAssertEqual(rec16.mouseCoalesceMicros, 1500)
        XCTAssertTrue(rec16.blockAccidentalShortcuts)

        let profile24 = HardwareProfileSnapshot(
            chipName: "Apple M4 Pro",
            totalCores: 12,
            performanceCores: 8,
            efficiencyCores: 4,
            physicalMemoryGiB: 24,
            displayRefreshRateHz: 120,
            recommendedStoragePath: "/Volumes/FastSSD/whisky-phase2-guest"
        )
        let rec24 = HardwareAutoTuner.recommend(
            for: profile24,
            benchmarkScore: 85.0,
            durationSeconds: 10.5
        )
        XCTAssertEqual(rec24.recommendedVCPU, 10)
        XCTAssertEqual(rec24.recommendedRAMMiB, 12288)
        XCTAssertEqual(rec24.recommendedTier, .nativeQuality)
    }

    func testHardwareAutoTunerRecommendationFor8GiB() {
        let profile8 = HardwareProfileSnapshot(
            chipName: "Apple M1",
            totalCores: 8,
            performanceCores: 4,
            efficiencyCores: 4,
            physicalMemoryGiB: 8,
            displayRefreshRateHz: 60,
            recommendedStoragePath: "/tmp"
        )
        let rec8 = HardwareAutoTuner.recommend(
            for: profile8,
            benchmarkScore: 45.0,
            durationSeconds: 12.0
        )
        XCTAssertEqual(rec8.recommendedVCPU, 6)
        XCTAssertEqual(rec8.recommendedRAMMiB, 6144)
        XCTAssertEqual(rec8.recommendedTier, .competitiveHighFPS)
        XCTAssertEqual(rec8.mouseCoalesceMicros, 2000)
    }

    func testHardwareAutoTunerDetectAndQuickBenchmark() async {
        let tuner = HardwareAutoTuner(benchmarkDurationSeconds: 0.15)
        let snapshot = tuner.detectHardwareProfile()
        XCTAssertFalse(snapshot.chipName.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.totalCores, 1)
        XCTAssertGreaterThanOrEqual(snapshot.physicalMemoryGiB, 1)
        XCTAssertGreaterThanOrEqual(snapshot.displayRefreshRateHz, 60)

        let rec = await tuner.runQuickBenchmarkAndRecommend()
        XCTAssertEqual(rec.hardware.chipName, snapshot.chipName)
        XCTAssertGreaterThan(rec.benchmarkScore, 0.0)
        XCTAssertGreaterThan(rec.durationSeconds, 0.0)
        XCTAssertGreaterThanOrEqual(rec.recommendedVCPU, 4)
        XCTAssertGreaterThanOrEqual(rec.recommendedRAMMiB, 6144)
    }

    func testOrchestratorLaunchAndInstallForBothEngines() async throws {
        let dir = try XCTUnwrap(tempDir)
        let store = UnifiedGameLibraryStore(storageURL: dir.appending(path: "store.json"))
        let bottleURL = dir.appending(path: "Bottles/Default")
        let wineExe = dir.appending(path: "Game.exe")
        let installerExe = dir.appending(path: "Setup.exe")
        let vmBundle = dir.appending(path: "playable.utm")
        let fakeManager = dir.appending(path: "golden_guest_manager.py")

        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vmBundle, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: wineExe)
        try Data("setup".utf8).write(to: installerExe)
        try Data("#!/usr/bin/env python3".utf8).write(to: fakeManager)

        let recorder = RecordedCommands()
        let config = UnifiedOrchestratorConfiguration(
            utmCustomAppPath: dir.appending(path: "MissingUTMCustom.app").path(percentEncoded: false),
            utmAppPath: dir.appending(path: "MissingUTM.app").path(percentEncoded: false),
            goldenManagerScriptPath: fakeManager.path(percentEncoded: false),
            kioskShellScriptPath: dir.appending(path: "kiosk.ps1").path(percentEncoded: false),
            defaultPlayableVMBundlePath: vmBundle.path(percentEncoded: false),
            defaultBottleURL: bottleURL
        )

        let orchestrator = UnifiedRuntimeOrchestrator(
            libraryStore: store,
            configuration: config,
            commandRunner: { executable, args in
                await recorder.record(executable: executable, arguments: args)
                return OrchestratorCommandResult(exitCode: 0, stdout: "ok")
            }
        )

        let installedWine = try await orchestrator.install(
            installerURL: installerExe,
            engineKind: .nativeWine,
            title: "Indie Title"
        )
        XCTAssertEqual(installedWine.engineKind, .nativeWine)
        XCTAssertEqual(store.entries.count, 1)

        let vmEntry = UnifiedGameEntry(
            name: "AntiCheat Title",
            executablePath: "C:\\Games\\Shooter.exe",
            engineKind: .antiCheatVM,
            vmBundlePath: vmBundle.path(percentEncoded: false)
        )
        try await orchestrator.launch(entry: vmEntry)

        let count = await recorder.count()
        XCTAssertEqual(count, 2)
        let health = orchestrator.healthStatus()
        XCTAssertEqual(health["golden_manager_ready"], true)
        XCTAssertEqual(health["library_store_writable"], true)
    }

    func testOrchestratorRejectsMissingInstallerOrVMBundle() async throws {
        let dir = try XCTUnwrap(tempDir)
        let store = UnifiedGameLibraryStore(storageURL: dir.appending(path: "store.json"))
        let orchestrator = UnifiedRuntimeOrchestrator(libraryStore: store)

        let missingInstaller = dir.appending(path: "NoSuchInstaller.exe")
        do {
            _ = try await orchestrator.install(
                installerURL: missingInstaller,
                engineKind: .nativeWine,
                title: "Broken"
            )
            XCTFail("Expected missingInstaller error")
        } catch let error as UnifiedOrchestrationError {
            XCTAssertEqual(error, .missingInstaller(missingInstaller.path(percentEncoded: false)))
        }

        let brokenVM = UnifiedGameEntry(
            name: "Broken VM",
            executablePath: "C:\\game.exe",
            engineKind: .antiCheatVM,
            vmBundlePath: dir.appending(path: "missing.utm").path(percentEncoded: false)
        )
        do {
            try await orchestrator.launch(entry: brokenVM)
            XCTFail("Expected missingVMBundle error")
        } catch let error as UnifiedOrchestrationError {
            XCTAssertEqual(
                error,
                .missingVMBundle(dir.appending(path: "missing.utm").path(percentEncoded: false))
            )
        }
    }
}
