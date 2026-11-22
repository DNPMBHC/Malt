//
//  ProgramShortcut.swift
//  Whisky
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
import QuickLookThumbnailing
import UniformTypeIdentifiers
import WhiskyKit

@MainActor
final class ProgramShortcut {
    static func createShortcut(_ program: Program, app: URL, name: String) async throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: app.path), !isSymbolicLink(app) else {
            throw ShortcutError.locationOccupied
        }

        try program.validateRuntimeLaunch()
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: app, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let stagedApp = staging.appending(path: app.lastPathComponent)
        try writeShortcut(program, app: stagedApp, name: name)
        let request = QLThumbnailGenerator.Request(fileAt: program.url,
                                                   size: CGSize(width: 512, height: 512),
                                                   scale: 2.0,
                                                   representationTypes: .thumbnail)
        if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            NSWorkspace.shared.setIcon(thumbnail.nsImage, forFile: stagedApp.path, options: [])
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: stagedApp, to: app)
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }

    static func chooseAndMigrate(_ program: Program) async throws {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "button.migrateShortcut")
        guard await panel.begin() == .OK, let app = panel.url else { return }
        try validateLegacyShortcut(app, program: program)

        let confirmation = NSAlert()
        confirmation.messageText = String(localized: "button.migrateShortcut")
        confirmation.informativeText = String(localized: "runtime.shortcut.migrateMessage")
        confirmation.addButton(withTitle: String(localized: "button.migrateShortcut"))
        confirmation.addButton(withTitle: String(localized: "create.cancel"))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        try Task.checkCancellation()
        try migrateLegacyShortcut(app, program: program)
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }

    private static func migrateLegacyShortcut(_ app: URL, program: Program) throws {
        try validateLegacyShortcut(app, program: program)
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: app, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let stagedApp = staging.appending(path: app.lastPathComponent)
        try writeShortcut(program, app: stagedApp, name: app.deletingPathExtension().lastPathComponent)
        let existingIcon = NSWorkspace.shared.icon(forFile: app.path)
        NSWorkspace.shared.setIcon(existingIcon, forFile: stagedApp.path, options: [])
        _ = try fileManager.replaceItemAt(
            app, withItemAt: stagedApp, backupItemName: nil, options: [.usingNewMetadataOnly]
        )
    }

    private static func writeShortcut(_ program: Program, app: URL, name: String) throws {
        guard let appIdentifier = Bundle.main.bundleIdentifier,
              let cli = Bundle.main.url(forResource: "WhiskyCmd", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw ShortcutError.runnerMissing
        }
        let contents = app.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let scriptURL = macOS.appending(path: "launch")
        let script = launcherScript(appIdentifier: appIdentifier, commandName: cli.lastPathComponent)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifest: [String: Any] = [
            "version": 1,
            "appBookmark": try Bundle.main.bundleURL.bookmarkData(options: .minimalBookmark),
            "bottlePath": program.bottle.url.standardizedFileURL.path(percentEncoded: false),
            "programPath": program.url.standardizedFileURL.path(percentEncoded: false)
        ]
        try writePlist(manifest, to: resources.appending(path: "Launch.plist"))
        let info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": appIdentifier + ".shortcut." + UUID().uuidString.lowercased(),
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "14.0",
            "LSApplicationCategoryType": "public.app-category.games"
        ]
        try writePlist(info, to: contents.appending(path: "Info.plist"))
    }

    private static func launcherScript(appIdentifier: String, commandName: String) -> String {
        let missing = String(localized: "runtime.shortcut.runnerMissing")
        return #"""
        #!/bin/sh
        manifest="${0%/*}/../Resources/Launch.plist"
        runner=$(/usr/bin/osascript -l JavaScript - \
            \#(shellWord(appIdentifier)) \#(shellWord(commandName)) "$manifest" <<'LOCATE_RUNNER'
        ObjC.import('AppKit');
        function runnerIn(app, identifier, command) {
            if (app.isNil()) return '';
            const bundle = $.NSBundle.bundleWithURL(app);
            if (bundle.isNil() || ObjC.unwrap(bundle.bundleIdentifier) !== identifier) return '';
            return ObjC.unwrap(bundle.resourceURL.URLByAppendingPathComponent(command).path) || '';
        }
        function run(argv) {
            const identifier = argv[0], command = argv[1];
            const manifest = $.NSDictionary.dictionaryWithContentsOfFile(argv[2]);
            if (!manifest.isNil()) {
                const data = manifest.objectForKey('appBookmark');
                if (!data.isNil()) {
                    const options = $.NSURLBookmarkResolutionWithoutUI | $.NSURLBookmarkResolutionWithoutMounting;
                    const app = $.NSURL.URLByResolvingBookmarkDataOptionsRelativeToURLBookmarkDataIsStaleError(
                        data, options, $(), Ref(), Ref());
                    const runner = runnerIn(app, identifier, command);
                    if (runner) return runner;
                }
            }
            const app = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier(identifier);
            return runnerIn(app, identifier, command);
        }
        LOCATE_RUNNER
        )
        if [ ! -x "$runner" ]; then
            message=\#(shellWord(missing))
            printf '%s\n' "$message" >&2
            /usr/bin/osascript -l JavaScript - "$message" <<'SHOW_ERROR'
        function run(argv) {
            const app = Application.currentApplication();
            app.includeStandardAdditions = true;
            app.displayAlert(argv[0]);
        }
        SHOW_ERROR
            exit 127
        fi
        exec "$runner" launch-shortcut --show-alert "$manifest" -- "$@"
        """# + "\n"
    }

    private static func validateLegacyShortcut(_ app: URL, program: Program) throws {
        let contents = app.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let scriptURL = macOS.appending(path: "launch")
        let infoURL = contents.appending(path: "Info.plist")
        let fileManager = FileManager.default
        let infoKeys: Set<String> = [
            "CFBundleExecutable", "CFBundleSupportedPlatforms", "LSMinimumSystemVersion", "LSApplicationCategoryType"
        ]
        guard app.pathExtension.lowercased() == "app",
              [app, contents, macOS, infoURL, scriptURL].allSatisfy({ !isSymbolicLink($0) }),
              let plist = try? readSmallFile(infoURL),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              Set(info.keys) == infoKeys,
              info["CFBundleExecutable"] as? String == "launch",
              info["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"],
              info["LSMinimumSystemVersion"] as? String == "14.0",
              info["LSApplicationCategoryType"] as? String == "public.app-category.games",
              fileManager.isExecutableFile(atPath: scriptURL.path),
              let scriptData = try? readSmallFile(scriptURL),
              let script = String(data: scriptData, encoding: .utf8),
              script.hasPrefix("#!/bin/bash\n"),
              let command = script.dropFirst("#!/bin/bash\n".count).split(separator: "\n").first else {
            throw ShortcutError.invalidLegacy
        }

        // Read the old shell text only as data and check the recorded program and bottle.
        let marker = " \(Wine.wineBinary.esc) start /unix \(program.url.esc)"
        let bottle = "WINEPREFIX=\"\(program.bottle.url.path)\" "
        guard let range = command.range(of: marker),
              range.upperBound == command.endIndex || command[range.upperBound] == " " else {
            throw ShortcutError.invalidLegacy
        }
        let environment = String(command[..<range.lowerBound]) + " "
        guard environment.hasPrefix(bottle) || environment.contains(" " + bottle) else {
            throw ShortcutError.invalidLegacy
        }
    }

    private static func readSmallFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 else {
            throw ShortcutError.invalidLegacy
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 else { throw ShortcutError.invalidLegacy }
        return data
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func writePlist(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: url, options: .atomic)
    }

    private static func shellWord(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum ShortcutError: LocalizedError {
        case runnerMissing, locationOccupied, invalidLegacy

        var errorDescription: String? {
            switch self {
            case .runnerMissing: String(localized: "runtime.shortcut.runnerMissing")
            case .locationOccupied: String(localized: "runtime.shortcut.locationOccupied")
            case .invalidLegacy: String(localized: "runtime.shortcut.invalidLegacy")
            }
        }
    }
}
