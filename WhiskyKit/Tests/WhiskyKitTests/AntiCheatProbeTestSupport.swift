// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import WhiskyKit

func makeAntiCheatPayload(
    schemaVersion: Any = 2,
    reportNonce: String? = nil,
    capturedAt: Int64 = 1_699_999_950,
    kernelArchitecture: String = "arm64",
    processArchitecture: String = "x64",
    candidateImageArchitecture: String = "arm64",
    loadedProbeArchitecture: String = "arm64",
    candidateImageAuthenticode: String = "trustedAuthenticode",
    loadState: String = "loaded",
    protocolVersion: Any = 2,
    observationScope: String = "selfProbe",
    requestorPID: Any = 100,
    observedPID: Any = 100,
    dispatchAttachedContextPID: Any = 100,
    requestorMatchesCurrentContext: Bool = true,
    sameProcessObject: Bool = true,
    deviceControlSucceeded: Bool = true,
    failureStage: String = "none",
    win32Error: UInt32 = 0,
    bytesReturned: UInt32 = 32,
    notificationAttempted: Bool = true,
    notificationCreateObserved: Bool = true,
    notificationExitObserved: Bool = true,
    notificationCleanupComplete: Bool = true,
    notificationChildPIDMatched: Bool = true,
    notificationBoundChildPID: UInt64 = 101
) -> Data {
    let object: [String: Any] = [
        "schemaVersion": schemaVersion,
        "nonce": reportNonce ?? String(repeating: "a", count: 64),
        "capturedAtUnixSeconds": capturedAt,
        "guest": [
            "kernelArchitecture": kernelArchitecture,
            "processArchitecture": processArchitecture,
            "windowsBuild": 26_100,
            "secureBoot": "unknown",
            "codeIntegrity": "unknown",
            "testSigning": "unknown",
            "kernelDebugger": "unknown",
            "memoryIntegrity": "unknown"
        ],
        "driver": [
            "candidateImageArchitecture": candidateImageArchitecture,
            "loadedProbeArchitecture": loadedProbeArchitecture,
            "candidateImageAuthenticode": candidateImageAuthenticode,
            "loadState": loadState,
            "protocolVersion": protocolVersion
        ],
        "observation": [
            "scope": observationScope,
            "requestorPID": requestorPID,
            "observedPID": observedPID,
            "dispatchAttachedContextPID": dispatchAttachedContextPID,
            "requestorMatchesCurrentContext": requestorMatchesCurrentContext,
            "sameProcessObject": sameProcessObject,
            "deviceControlSucceeded": deviceControlSucceeded,
            "failureStage": failureStage,
            "win32Error": win32Error,
            "bytesReturned": bytesReturned,
            "notification": [
                "attempted": notificationAttempted,
                "createObserved": notificationCreateObserved,
                "exitObserved": notificationExitObserved,
                "childCleanupComplete": notificationCleanupComplete,
                "childPIDMatched": notificationChildPIDMatched,
                "boundChildPID": notificationBoundChildPID
            ]
        ]
    ]
    return makeJSONData(object)
}

struct SelfProbeGuest: WindowsGuestProbeReporting {
    let reportFactory: @Sendable (String) -> Data

    var availability: WindowsGuestAvailability { .ready }

    init(reportFactory: @escaping @Sendable (String) -> Data) {
        self.reportFactory = reportFactory
    }

    func collectSelfProbeReport(nonce: String) async throws -> Data {
        reportFactory(nonce)
    }

    func launch(_ request: RuntimeLaunchRequest) async throws {}
}

enum SelfProbeFixtures {
    static func report(nonce: String, capturedAt: Int64) -> Data {
        makeJSONData([
            "schemaVersion": 2,
            "nonce": nonce,
            "capturedAtUnixSeconds": capturedAt,
            "guest": [
                "kernelArchitecture": "arm64",
                "processArchitecture": "arm64",
                "windowsBuild": 26_100,
                "secureBoot": "unknown",
                "codeIntegrity": "unknown",
                "testSigning": "unknown",
                "kernelDebugger": "unknown",
                "memoryIntegrity": "unknown"
            ],
            "driver": [
                "candidateImageArchitecture": "arm64",
                "loadedProbeArchitecture": "arm64",
                "candidateImageAuthenticode": "trustedAuthenticode",
                "loadState": "loaded",
                "protocolVersion": 2
            ],
            "observation": [
                "scope": "selfProbe",
                "requestorPID": 100,
                "observedPID": 100,
                "dispatchAttachedContextPID": 100,
                "requestorMatchesCurrentContext": true,
                "sameProcessObject": true,
                "deviceControlSucceeded": true,
                "failureStage": "none",
                "win32Error": 0,
                "bytesReturned": 32,
                "notification": [
                    "attempted": true,
                    "createObserved": true,
                    "exitObserved": true,
                    "childCleanupComplete": true,
                    "childPIDMatched": true,
                    "boundChildPID": 101
                ]
            ]
        ])
    }
}

private func makeJSONData(_ object: [String: Any]) -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    } catch {
        preconditionFailure("fixture JSON encoding failed: \(error)")
    }
}
