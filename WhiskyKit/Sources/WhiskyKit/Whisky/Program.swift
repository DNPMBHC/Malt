//
//  Program.swift
//  WhiskyKit
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
import CryptoKit
import SwiftUI
import os.log

// swiftlint:disable:next todo
// TODO: Should not be unchecked!
public final class Program: ObservableObject, Equatable, Hashable, Identifiable, @unchecked Sendable {
    public let bottle: Bottle
    public let url: URL
    public let identityURL: URL
    public let settingsURL: URL

    public var name: String {
        url.lastPathComponent
    }

    @Published public var settings: ProgramSettings {
        didSet { saveSettings() }
    }

    @Published public var pinned: Bool {
        didSet {
            if pinned {
                let alreadyPinned = bottle.settings.pins.contains { $0.url.map(Self.identity(for:)) == identityURL }
                guard !alreadyPinned else { return }
                bottle.settings.pins.append(PinnedProgram(
                    name: name.replacingOccurrences(of: ".exe", with: ""),
                    url: url
                ))
            } else {
                bottle.settings.pins.removeAll(where: { $0.url.map(Self.identity(for:)) == identityURL })
            }
        }
    }

    public let peFile: PEFile?

    public init(url: URL, bottle: Bottle, loadSettingsOnly: Bool = false) {
        let name = url.lastPathComponent
        self.bottle = bottle
        self.url = url
        let identityURL = Self.identity(for: url)
        self.identityURL = identityURL
        self.pinned = bottle.settings.pins.contains(where: { $0.url.map(Self.identity(for:)) == identityURL })

        let settingsFolder = bottle.url.appending(path: "Program Settings")
        let programComponents = identityURL.pathComponents
        let bottleComponents = Self.identity(for: bottle.url).pathComponents
        let identity = programComponents.starts(with: bottleComponents)
            ? programComponents.dropFirst(bottleComponents.count).joined(separator: "/")
            : identityURL.path(percentEncoded: false)
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let settingsUrl = settingsFolder.appending(path: "v2-\(digest).plist")
        let legacySettingsURL = settingsFolder.appending(path: name).appendingPathExtension("plist")
        self.settingsURL = settingsUrl

        do {
            let settingsFolderPath = settingsFolder.path(percentEncoded: false)
            if !loadSettingsOnly && !FileManager.default.fileExists(atPath: settingsFolderPath) {
                try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
            }

            let hasSettings = FileManager.default.fileExists(atPath: settingsUrl.path(percentEncoded: false))
            if !hasSettings,
               FileManager.default.fileExists(atPath: legacySettingsURL.path(percentEncoded: false)) {
                var inherited = try ProgramSettings.decode(from: legacySettingsURL)
                inherited.launchTarget = nil
                self.settings = inherited
            } else if loadSettingsOnly && !hasSettings {
                self.settings = ProgramSettings()
            } else {
                self.settings = try ProgramSettings.decode(from: settingsUrl)
            }
        } catch {
            Logger.wineKit.error("Failed to load settings for `\(name)`: \(error)")
            self.settings = ProgramSettings()
        }

        do {
            self.peFile = loadSettingsOnly ? nil : try PEFile(url: url)
        } catch {
            self.peFile = nil
        }
    }

    public static func identity(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    public func generateEnvironment() -> [String: String] {
        var environment = settings.environment
        if settings.locale != .auto {
            environment["LC_ALL"] = settings.locale.rawValue
        }
        return environment
    }

    /// Save the settings to file
    private func saveSettings() {
        do {
            try settings.encode(to: settingsURL)
        } catch {
            Logger.wineKit.error("Failed to save settings for `\(self.name)`: \(error)")
        }
    }

    // MARK: - Equatable

    public static func == (lhs: Program, rhs: Program) -> Bool {
        return lhs.identityURL == rhs.identityURL
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        return hasher.combine(identityURL)
    }

    // MARK: - Identifiable

    public var id: URL {
        identityURL
    }
}
