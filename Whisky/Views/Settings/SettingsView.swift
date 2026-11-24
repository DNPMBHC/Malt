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
    @AppStorage("runtime.defaultMetalFXPreset") private var defaultMetalFXPreset = "off"
    @AppStorage("runtime.defaultMetalFXOutputHeight") private var defaultMetalFXOutputHeight = 1080
    @AppStorage("runtime.defaultPreferVulkanDriver") private var defaultPreferVulkanDriver = false
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
            Section("settings.graphics.defaults") {
                Picker("config.dxmt.metalFX.preset", selection: $defaultMetalFXPreset) {
                    ForEach(HostDXMTMetalFXPreset.allCases, id: \.self) { preset in
                        Text(String(localized: String.LocalizationValue(
                            "config.dxmt.metalFX.\(preset.rawValue)"
                        ))).tag(preset.rawValue)
                    }
                }
                Picker("config.dxmt.metalFX.outputHeight", selection: $defaultMetalFXOutputHeight) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("1440p").tag(1440)
                    Text("2160p").tag(2160)
                }
                Toggle("config.dxvk.preferKosmicKrisp", isOn: $defaultPreferVulkanDriver)
                Text("settings.graphics.defaults.note").font(.footnote).foregroundStyle(.secondary)
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
    @State private var baselineReport: UnifiedRuntimeBaselineReport?
    @AppStorage("runtime.defaultPreferVulkanDriver") private var defaultPreferVulkanDriver = false

    var body: some View {
        Section("settings.section.manifest") {
            if let report {
                if let sha = baselineReport?.runtimeManifestSHA256 {
                    LabeledContent("settings.manifest.fingerprint", value: String(sha.prefix(16)))
                        .font(.footnote)
                }
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
                let icdRoute = defaultICDRoute
                let icdLabel = icdRoute.selectedICD.map {
                    String(localized: String.LocalizationValue("config.dxvk.icd.\($0.rawValue)"))
                } ?? String(localized: "runtime.unavailable")
                LabeledContent("settings.vulkanICD.active", value: icdLabel)
                    .font(.footnote)
                Text(String(localized: String.LocalizationValue(icdRoute.reason)))
                    .font(.caption)
                    .foregroundStyle(icdRoute.usedFallback ? .orange : .secondary)
            } else {
                Text("settings.manifest.unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            goldenGuestRows
            guestSurfaceGateRows
            HStack {
                Spacer()
                Button("settings.manifest.recheck") { reload() }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: libraryFolder) { reload() }
    }

    @ViewBuilder
    private var goldenGuestRows: some View {
        let state = baselineReport?.goldenGuestState ?? .uninitialized
        let stateText = String(localized: String.LocalizationValue(state.localizationKey))
        LabeledContent("settings.goldenGuest.title", value: stateText)
            .font(.footnote)
        if let golden = baselineReport?.goldenGuestManifest {
            let idLabel = golden.status.map { "\(golden.guestID) (\($0))" } ?? golden.guestID
            LabeledContent("settings.goldenGuest.id", value: idLabel)
                .font(.caption)
            if let driver = golden.driverVersion {
                let driverText = golden.featureLevel.map { "\(driver) (FL \($0))" } ?? driver
                LabeledContent("settings.goldenGuest.driver", value: driverText)
                    .font(.caption)
            }
            if let optimizer = golden.optimizerProfileID {
                LabeledContent("settings.goldenGuest.optimizer", value: optimizer)
                    .font(.caption)
            }
            if let secPassed = golden.securityInvariantsPassed {
                let key = secPassed ? "settings.goldenGuest.security.passed" : "settings.goldenGuest.security.failed"
                LabeledContent("settings.goldenGuest.security", value: String(localized: String.LocalizationValue(key)))
                    .font(.caption)
            }
            if let sha = baselineReport?.goldenGuestManifestSHA256 {
                LabeledContent("settings.goldenGuest.fingerprint", value: String(sha.prefix(16))).font(.caption)
            }
        } else {
            Text(state == .invalid ? "settings.goldenGuest.invalidNote" : "settings.goldenGuest.uninitializedNote")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let compat = baselineReport?.compatibilitySummary {
            LabeledContent("settings.compatibility.targetSummary", value: "\(compat.targetID): \(compat.visualStage)")
                .font(.caption)
            let detail = "\(compat.rootCauseCode) | \(compat.mitigationStatus)"
                + " | Lobby: \(compat.protectedLobbyAndMatch)"
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        if let advisories = baselineReport?.advisoryLocalizationKeys, !advisories.isEmpty {
            ForEach(advisories, id: \.self) { key in
                Label(String(localized: String.LocalizationValue(key)), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let volumes = baselineReport?.externalVolumes, !volumes.isEmpty {
            ForEach(volumes) { volume in
                let free = ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .file)
                LabeledContent("settings.storage.externalTitle", value: "\(volume.volumeName) (\(free))").font(.caption)
            }
        }
    }

    @ViewBuilder
    private var guestSurfaceGateRows: some View {
        let gate = baselineReport?.guestSurfaceGate ?? .current
        let gateValue = gate.gameShellEntryEnabled
            ? String(localized: "runtime.on")
            : String(localized: "settings.guestSurfaceGate.controlledOff")
        LabeledContent(
            "settings.guestSurfaceGate.title",
            value: "\(gateValue) (Rev \(gate.contractRevision)/S\(gate.snapshotRevision))"
        )
        .font(.caption)
        Text("settings.guestSurfaceGate.note")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var defaultICDRoute: HostVulkanICDRoute {
        var settings = BottleSettings()
        settings.dxvkPreferKosmicKrisp = defaultPreferVulkanDriver
        return settings.resolveDXVKVulkanICDRoute(libraryFolder: libraryFolder)
    }

    private func reload() {
        let unified = UnifiedRuntimeBaselineReport.collect(libraryFolder: libraryFolder)
        baselineReport = unified
        report = unified.runtimeVerification
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

/// Reusable DXMT MetalFX Spatial preset picker and DXVK KosmicKrisp ICD toggle with live fallback visibility.
struct BottleGraphicsAdvancedOptionsView: View {
    @ObservedObject var bottle: Bottle
    let selectedBackend: HostWineGraphicsBackend?
    @State private var hostSnapshot = HostCapabilityProvider.current()

    var body: some View {
        let showDXMT = bottle.settings.wineGraphicsBackendMode == .dxmt
            || bottle.settings.wineGraphicsBackendMode == .auto
            || selectedBackend == .dxmt
        let showDXVK = bottle.settings.wineGraphicsBackendMode == .dxvk
            || bottle.settings.wineGraphicsBackendMode == .auto
            || selectedBackend == .dxvk

        if showDXMT {
            let fxPolicy = bottle.settings.resolveDXMTMetalFXPolicy(hostSnapshot: hostSnapshot)
            Picker("config.dxmt.metalFX.preset", selection: $bottle.settings.dxmtMetalFXPreset) {
                Text("config.dxmt.metalFX.off").tag(HostDXMTMetalFXPreset.off)
                Text("config.dxmt.metalFX.ultraQuality").tag(HostDXMTMetalFXPreset.ultraQuality)
                Text("config.dxmt.metalFX.quality").tag(HostDXMTMetalFXPreset.quality)
                Text("config.dxmt.metalFX.balanced").tag(HostDXMTMetalFXPreset.balanced)
                Text("config.dxmt.metalFX.performance").tag(HostDXMTMetalFXPreset.performance)
            }
            Picker("config.dxmt.metalFX.outputHeight", selection: $bottle.settings.dxmtMetalFXOutputHeight) {
                Text("720p").tag(720)
                Text("1080p").tag(1080)
                Text("1440p").tag(1440)
                Text("2160p").tag(2160)
            }
            LabeledContent("config.dxmt.metalFX.effective", value: String(localized: String.LocalizationValue(
                "config.dxmt.metalFX.\(fxPolicy.effectivePreset.rawValue)"
            )))
            Text("config.dxmt.metalFX.note")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .onReceive(NotificationCenter.default.publisher(
                    for: ProcessInfo.thermalStateDidChangeNotification
                )) { _ in hostSnapshot = HostCapabilityProvider.current() }
            if fxPolicy.fallbackReason != nil {
                Label(String(localized: String.LocalizationValue(
                    metalFXFallbackKey
                )), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }

        if showDXVK {
            let icdRoute = bottle.settings.resolveDXVKVulkanICDRoute()
            let icdLabel = icdRoute.selectedICD.map {
                String(localized: String.LocalizationValue("config.dxvk.icd.\($0.rawValue)"))
            } ?? String(localized: "runtime.unavailable")
            Toggle("config.dxvk.preferKosmicKrisp", isOn: $bottle.settings.dxvkPreferKosmicKrisp)
            LabeledContent("config.dxvk.icd.active", value: icdLabel)
            if icdRoute.usedFallback || icdRoute.selectedICD == nil {
                Label(
                    String(localized: String.LocalizationValue(icdRoute.reason)),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text(String(localized: String.LocalizationValue(icdRoute.reason)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metalFXFallbackKey: String {
        if !hostSnapshot.isAppleSilicon || !hostSnapshot.metalFXSpatialScalingAvailable {
            return "runtime.metalfx.reason.unsupported"
        }
        if hostSnapshot.performancePolicy != .maximumPerformance {
            return "runtime.metalfx.reason.pressure"
        }
        if bottle.settings.dxmtMetalFXOutputHeight < 1080 {
            return "runtime.metalfx.reason.lowResolution"
        }
        return "runtime.metalfx.reason.protected"
    }
}

#Preview {
    SettingsView()
}
