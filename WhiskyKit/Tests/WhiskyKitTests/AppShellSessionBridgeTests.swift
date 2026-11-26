// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import WhiskyKit

final class AppShellSessionBridgeTests: XCTestCase {
  func testBindingRequiresSameVMHelperAndLifecycle() async throws {
    let fixture = ShellSignalFixture()
    let bridge = AppShellSessionBridge()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = try await bridge.createBinding(
      vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", directory: directory,
      title: "Sample", windowSize: "1024x680")
    do {
      _ = try await bridge.requireBinding(
        vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", identity: "one")
      XCTFail("An unbound warm helper must be rejected")
    } catch is UnifiedOrchestrationError {}
    await bridge.recordHelperIdentity("one", bindingID: binding.id)
    let verified = try await bridge.requireBinding(
      vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", identity: "one")
    XCTAssertEqual(verified.id, binding.id)
    await bridge.recordHelperIdentity("two", bindingID: binding.id)
    do {
      _ = try await bridge.requireBinding(
        vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", identity: "two")
      XCTFail("An existing binding cannot be reassigned to another process")
    } catch is UnifiedOrchestrationError {}
    do {
      _ = try await bridge.requireBinding(vmIdentifier: UUID().uuidString, helper: "/tmp/helper", identity: "one")
      XCTFail("A binding cannot migrate to a different VM")
    } catch is UnifiedOrchestrationError {}
  }

  func testForegroundCompactAndFinishWriteOnlyPrivateBoundState() async throws {
    let fixture = ShellSignalFixture()
    let bridge = AppShellSessionBridge()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = try await bridge.createBinding(
      vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", directory: directory,
      title: "Sample", windowSize: "1024x680")
    let generation = try await bridge.begin(session: fixture.session, bindingID: binding.id)
    XCTAssertEqual(try state(binding.stateURL), "installer")
    try await bridge.consume(
      fixture.data(), session: fixture.session, challenge: fixture.challenge, generation: generation)
    XCTAssertEqual(try state(binding.stateURL), "game_foreground")
    try await bridge.consume(
      fixture.data(signalChanges: ["sequence": 2, "event": "compact", "foregroundPID": 0]),
      session: fixture.session, challenge: fixture.challenge, generation: generation)
    XCTAssertEqual(try state(binding.stateURL), "installer")
    await bridge.finish(generation: generation)
    XCTAssertEqual(try state(binding.stateURL), "installer")
    let attributes = try FileManager.default.attributesOfItem(atPath: binding.stateURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let parent = try FileManager.default.attributesOfItem(atPath: binding.stateURL.deletingLastPathComponent().path)
    XCTAssertEqual((parent[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }

  func testLateOldGenerationCannotExpandOrCompactNewSession() async throws {
    let fixture = ShellSignalFixture()
    let bridge = AppShellSessionBridge()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = try await bridge.createBinding(
      vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", directory: directory,
      title: "Sample", windowSize: "1024x680")
    let old = try await bridge.begin(session: fixture.session, bindingID: binding.id)
    let current = try await bridge.begin(session: fixture.session, bindingID: binding.id)
    try await bridge.consume(
      fixture.data(), session: fixture.session, challenge: fixture.challenge, generation: current)
    await bridge.finish(generation: old)
    XCTAssertEqual(try state(binding.stateURL), "game_foreground")
    do {
      try await bridge.consume(fixture.data(), session: fixture.session, challenge: fixture.challenge, generation: old)
      XCTFail("A late observer must never write to a newer session")
    } catch is CancellationError {}
    XCTAssertEqual(try state(binding.stateURL), "game_foreground")
    await bridge.finish(generation: current)
    XCTAssertEqual(try state(binding.stateURL), "installer")
  }

  func testNewBindingCompactsPreviousFileAndRejectsItsToken() async throws {
    let fixture = ShellSignalFixture()
    let bridge = AppShellSessionBridge()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = try await bridge.createBinding(
      vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", directory: directory,
      title: "Sample", windowSize: "1024x680")
    let generation = try await bridge.begin(session: fixture.session, bindingID: old.id)
    try await bridge.consume(
      fixture.data(), session: fixture.session, challenge: fixture.challenge, generation: generation)
    _ = try await bridge.createBinding(
      vmIdentifier: fixture.session.vmIdentifier, helper: "/tmp/helper", directory: directory,
      title: "Sample", windowSize: "1024x680")
    XCTAssertEqual(try state(old.stateURL), "installer")
    do {
      _ = try await bridge.begin(session: fixture.session, bindingID: old.id)
      XCTFail("A previous lifecycle token must be rejected")
    } catch is GuestAppShellValidationError {}
  }

  func testObserverEvidenceComesFromInteractiveTaskAndIsBounded() {
    let fixture = ShellSignalFixture()
    let observer = GuestAppShellScripts.observer(for: fixture.session)
    XCTAssertTrue(observer.contains("GetForegroundWindow"))
    XCTAssertTrue(observer.contains("CreationDate"))
    XCTAssertTrue(observer.contains("ExecutablePath"))
    XCTAssertTrue(observer.contains("AddHours(12)"))
    XCTAssertTrue(observer.contains(fixture.session.id.uuidString))
    XCTAssertTrue(observer.contains("Move-Item -LiteralPath $temporary"))
    let read = GuestAppShellScripts.readEnvelope(for: fixture.session, challenge: fixture.challenge)
    XCTAssertTrue(read.contains(fixture.challenge))
    XCTAssertTrue(read.contains(fixture.session.signalPath))
    XCTAssertFalse(read.contains("GetForegroundWindow"))
    XCTAssertFalse(read.contains("Get-Process"))
  }

  func testObserverUploadPreservesUnicodeTargetInWindowsPowerShell() async throws {
    let uploads = ObserverScriptUploads()
    let session = GuestAppShellSession(
      vmIdentifier: UUID().uuidString, targetExecutable: #"C:\Games\示例\d3d11_probe.exe"#)
    let dispatcher = ContainerGuestDispatcher(
      controlBinaryPath: "/tmp/control", vmIdentifier: session.vmIdentifier,
      commandRunner: { _, arguments, environment in
        if arguments.first == "file", arguments.last == session.observerPath,
          let file = environment["__DEMOAPP_STDIN_FILE"] {
          await uploads.record(try Data(contentsOf: URL(filePath: file)))
        }
        return OrchestratorCommandResult(exitCode: 0, stdout: "")
      })
    try await dispatcher.submit(
      targetExecutable: session.targetExecutable, kioskScriptPath: "/tmp/kiosk.ps1", appShellSession: session)
    let data = await uploads.data()
    let uploaded = try XCTUnwrap(data)
    XCTAssertEqual(Array(uploaded.prefix(3)), [0xEF, 0xBB, 0xBF])
    let script = try XCTUnwrap(String(data: Data(uploaded.dropFirst(3)), encoding: .utf8))
    XCTAssertTrue(script.contains(session.targetExecutable))
    XCTAssertTrue(script.contains(session.id.uuidString))
  }

  private func state(_ url: URL) throws -> String? {
    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
    return payload?["state"]
  }
}

private actor ObserverScriptUploads {
  private var script: Data?
  func record(_ data: Data) { script = data }
  func data() -> Data? { script }
}
