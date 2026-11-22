// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct JSONKeyUniquenessScanner {
    private static let maximumNestingDepth = 64
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try scanValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw AntiCheatProbeReportError.invalidJSON }
    }

    private mutating func scanValue(depth: Int) throws {
        skipWhitespace()
        guard index < bytes.count else { throw AntiCheatProbeReportError.invalidJSON }
        guard depth <= Self.maximumNestingDepth else {
            throw AntiCheatProbeReportError.excessiveNesting
        }
        switch bytes[index] {
        case 123: try scanObject(depth: depth)
        case 91: try scanArray(depth: depth)
        case 34: _ = try scanString()
        default: scanPrimitive()
        }
    }

    private mutating func scanObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(125) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw AntiCheatProbeReportError.duplicateObjectKey
            }
            skipWhitespace()
            guard consume(58) else { throw AntiCheatProbeReportError.invalidJSON }
            try scanValue(depth: depth + 1)
            skipWhitespace()
            if consume(125) { return }
            guard consume(44) else { throw AntiCheatProbeReportError.invalidJSON }
        }
    }

    private mutating func scanArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(93) { return }
        while true {
            try scanValue(depth: depth + 1)
            skipWhitespace()
            if consume(93) { return }
            guard consume(44) else { throw AntiCheatProbeReportError.invalidJSON }
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        guard consume(34) else { throw AntiCheatProbeReportError.invalidJSON }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                let data = Data(bytes[start..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: data)
                } catch {
                    throw AntiCheatProbeReportError.invalidJSON
                }
            }
        }
        throw AntiCheatProbeReportError.invalidJSON
    }

    private mutating func scanPrimitive() {
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
