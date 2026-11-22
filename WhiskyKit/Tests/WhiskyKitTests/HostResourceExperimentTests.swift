// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import WhiskyKit

final class HostResourceExperimentTests: XCTestCase {
    func testMeasuredOptionalConsumerABAndFallback() throws {
        let report = HostResourceExperiment.run()
        XCTAssertEqual(report.rounds.count, 12)
        for round in report.rounds {
            XCTAssertEqual(round.samples.count, report.jobsPerRound)
            XCTAssertLessThanOrEqual(round.peakConcurrency, round.configuredConcurrency)
            XCTAssertGreaterThan(round.peakConcurrency, 0)
            XCTAssertGreaterThan(round.wallMilliseconds, 0)
            XCTAssertTrue(round.samples.allSatisfy { $0.checksum == report.expectedChecksum })
            if round.treatment == "serious" { XCTAssertEqual(round.peakConcurrency, 1) }
        }
        for pause in report.pauseObservations {
            XCTAssertEqual(pause.completedWhilePaused, 0)
            XCTAssertEqual(pause.completedAfterRecovery, 4)
            XCTAssertTrue(pause.baselineRestored)
        }
        if ProcessInfo.processInfo.environment["HOST_WRITE_RESOURCE_AB"] == "1" {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let output = package.appendingPathComponent("Documentation/HostResourceAB.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
        }
    }
}
