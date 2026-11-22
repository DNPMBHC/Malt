// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum GameCompatibilityDatabase {
    public static let profiles: [GameCompatibilityProfile] = [
        GameCompatibilityProfile(
            id: "riot-valorant",
            displayName: "VALORANT",
            executableNames: ["valorant.exe", "valorant-win64-shipping.exe"],
            antiCheat: .riotVanguard,
            wineCompatibility: .requiresWindowsKernel,
            windowsGuestCompatibility: .vendorRestricted,
            notes: "The Windows build depends on a kernel-level anti-cheat path. A guest must be supported by the"
                + " game vendor and configured as a real Windows environment."
        ),
        GameCompatibilityProfile(
            id: "riot-league-of-legends",
            displayName: "League of Legends",
            executableNames: ["leagueclient.exe", "leagueclientux.exe",
                              "leagueclientuxrender.exe", "league of legends.exe"],
            antiCheat: .riotVanguard,
            wineCompatibility: .requiresWindowsKernel,
            windowsGuestCompatibility: .vendorRestricted,
            notes: "This profile refers to the Windows client. The separate native macOS client is outside this"
                + " Windows runtime path."
        ),
        GameCompatibilityProfile(
            id: "embark-the-finals",
            displayName: "THE FINALS",
            executableNames: ["discovery.exe", "discovery-win64-shipping.exe", "thefinals.exe"],
            antiCheat: .easyAntiCheat,
            wineCompatibility: .vendorRestricted,
            windowsGuestCompatibility: .vendorRestricted,
            notes: "Easy Anti-Cheat support is controlled by the game publisher. The compatibility layer cannot"
                + " enable or emulate a vendor-side module."
        )
    ]

    /// Scripts and known front ends do not identify the application they will start.
    public static func requiresExplicitSelection(for executableURL: URL) -> Bool {
        let knownLaunchers: Set<String> = [
            "launcher", "launch", "start", "steam", "steamwebhelper", "riotclientservices", "epicgameslauncher",
            "battle.net", "upc", "eadesktop", "gog galaxy"
        ]
        return candidateURLs(for: executableURL).contains { candidate in
            let name = candidate.deletingPathExtension().lastPathComponent.lowercased()
            return ["bat", "cmd"].contains(candidate.pathExtension.lowercased()) || knownLaunchers.contains(name)
        }
    }

    public static func profile(for executableURL: URL) -> GameCompatibilityProfile? {
        for candidate in candidateURLs(for: executableURL) {
            if let profile = profiles.first(where: { $0.matches(executableURL: candidate) }) { return profile }
        }
        return nil
    }

    private static func candidateURLs(for url: URL) -> [URL] {
        guard url.isFileURL else { return [url] }
        let resolved = url.resolvingSymlinksInPath()
        return resolved.lastPathComponent == url.lastPathComponent ? [url] : [resolved, url]
    }
}
