// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum WineDPIConfigurationError: Error, Equatable, Sendable {
    case invalidDPI, readbackMismatch
}

/// Shared validation for registry writes and the display-settings editor.
public enum WineDPIConfigurationPolicy {
    public static let defaultDPI = 96
    public static let allowedRange = 96...480

    public static func validatedDPI(_ value: Int) throws -> Int {
        guard allowedRange.contains(value) else { throw WineDPIConfigurationError.invalidDPI }
        return value
    }

    public static func validatedDPI(_ value: Double) throws -> Int {
        guard value.isFinite, value.rounded() == value,
              value >= Double(allowedRange.lowerBound), value <= Double(allowedRange.upperBound),
              let integer = Int(exactly: value) else { throw WineDPIConfigurationError.invalidDPI }
        return integer
    }

    public static func loadedDPI(_ value: Int?) -> Int {
        (try? validatedDPI(value ?? defaultDPI)) ?? defaultDPI
    }
}
