// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum RuntimeArguments {
    /// Parses the settings field without expansion, substitution, or shell execution.
    public static func parse(_ value: String) throws -> [String] {
        let characters = Array(value)
        var argument = ""
        var arguments: [String] = []
        var quote: Character?
        var started = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\", quote != "'" {
                if let escaped = try escapedCharacter(in: characters, at: index, quote: quote) {
                    argument.append(escaped)
                    index += 1
                } else {
                    argument.append(character)
                }
                started = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { argument.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { arguments.append(argument) }
                argument = ""
                started = false
            } else {
                argument.append(character)
                started = true
            }
        }
        guard quote == nil else { throw RuntimeLaunchError.issue(.unmatchedQuote) }
        if started { arguments.append(argument) }
        return arguments
    }

    private static func escapedCharacter(in characters: [Character], at index: Int,
                                         quote: Character?) throws -> Character? {
        guard index < characters.count else { throw RuntimeLaunchError.issue(.unfinishedEscape) }
        let next = characters[index]
        if next == "\\" || next == "\"" || (quote == nil && (next == "'" || next.isWhitespace)) {
            return next
        }
        return nil
    }

    /// Quotes one argv element for a command displayed and run by Terminal.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
