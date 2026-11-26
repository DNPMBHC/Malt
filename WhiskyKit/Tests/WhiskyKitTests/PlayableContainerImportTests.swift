// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated tests for explicit managed-container import and persisted selection.

import Foundation
import XCTest

@testable import WhiskyKit

private struct ImportInvocation: Sendable {
  let executable: String
  let arguments: [String]
  let environment: [String: String]
}

private actor ImportInvocationLog {
  private var calls: [ImportInvocation] = []
  func record(_ executable: String, _ arguments: [String], _ environment: [String: String]) {
    calls.append(ImportInvocation(executable: executable, arguments: arguments, environment: environment))
  }
  func snapshot() -> [ImportInvocation] { calls }
}

final class PlayableContainerImportTests: XCTestCase {
  private var root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appending(path: "container-import-\(UUID().uuidString)")
  private let identifier = UUID()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appending(path: "container-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testUnconfirmedImportDoesNotExecuteOrPersist() async throws {
    let fixture = try stageFixture()
    let log = ImportInvocationLog()
    let orchestrator = makeOrchestrator(fixture: fixture, log: log, response: success())
    do {
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: false)
      XCTFail("Explicit stopped-state confirmation must be required")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("完全关闭"))
    }
    let calls = await log.snapshot()
    XCTAssertTrue(calls.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
  }

  func testVerifiedImportUsesOnlyManagedPythonAndPersistsPrivateSelection() async throws {
    let fixture = try stageFixture()
    let log = ImportInvocationLog()
    let orchestrator = makeOrchestrator(fixture: fixture, log: log, response: success())
    let selected = fixture.bundle.appending(path: ".")
    let result = try await orchestrator.importPlayableContainer(at: selected, confirmedStopped: true)
    XCTAssertEqual(result.bundlePath, fixture.bundle.path)
    XCTAssertEqual(result.vmIdentifier, identifier.uuidString)
    XCTAssertFalse(result.alreadyManaged)
    let calls = await log.snapshot()
    XCTAssertEqual(calls.count, 1)
    let call = try XCTUnwrap(calls.first)
    XCTAssertEqual(call.executable, fixture.python.path)
    XCTAssertEqual(call.arguments, ["-I", fixture.script.path, "import-playable", "--playable",
      fixture.bundle.path, "--confirmed-stopped"])
    XCTAssertEqual(call.environment["__DEMOAPP_TIMEOUT_SECONDS"], "25")
    XCTAssertEqual(call.environment["PYTHONNOUSERSITE"], "1")
    XCTAssertEqual(call.environment["PYTHONDONTWRITEBYTECODE"], "1")
    let attrs = try FileManager.default.attributesOfItem(atPath: fixture.selection.path)
    let parentAttrs = try FileManager.default.attributesOfItem(
      atPath: fixture.selection.deletingLastPathComponent().path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual((parentAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let fresh = UnifiedRuntimeOrchestrator(configuration: configuration(for: fixture))
    XCTAssertEqual(fresh.resolvedRuntimePaths().playableVMBundlePath, fixture.bundle.path)
  }

  func testAlreadyManagedImportReturnsVerifiedSelection() async throws {
    let fixture = try stageFixture()
    let orchestrator = makeOrchestrator(
      fixture: fixture, log: ImportInvocationLog(), response: success(alreadyManaged: true))
    let result = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
    XCTAssertTrue(result.alreadyManaged)
    XCTAssertEqual(orchestrator.resolvedRuntimePaths().playableVMBundlePath, fixture.bundle.path)
  }

  func testIncompleteSuccessReportsCannotPersistSelection() async throws {
    let reports = [
      "{}", "not-json",
      "{\"action\":\"other\",\"imported\":true}",
      "{\"action\":\"import-playable\",\"imported\":true,\"metadata_verified\":true}"
    ]
    for report in reports {
      let fixture = try stageFixture()
      let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: report)
      do {
        _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
        XCTFail("An incomplete success report must fail closed")
      } catch {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
      }
    }
  }

  func testMismatchedUUIDCannotPersistSelection() async throws {
    let fixture = try stageFixture()
    let orchestrator = makeOrchestrator(
      fixture: fixture, log: ImportInvocationLog(), response: success(vmID: UUID()))
    do {
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
      XCTFail("The report must match the local configuration and marker")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
    }
  }

  func testMissingOrPublicMarkerCannotPersistSelection() async throws {
    for permissions in [0, 0o644] {
      let fixture = try stageFixture()
      let marker = fixture.bundle.appending(path: ".playable-meta.json")
      if permissions == 0 {
        try FileManager.default.removeItem(at: marker)
      } else {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: marker.path)
      }
      let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
      do {
        _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
        XCTFail("Only verified private metadata can be selected")
      } catch {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
      }
    }
  }

  func testStructuredRefusalsDoNotPersistOrExposeManagerDetails() async throws {
    for code in ["needs_confirmation", "active_runtime", "suspended_state", "protected_instance", "unsafe_path",
      "invalid_configuration", "conflicting_metadata", "config_changed", "busy_lock", "process_check_failed"] {
      let fixture = try stageFixture()
      let report = "{\"action\":\"import-playable\",\"imported\":false,\"error_code\":\"\(code)\","
        + "\"message\":\"sensitive-detail\"}"
      let orchestrator = makeOrchestrator(
        fixture: fixture, log: ImportInvocationLog(), response: report, exitCode: 1)
      do {
        _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
        XCTFail("A refused import must not be selected")
      } catch {
        XCTAssertFalse(error.localizedDescription.contains("sensitive-detail"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
      }
    }
  }
}

extension PlayableContainerImportTests {
  func testPersistedSelectionFailsClosedWhenMarkerOrUUIDChanges() async throws {
    for removeMarker in [false, true] {
      let fixture = try stageFixture()
      let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
      if removeMarker {
        try FileManager.default.removeItem(at: fixture.bundle.appending(path: ".playable-meta.json"))
      } else {
        try writeConfiguration(at: fixture.bundle, identifier: UUID())
      }
      let fallback = root.appending(path: "fallback/playable.utm")
      try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      try writeConfiguration(at: fallback, identifier: identifier)
      let config = configuration(for: fixture, searchRoots: [fallback.deletingLastPathComponent()])
      XCTAssertNil(UnifiedRuntimeDiscovery.resolve(configuration: config).playableVMBundlePath)
    }
  }

  func testExplicitOverridePrecedesSavedSelection() async throws {
    let fixture = try stageFixture()
    let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
    _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
    let other = root.appending(path: "explicit.utm")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try writeConfiguration(at: other, identifier: UUID())
    let config = configuration(for: fixture, explicit: other.path)
    XCTAssertEqual(UnifiedRuntimeDiscovery.resolve(configuration: config).playableVMBundlePath, other.path)
  }

  func testSymbolicLinkCannotBecomeSavedSelection() async throws {
    let fixture = try stageFixture()
    let alias = root.appending(path: "alias.utm")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.bundle)
    let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
    do {
      _ = try await orchestrator.importPlayableContainer(at: alias, confirmedStopped: true)
      XCTFail("A symbolic link cannot be persisted as a managed selection")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
    }
  }

  func testMissingEmbeddedPythonDoesNotExecuteImport() async throws {
    let fixture = try stageFixture()
    try FileManager.default.removeItem(at: fixture.python)
    let log = ImportInvocationLog()
    let orchestrator = makeOrchestrator(fixture: fixture, log: log, response: success())
    do {
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
      XCTFail("Import requires the packaged management runtime")
    } catch {
      let calls = await log.snapshot()
      XCTAssertTrue(calls.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
    }
  }

  func testInvalidSavedIdentifierAndMissingMarkerCannotRestoreSelection() async throws {
    let fixture = try stageFixture()
    let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
    _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
    let data = try Data(contentsOf: fixture.selection)
    var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    saved["vmIdentifier"] = "invalid"
    try JSONSerialization.data(withJSONObject: saved).write(to: fixture.selection)
    try FileManager.default.removeItem(at: fixture.bundle.appending(path: ".playable-meta.json"))
    let config = configuration(for: fixture, searchRoots: [fixture.bundle.deletingLastPathComponent()])
    XCTAssertNil(UnifiedRuntimeDiscovery.resolve(configuration: config).playableVMBundlePath)
  }

  func testPublicSelectionFileOrDirectoryCannotRestoreSelection() async throws {
    for changeDirectory in [false, true] {
      let fixture = try stageFixture()
      let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
      let target = changeDirectory ? fixture.selection.deletingLastPathComponent() : fixture.selection
      try FileManager.default.setAttributes(
        [.posixPermissions: changeDirectory ? 0o755 : 0o644], ofItemAtPath: target.path)
      let config = configuration(for: fixture, searchRoots: [fixture.bundle.deletingLastPathComponent()])
      XCTAssertNil(UnifiedRuntimeDiscovery.resolve(configuration: config).playableVMBundlePath)
    }
  }

  func testRunnerFailureDoesNotPersistOrExposeRuntimeDetails() async throws {
    let fixture = try stageFixture()
    let orchestrator = UnifiedRuntimeOrchestrator(
      libraryStore: UnifiedGameLibraryStore(storageURL: root.appending(path: "library.json")),
      configuration: configuration(for: fixture), commandRunner: { _, _, _ in
        throw UnifiedOrchestrationError.commandFailed("sensitive-detail")
      })
    do {
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
      XCTFail("A process failure cannot select a container")
    } catch {
      XCTAssertFalse(error.localizedDescription.contains("sensitive-detail"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selection.path))
    }
  }

  func testSymlinkedAncestorCannotRestoreSavedSelection() async throws {
    let fixture = try stageFixture()
    let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
    _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
    let original = fixture.bundle.deletingLastPathComponent()
    let moved = original.deletingLastPathComponent().appending(path: "moved")
    try FileManager.default.moveItem(at: original, to: moved)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
    XCTAssertNil(orchestrator.resolvedRuntimePaths().playableVMBundlePath)
  }

  func testHardLinkedMarkerOrConfigurationCannotRestoreSavedSelection() async throws {
    for name in [".playable-meta.json", "config.plist"] {
      let fixture = try stageFixture()
      let orchestrator = makeOrchestrator(fixture: fixture, log: ImportInvocationLog(), response: success())
      _ = try await orchestrator.importPlayableContainer(at: fixture.bundle, confirmedStopped: true)
      let linked = fixture.bundle.deletingLastPathComponent().appending(path: "linked-file")
      try FileManager.default.linkItem(at: fixture.bundle.appending(path: name), to: linked)
      XCTAssertNil(orchestrator.resolvedRuntimePaths().playableVMBundlePath)
    }
  }

  private struct Fixture {
    let app: URL
    let bundle: URL
    let python: URL
    let script: URL
    let selection: URL
  }

  private func stageFixture() throws -> Fixture {
    let base = root.appending(path: UUID().uuidString)
    let app = base.appending(path: "TestHost.app")
    let python = app.appending(path: "Contents/Frameworks/Python.framework/Versions/Current/bin/python3")
    let script = app.appending(path: "Contents/Resources/RuntimeScripts/golden_guest_manager.py")
    let bundle = base.appending(path: "external/playable.utm")
    for directory in [python.deletingLastPathComponent(), script.deletingLastPathComponent(), bundle] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("#!/bin/sh\n".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    try Data("# fixture\n".utf8).write(to: script)
    try writeConfiguration(at: bundle, identifier: identifier)
    let marker: [String: Any] = ["schema_version": 1, "role": "playable_working_vm",
      "owner": "@DNPMBHC", "vm_uuid": identifier.uuidString]
    let markerURL = bundle.appending(path: ".playable-meta.json")
    try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
    return Fixture(app: app, bundle: bundle, python: python, script: script,
      selection: base.appending(path: "private/selection.json"))
  }

  private func writeConfiguration(at bundle: URL, identifier: UUID) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["Information": ["UUID": identifier.uuidString]], format: .xml, options: 0)
    try data.write(to: bundle.appending(path: "config.plist"))
  }

  private func configuration(for fixture: Fixture, explicit: String? = nil, searchRoots: [URL] = [])
    -> UnifiedOrchestratorConfiguration {
    UnifiedOrchestratorConfiguration(
      utmCustomAppPath: "", utmAppPath: "", defaultPlayableVMBundlePath: explicit,
      appBundleURL: fixture.app, volumesRootURL: root.appending(path: "no-volumes"),
      localVMSearchRoots: searchRoots, playableSelectionStorageURL: fixture.selection)
  }

  private func makeOrchestrator(
    fixture: Fixture, log: ImportInvocationLog, response: String, exitCode: Int32 = 0
  ) -> UnifiedRuntimeOrchestrator {
    UnifiedRuntimeOrchestrator(
      libraryStore: UnifiedGameLibraryStore(storageURL: root.appending(path: "library.json")),
      configuration: configuration(for: fixture),
      commandRunner: { executable, arguments, environment in
        await log.record(executable, arguments, environment)
        return OrchestratorCommandResult(exitCode: exitCode, stdout: response)
      })
  }

  private func success(alreadyManaged: Bool = false, vmID: UUID? = nil) -> String {
    "{\"action\":\"import-playable\",\"imported\":true,\"metadata_verified\":true,"
      + "\"already_managed\":\(alreadyManaged),\"vm_uuid\":\"\((vmID ?? identifier).uuidString)\",\"dry_run\":false}"
  }
}
