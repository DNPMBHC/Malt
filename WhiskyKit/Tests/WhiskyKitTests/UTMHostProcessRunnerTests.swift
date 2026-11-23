// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest

@testable import WhiskyKit

final class UTMHostProcessRunnerTests: XCTestCase, @unchecked Sendable {
  private let python = URL(fileURLWithPath: "/usr/bin/python3")

  func testCapturesSeparateStreamsArgumentsAndFullExitCode() async throws {
    let result = try await UTMHostProcessRunner.run(
      executable: python,
      arguments: [
        "-c", "import sys;print(sys.argv[1]);print('error-output',file=sys.stderr);sys.exit(42)",
        "two words and \"quotes\" & $()"
      ], until: .now + .seconds(10))
    XCTAssertEqual(result.terminationReason, .exit)
    XCTAssertEqual(result.terminationStatus, 42)
    XCTAssertEqual(
      String(data: result.standardOutput, encoding: .utf8),
      "two words and \"quotes\" & $()\n")
    XCTAssertEqual(String(data: result.standardError, encoding: .utf8), "error-output\n")
    assertProcessAbsent(result.processIdentifier)
  }

  func testExpiredDeadlineDoesNotLaunchProcess() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("pid.txt")
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: python, arguments: sleepingArguments(marker), until: .now - .seconds(1))
      XCTFail("Expected expired deadline")
    } catch let error as UTMHostProcessError {
      XCTAssertEqual(error, .timedOut)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testDeadlineKillsAndReapsTheOwnedProcess() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("pid.txt")
    let started = ContinuousClock.now
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: python, arguments: sleepingArguments(marker), until: .now + .seconds(1))
      XCTFail("Expected host deadline")
    } catch let error as UTMHostProcessError {
      XCTAssertEqual(error, .timedOut)
    }
    XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    assertProcessAbsent(try readPID(marker))
  }

  func testTaskCancellationKillsAndReapsTheOwnedProcess() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("pid.txt")
    let arguments = sleepingArguments(marker)
    let python = python
    let task = Task {
      try await UTMHostProcessRunner.run(
        executable: python, arguments: arguments, until: .now + .seconds(30))
    }
    defer { task.cancel() }
    let deadline = ContinuousClock.now + .seconds(5)
    while (try? readPID(marker)) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let pid = try readPID(marker)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected task cancellation")
    } catch is CancellationError {
      assertProcessAbsent(pid)
    }
  }

  func testOutputLimitKillsAndReapsFloodingProcess() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("pid.txt")
    let script =
      "import os,sys,time;open(sys.argv[1],'w').write(str(os.getpid()));"
      + "os.write(1,b'x'*1000000);time.sleep(60)"
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: python, arguments: ["-c", script, marker.path],
        until: .now + .seconds(10), maximumOutputBytes: 64 * 1024)
      XCTFail("Expected bounded output failure")
    } catch let error as UTMHostProcessError {
      XCTAssertEqual(error, .outputLimitExceeded)
    }
    assertProcessAbsent(try readPID(marker))
  }

  func testLaunchFailureIsExplicit() async throws {
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: URL(fileURLWithPath: "/nonexistent/demo-app-helper"), arguments: [],
        until: .now + .seconds(1))
      XCTFail("Expected launch failure")
    } catch let error as UTMHostProcessError {
      XCTAssertEqual(error, .launchFailed)
    }
  }

  private func sleepingArguments(_ marker: URL) -> [String] {
    [
      "-c",
      "import os,sys,time;open(sys.argv[1],'w').write(str(os.getpid()));time.sleep(60)",
      marker.path
    ]
  }

  private func readPID(_ marker: URL) throws -> Int32 {
    let value = try String(contentsOf: marker, encoding: .utf8)
    return try XCTUnwrap(Int32(value), "Expected an owned process identifier")
  }

  private func assertProcessAbsent(
    _ pid: Int32, file: StaticString = #filePath, line: UInt = #line
  ) {
    errno = 0
    let status = Darwin.kill(pid, 0)
    let lastError = errno
    XCTAssertEqual(status, -1, "Owned process survived completion", file: file, line: line)
    XCTAssertEqual(lastError, ESRCH, "Owned process was not reaped", file: file, line: line)
  }

  private func fixtureDirectory() throws -> URL {
    var parent = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
      let evidence = parent.appendingPathComponent("handoff/phase-2/evidence/window-a/m0-swift")
      if FileManager.default.fileExists(atPath: evidence.path) {
        let directory = evidence.appendingPathComponent("host-process-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
      }
      parent.deleteLastPathComponent()
    }
    throw XCTSkip("The isolated host-process evidence directory is unavailable.")
  }
}
