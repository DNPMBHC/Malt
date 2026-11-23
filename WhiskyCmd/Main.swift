//
//  Main.swift
//  WhiskyCmd
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import AppKit
import Dispatch
import Darwin
import WhiskyKit
import SwiftyTextTable
import Progress
import SemanticVersion
import ArgumentParser

@main
struct Whisky: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A CLI interface for Whisky.",
        discussion: RuntimeIntegrityReport.defaultBoundaryDisclosure,
        subcommands: [List.self,
                      Create.self,
                      Add.self,
                      Delete.self,
                      Remove.self,
                      Run.self,
                      LaunchShortcut.self,
                      StoragePreflight.self,
                      IntegrityReport.self,
                      Shellenv.self])
}

extension Whisky {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List existing bottles.")

        mutating func run() throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            let nameCol = TextTableColumn(header: "Name")
            let winVerCol = TextTableColumn(header: "Windows Version")
            let pathCol = TextTableColumn(header: "Path")

            var table = TextTable(columns: [nameCol, winVerCol, pathCol])
            for bottle in bottles {
                table.addRow(values: [bottle.settings.name,
                                      bottle.settings.windowsVersion.pretty(),
                                      bottle.url.prettyPath()])
            }

            print(table.render())
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new bottle.")

        @Argument var name: String

        mutating func run() throws {
            let bottleURL = BottleData.defaultBottleDir.appending(path: UUID().uuidString)

            do {
                try FileManager.default.createDirectory(atPath: bottleURL.path(percentEncoded: false),
                                                        withIntermediateDirectories: true)
                let bottle = Bottle(bottleUrl: bottleURL, inFlight: true)
                // Should allow customisation
                bottle.settings.windowsVersion = .win10
                bottle.settings.name = name
//                try await Wine.changeWinVersion(bottle: bottle, win: winVersion)
//                let wineVer = try await Wine.wineVersion()
                bottle.settings.wineVersion = SemanticVersion(0, 0, 0)

                var bottlesList = BottleData()
                bottlesList.paths.append(bottleURL)
                print("Created new bottle \"\(name)\".")
            } catch {
                throw ValidationError("\(error)")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an existing bottle.")

        @Argument var path: String

        mutating func run() throws {
            let input = URL(filePath: path).standardizedFileURL
            let bottleURL = input.lastPathComponent == "Metadata.plist" ? input.deletingLastPathComponent() : input
            let metadata = bottleURL.appending(path: "Metadata.plist")
            let settings = try BottleSettings.decode(from: metadata)
            var bottlesList = BottleData()
            bottlesList.paths.append(bottleURL)
            print("Bottle \"\(settings.name)\" added.")
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an existing bottle from disk.")

        @Argument var name: String

        mutating func run() throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            // Should ask for confirmation
            let bottleToRemove = bottles.first(where: { $0.settings.name == name })
            if let bottleToRemove = bottleToRemove {
                bottlesList.paths.removeAll(where: { $0 == bottleToRemove.url })
                do {
                    try FileManager.default.removeItem(at: bottleToRemove.url)
                    print("Deleted \"\(name)\".")
                } catch {
                    print(error)
                }
            } else {
                throw ValidationError("No bottle called \"\(name)\" found.")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an existing bottle from Whisky.",
                                                        discussion: "This will not remove the bottle from disk.")

        @Argument var name: String

        mutating func run() throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            let bottleToRemove = bottles.first(where: { $0.settings.name == name })
            if let bottleToRemove = bottleToRemove {
                bottlesList.paths.removeAll(where: { $0 == bottleToRemove.url })
                print("Removed \"\(name)\".")
            } else {
                throw ValidationError("No bottle called \"\(name)\" found.")
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: RuntimeCLI.localized("runtime.cli.run", fallback: "Run a Windows program."),
            discussion: RuntimeCLI.localized(
                "runtime.cli.discussion",
                fallback: "Use -- before program arguments to pass options and preserve their order. "
                    + "Leave them out to use the program’s saved arguments."
            )
        )

        @Flag(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.bottlePath", fallback: "Interpret the bottle argument as a path instead of a name."
        ))) var bottlePath = false

        @Flag(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.ignoreSavedArguments", fallback: "Use only the arguments given on the command line."
        ))) var ignoreSavedArguments = false

        @Option(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.profile", fallback: "Use auto, ordinary, or a compatibility profile identifier."
        ))) var profile: String?

        @Option(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.backend", fallback: "Use auto, wine, windowsGuest, or remotePhysics."
        ))) var backend: String?

        @Argument(help: ArgumentHelp(RuntimeCLI.localized("runtime.cli.bottle", fallback: "The bottle name or path.")))
        var bottle: String

        @Argument(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.path", fallback: "The path of the Windows program."
        )))
        var path: String

        @Argument(help: ArgumentHelp(RuntimeCLI.localized(
            "runtime.cli.arguments", fallback: "Arguments forwarded to the Windows program."
        )))
        var args: [String] = []

        mutating func run() async throws {
            do {
                let selectedBottle = try RuntimeCLI.findBottle(bottle, byPath: bottlePath)
                let arguments = args.isEmpty && !ignoreSavedArguments ? nil : args
                try await RuntimeCLI.launch(
                    path: path, bottle: selectedBottle, arguments: arguments, profile: profile, backend: backend
                )
            } catch {
                writeStandardError(RuntimeCLI.message(for: error))
                throw RuntimeCLI.exitCode(for: error)
            }
        }
    }

    struct LaunchShortcut: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "launch-shortcut", shouldDisplay: false)

        @Flag var showAlert = false
        @Argument var manifest: String
        @Argument var args: [String] = []

        mutating func run() async throws {
            do {
                let shortcut = try RuntimeCLI.Shortcut(contentsOf: URL(fileURLWithPath: manifest))
                let bottle = try RuntimeCLI.findBottle(shortcut.bottlePath, byPath: true)
                try await RuntimeCLI.launch(path: shortcut.programPath, bottle: bottle,
                                            arguments: args.isEmpty ? nil : args, profile: nil)
            } catch {
                let message = RuntimeCLI.message(for: error)
                writeStandardError(message)
                if showAlert && !(error is CancellationError) { await RuntimeCLI.showShortcutError(message) }
                throw RuntimeCLI.exitCode(for: error)
            }
        }
    }

    struct Shellenv: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prints export statements for a Bottle for eval.")

        @Argument var bottleName: String

        mutating func run() throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            guard let bottle = bottles.first(where: { $0.settings.name == bottleName }) else {
                throw ValidationError("A bottle with that name doesn't exist.")
            }

            let envCmd = Wine.generateTerminalEnvironmentCommand(bottle: bottle)
            print(envCmd)

        }
    }
}

