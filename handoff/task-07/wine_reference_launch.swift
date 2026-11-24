// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC
// Match the production Wine child process attributes without invoking the packaged CLI.

import Foundation
import CryptoKit

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { exit(64) }
if arguments.first == "--identity-digest" {
    guard arguments.count == 3 else { exit(64) }
    func canonical(_ value: String) -> URL {
        URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }
    let program = canonical(arguments[1])
    let bottle = canonical(arguments[2]).pathComponents
    let identity = program.pathComponents.starts(with: bottle)
        ? program.pathComponents.dropFirst(bottle.count).joined(separator: "/")
        : program.path(percentEncoded: false)
    print(SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined())
    exit(0)
}
let child = Process()
child.executableURL = URL(fileURLWithPath: arguments.removeFirst())
child.arguments = arguments
child.environment = ProcessInfo.processInfo.environment
child.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
child.qualityOfService = .userInitiated
child.standardOutput = FileHandle.standardOutput
child.standardError = FileHandle.standardError
do {
    try child.run()
    child.waitUntilExit()
    exit(child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("reference_wine_launch_failed\n".utf8))
    exit(70)
}
