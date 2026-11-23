//
//  SettingsView.swift
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

import SwiftUI
import WhiskyKit

struct SettingsView: View {
    @AppStorage("SUEnableAutomaticChecks") var whiskyUpdate = true
    @AppStorage("killOnTerminate") var killOnTerminate = true
    @AppStorage("checkWhiskyWineUpdates") var checkWhiskyWineUpdates = true
    @AppStorage("defaultBottleLocation") var defaultBottleLocation = BottleData.defaultBottleDir
    @State private var runtimeFolder = WhiskyWineInstaller.applicationFolder
    @State private var externalVolumes = WhiskyWineInstaller.mountedExternalVolumes()
    @State private var runtimePathChanged = false

    var body: some View {
        Form {
            Section("settings.general") {
                Toggle("settings.toggle.kill.on.terminate", isOn: $killOnTerminate)
                ActionView(
                    text: "settings.path",
                    subtitle: storageSubtitle(for: defaultBottleLocation),
                    actionName: "create.browse"
                ) {
                    chooseDirectory(initial: defaultBottleLocation) { defaultBottleLocation = $0 }
                }
                ActionView(
                    text: "settings.runtimePath",
                    subtitle: storageSubtitle(for: runtimeFolder),
                    actionName: "create.browse"
                ) {
                    chooseDirectory(initial: runtimeFolder) { url in
                        WhiskyWineInstaller.setCustomRuntimeLocation(url)
                        runtimeFolder = WhiskyWineInstaller.applicationFolder
                        runtimePathChanged = true
                    }
                }
                externalVolumeQuickActions
                if runtimePathChanged {
                    Text("settings.runtimePath.restartNote")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section("settings.updates") {
                Toggle("settings.toggle.whisky.updates", isOn: $whiskyUpdate)
                Toggle("settings.toggle.whiskywine.updates", isOn: $checkWhiskyWineUpdates)
            }
            SettingsRuntimeManifestSection(libraryFolder: runtimeFolder.appending(path: "Libraries"))
            SettingsRuntimeAndComplianceSections()
        }
        .formStyle(.grouped)
        .frame(width: ViewWidth.large, height: 560)
        .onAppear {
            runtimeFolder = WhiskyWineInstaller.applicationFolder
            externalVolumes = WhiskyWineInstaller.mountedExternalVolumes()
        }
    }

    @ViewBuilder
    private var externalVolumeQuickActions: some View {
        if let preferred = externalVolumes.first {
            let freeText = ByteCountFormatter.string(fromByteCount: preferred.freeBytes, countStyle: .file)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.storage.externalTitle")
                        .font(.subheadline.weight(.medium))
                    Text("\(preferred.url.lastPathComponent) (\(freeText))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("settings.storage.useExternal") {
                    let base = preferred.url.appending(path: "WhiskyExternalData", directoryHint: .isDirectory)
                    defaultBottleLocation = base.appending(path: "Bottles", directoryHint: .isDirectory)
                    let runtimeDir = base.appending(path: "Runtime", directoryHint: .isDirectory)
                    WhiskyWineInstaller.setCustomRuntimeLocation(runtimeDir)
                    runtimeFolder = WhiskyWineInstaller.applicationFolder
                    runtimePathChanged = true
                }
            }
        }
        if WhiskyWineInstaller.isUsingCustomRuntimeLocation() {
            HStack {
                Spacer()
                Button("settings.runtimePath.resetDefault") {
                    WhiskyWineInstaller.setCustomRuntimeLocation(nil)
                    runtimeFolder = WhiskyWineInstaller.applicationFolder
                    runtimePathChanged = true
                }
            }
        }
    }

    private func storageSubtitle(for url: URL) -> String {
        let base = url.prettyPath()
        guard let bytes = WhiskyWineInstaller.availableCapacityBytes(for: url) else { return base }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(base) (\(String(format: String(localized: "settings.storage.freeFormat"), formatted)))"
    }

    private func chooseDirectory(initial: URL, onSelect: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = initial
        panel.begin { result in
            if result == .OK, let url = panel.urls.first {
                onSelect(url)
            }
        }
    }
}

struct SettingsRuntimeManifestSection: View {
    let libraryFolder: URL
    @State private var report: RuntimeManifestVerificationReport?

    var body: some View {
        Section("settings.section.manifest") {
            if let report {
                if report.hasMismatch {
                    Label("settings.manifest.mismatchWarning", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                ForEach(report.components) { item in
                    let stateText = String(localized: String.LocalizationValue(item.state.localizationKey))
                    LabeledContent("\(item.displayName) (\(item.lockedVersion))", value: stateText)
                        .font(.footnote)
                }
            } else {
                Text("settings.manifest.unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("settings.manifest.recheck") { reload() }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: libraryFolder) { reload() }
    }

    private func reload() {
        guard let manifest = try? RuntimeManifest.load() else {
            report = nil
            return
        }
        report = RuntimeManifestVerifier.verify(manifest: manifest, in: libraryFolder)
    }
}

/// Reusable non-silent fallback warning banner shown whenever graphics routing degrades or lacks engines.
struct GraphicsFallbackWarningBanner: View {
    let route: HostWineBackendRoute

    var body: some View {
        if route.usedFallback || route.selectedBackend == nil {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    route.selectedBackend == nil
                        ? "config.graphicsBackend.missingAlert.title"
                        : "config.graphicsBackend.fallbackAlert.title",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                Text(
                    route.selectedBackend == nil
                        ? "config.graphicsBackend.missingAlert.body"
                        : "config.graphicsBackend.fallbackAlert.body"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    SettingsView()
}