enum RuntimeCLI {
    struct Shortcut: Decodable {
        let version: Int
        let bottlePath: String
        let programPath: String

        init(contentsOf url: URL) throws {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 else {
                    throw Failure.invalidShortcut
                }
                let data = try Data(contentsOf: url)
                guard data.count <= 64 * 1024 else { throw Failure.invalidShortcut }
                self = try PropertyListDecoder().decode(Self.self, from: data)
                guard version == 1, bottlePath.hasPrefix("/"), programPath.hasPrefix("/") else {
                    throw Failure.invalidShortcut
                }
            } catch {
                throw Failure.invalidShortcut
            }
        }
    }

    static func findBottle(_ reference: String, byPath: Bool, readOnly: Bool = false) throws -> Bottle {
        var bottleData = BottleData(readOnly: readOnly)
        let bottles = bottleData.loadBottles().filter(\.isAvailable)
        if byPath {
            let path = canonicalPath(URL(fileURLWithPath: reference))
            guard let bottle = bottles.first(where: { canonicalPath($0.url) == path }) else {
                throw Failure.bottleMissing
            }
            return bottle
        }
        let matching = bottles.filter { $0.settings.name == reference }
        guard let bottle = matching.first else { throw Failure.bottleMissing }
        guard Set(matching.map { canonicalPath($0.url) }).count == 1 else { throw Failure.bottleAmbiguous }
        return bottle
    }

    private static func canonicalPath(_ url: URL) -> [String] {
        Program.identity(for: url).pathComponents
    }

    static func launch(
        path: String, bottle: Bottle, arguments: [String]?, profile: String?, backend: String? = nil
    ) async throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let program = Program(url: url, bottle: bottle)
        let selection: RuntimeTargetSelection? = switch profile {
        case nil: nil
        case "auto": .automatic
        case "ordinary": .ordinary
        case .some(let profileID): .profile(profileID)
        }
        let resolvedBackend = try RuntimeCLI.parseBackend(backend)

        let previous = signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        let launchTask = Task {
            try await program.launchWithRuntime(arguments: arguments, selection: selection, backend: resolvedBackend)
        }
        source.setEventHandler { launchTask.cancel() }
        source.resume()
        defer {
            source.cancel()
            _ = signal(SIGINT, previous)
        }
        try await withTaskCancellationHandler {
            try await launchTask.value
        } onCancel: {
            launchTask.cancel()
        }
    }

    static func message(for error: Error) -> String {
        if error is CancellationError {
            return localized("runtime.cli.cancelled", fallback: "Launch cancelled.")
        }
        if let runtimeError = error as? RuntimeLaunchError {
            return runtimeError.description(in: localizationBundle)
        }
        return error.localizedDescription
    }

    static func exitCode(for error: Error) -> ExitCode {
        if error is CancellationError { return ExitCode(130) }
        if let runtimeError = error as? RuntimeLaunchError {
            switch runtimeError {
            case .processExit(let status) where (1...255).contains(status): return ExitCode(status)
            case .processSignal(let status) where (1...127).contains(status): return ExitCode(128 + status)
            default: break
            }
        }
        return .failure
    }

    private static var localizationBundle: Bundle {
        // A CLI executable in Contents/Resources does not have the enclosing app as Bundle.main.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let app = Bundle(url: executable.deletingLastPathComponent()
                                     .deletingLastPathComponent().deletingLastPathComponent()),
              app.bundleURL.pathExtension == "app" else { return .main }
        return app
    }

    static func localized(_ key: String, fallback: String) -> String {
        localizationBundle.localizedString(forKey: key, value: fallback, table: nil)
    }

    @MainActor
    static func showShortcutError(_ message: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = localized("runtime.errorTitle", fallback: "Unable to launch")
        alert.informativeText = message
        alert.addButton(withTitle: localized("button.ok", fallback: "OK"))
        alert.runModal()
    }

    enum Failure: LocalizedError {
        case bottleMissing, bottleAmbiguous, invalidShortcut

        var errorDescription: String? {
            switch self {
            case .bottleMissing:
                localized("runtime.cli.bottleMissing", fallback: "The selected bottle could not be found.")
            case .bottleAmbiguous:
                localized("runtime.cli.bottleAmbiguous",
                          fallback: "More than one bottle has this name. "
                              + "Use --bottle-path and give the bottle’s path.")
            case .invalidShortcut:
                localized("runtime.shortcut.invalidManifest",
                          fallback: "This shortcut is damaged or was created by a newer version. "
                              + "Re-create it from the main app.")
            }
        }
    }
}

func writeStandardError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}
