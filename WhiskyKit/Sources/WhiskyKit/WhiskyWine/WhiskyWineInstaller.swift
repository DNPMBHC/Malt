//
//  WhiskyWineInstaller.swift
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
import SemanticVersion

public class WhiskyWineInstaller {
    /// The Whisky application folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: Bundle.whiskyBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    /// URL to the installed `DXVK` directory
    public static let dxvkFolder: URL = libraryFolder.appending(path: "DXVK")

    /// URL to the installed `DXMT` directory
    public static let dxmtFolder: URL = libraryFolder.appending(path: "DXMT")

    /// Returns the DXMT `wine` directory (containing `x86_64-windows` and `x86_64-unix`) when installed.
    public static func dxmtWineFolder(
        in libraryFolder: URL = WhiskyWineInstaller.libraryFolder,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = libraryFolder.appending(path: "DXMT")
        let wineDir = root.appending(path: "wine")
        let win64 = wineDir.appending(path: "x86_64-windows")
        let unix64 = wineDir.appending(path: "x86_64-unix")
        let hasStandard = fileManager.fileExists(atPath: win64.appending(path: "d3d11.dll").path(percentEncoded: false))
            && fileManager.fileExists(atPath: win64.appending(path: "dxgi.dll").path(percentEncoded: false))
            && fileManager.fileExists(atPath: unix64.appending(path: "winemetal.so").path(percentEncoded: false))
        if hasStandard {
            return wineDir
        }
        return nil
    }

    /// Returns the directory containing DXMT x86_64 Windows DLLs (`d3d11.dll`, `dxgi.dll`, etc.).
    public static func dxmtPEFolder(
        in dxmtFolder: URL = WhiskyWineInstaller.dxmtFolder,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            dxmtFolder.appending(path: "wine").appending(path: "x86_64-windows"),
            dxmtFolder.appending(path: "x64")
        ]
        for candidate in candidates {
            let probe = candidate.appending(path: "d3d11.dll").path(percentEncoded: false)
            if fileManager.fileExists(atPath: probe) {
                return candidate
            }
        }
        return nil
    }

    /// Probes which Wine DirectX translation backends are installed under the given library folder.
    public static func availableGraphicsBackends(
        fileManager: FileManager = .default,
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder
    ) -> HostAvailableWineBackends {
        let hasDXMT = dxmtWineFolder(in: libraryFolder, fileManager: fileManager) != nil
        let dxvkCandidates = [
            libraryFolder.appending(path: "DXVK/x64/d3d11.dll"),
            libraryFolder.appending(path: "DXVK/wine/x86_64-windows/d3d11.dll")
        ]
        let hasDXVK = dxvkCandidates.contains {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false))
        }
        let d3dMetalCandidates = [
            libraryFolder.appending(path: "Wine/lib/external/libd3dshared.dylib"),
            libraryFolder.appending(path: "GPTK/external/libd3dshared.dylib"),
            libraryFolder.appending(path: "Wine/lib/wine/x86_64-windows/d3d11.dll")
        ]
        let hasD3DMetal = d3dMetalCandidates.contains {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false))
        }
        return HostAvailableWineBackends(hasD3DMetal: hasD3DMetal, hasDXMT: hasDXMT, hasDXVK: hasDXVK)
    }

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    public static func install(from: URL) {
        do {
            if !FileManager.default.fileExists(atPath: applicationFolder.path) {
                try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            } else {
                // Recreate it
                try FileManager.default.removeItem(at: applicationFolder)
                try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            }

            try Tar.untar(tarBall: from, toURL: applicationFolder)
            try FileManager.default.removeItem(at: from)
        } catch {
            print("Failed to install WhiskyWine: \(error)")
        }
    }

    public static func uninstall() {
        do {
            try FileManager.default.removeItem(at: libraryFolder)
        } catch {
            print("Failed to uninstall WhiskyWine: \(error)")
        }
    }

    public static func shouldUpdateWhiskyWine() async -> (Bool, SemanticVersion) {
        let versionPlistURL = "https://data.getwhisky.app/Wine/WhiskyWineVersion.plist"
        let localVersion = whiskyWineVersion()

        var remoteVersion: SemanticVersion?

        if let remoteUrl = URL(string: versionPlistURL) {
            remoteVersion = await withCheckedContinuation { continuation in
                URLSession(configuration: .ephemeral).dataTask(with: URLRequest(url: remoteUrl)) { data, _, error in
                    do {
                        if error == nil, let data = data {
                            let decoder = PropertyListDecoder()
                            let remoteInfo = try decoder.decode(WhiskyWineVersion.self, from: data)
                            let remoteVersion = remoteInfo.version

                            continuation.resume(returning: remoteVersion)
                            return
                        }
                        if let error = error {
                            print(error)
                        }
                    } catch {
                        print(error)
                    }

                    continuation.resume(returning: nil)
                }.resume()
            }
        }

        if let localVersion = localVersion, let remoteVersion = remoteVersion {
            if localVersion < remoteVersion {
                return (true, remoteVersion)
            }
        }

        return (false, SemanticVersion(0, 0, 0))
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        do {
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WhiskyWineVersion.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

struct WhiskyWineVersion: Codable {
    var version: SemanticVersion = SemanticVersion(1, 0, 0)
}
