// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import WhiskyKit

/// Modal sheet displaying the four mandatory legal & anti-cheat compliance disclaimer clauses.
struct ComplianceDisclaimerSheet: View {
    @Binding var isPresented: Bool
    var requireAcceptance: Bool
    var onAccept: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("disclaimer.title")
                        .font(.headline)
                    Text("disclaimer.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    disclaimerClause(number: "1", titleKey: "disclaimer.clause1.title",
                                     bodyKey: "disclaimer.clause1.body")
                    disclaimerClause(number: "2", titleKey: "disclaimer.clause2.title",
                                     bodyKey: "disclaimer.clause2.body")
                    disclaimerClause(number: "3", titleKey: "disclaimer.clause3.title",
                                     bodyKey: "disclaimer.clause3.body")
                    disclaimerClause(number: "4", titleKey: "disclaimer.clause4.title",
                                     bodyKey: "disclaimer.clause4.body")
                    GroupBox {
                        Text("disclaimer.openSourceBoundary")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("disclaimer.openSourceBoundary.title", systemImage: "lock.shield")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            footerButtons
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .interactiveDismissDisabled(requireAcceptance)
    }

    private func disclaimerClause(
        number: String,
        titleKey: String.LocalizationValue,
        bodyKey: String.LocalizationValue
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number). \(String(localized: titleKey))")
                .font(.subheadline.weight(.semibold))
            Text(String(localized: bodyKey))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        HStack {
            if requireAcceptance {
                Button("disclaimer.declineQuit", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("disclaimer.acceptContinue") {
                    onAccept()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("button.ok") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Inline compliance warning banner shown in `ProgramView` when kernel anti-cheat or Windows Guest is selected.
struct KernelAntiCheatComplianceBanner: View {
    let plan: RuntimePlan
    @State private var showFullDisclaimer = false

    var shouldDisplay: Bool {
        if let profile = plan.profile, profile.antiCheat != .none {
            return true
        }
        return plan.preferredBackend == .windowsGuest
    }

    var body: some View {
        if shouldDisplay {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .symbolRenderingMode(.multicolor)
                    Text("runtime.complianceBanner.title")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("runtime.complianceBanner.detailsButton") {
                        showFullDisclaimer = true
                    }
                    .controlSize(.small)
                }
                Text("runtime.complianceBanner.body")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .sheet(isPresented: $showFullDisclaimer) {
                ComplianceDisclaimerSheet(isPresented: $showFullDisclaimer, requireAcceptance: false)
            }
        }
    }
}

/// Consolidated sections for `SettingsView`: three-engine runtime status, bundled compatibility matrix, and integrity.
struct SettingsRuntimeAndComplianceSections: View {
    @State private var enginesSummary = WhiskyWineInstaller.runtimeEnginesSummary()
    @State private var integrityReport = RuntimeIntegrityAttestor.currentReport()
    @State private var matrix: BundledCompatibilityMatrix? = try? BundledCompatibilityMatrix.load()
    @State private var showDisclaimerSheet = false

    var body: some View {
        Section("settings.section.engines") {
            enginesRows
        }
        Section("settings.section.compatibilityMatrix") {
            compatibilityMatrixRows
        }
        Section("settings.section.integrityAndDisclaimer") {
            integrityAndDisclaimerRows
        }
    }

    @ViewBuilder
    private var enginesRows: some View {
        LabeledContent(
            "settings.engines.rosetta",
            value: loc(enginesSummary.rosettaInstalled ? "runtime.available" : "runtime.unavailable")
        )
        let wineStatus = enginesSummary.whiskyWineVersionString
            ?? loc(enginesSummary.whiskyWineInstalled ? "runtime.available" : "runtime.unavailable")
        LabeledContent("settings.engines.whiskyWine", value: wineStatus)
        ForEach(enginesSummary.engines) { item in
            let stateText = loc(item.isInstalled ? "runtime.available" : "runtime.unavailable")
            LabeledContent(
                loc("config.graphicsBackend.mode.\(item.backend.rawValue)"),
                value: "\(stateText) (\(item.supportedAPIs))"
            )
        }
        LabeledContent(
            "settings.engines.route.dx11Perf",
            value: routeLabel(for: enginesSummary.defaultDX11PerformanceRoute)
        )
        LabeledContent(
            "settings.engines.route.dx11Compat",
            value: routeLabel(for: enginesSummary.defaultDX11CompatibilityRoute)
        )
        LabeledContent(
            "settings.engines.route.dx12",
            value: routeLabel(for: enginesSummary.defaultDX12Route)
        )
        HStack {
            Spacer()
            Button("settings.engines.refresh") {
                enginesSummary = WhiskyWineInstaller.runtimeEnginesSummary()
                integrityReport = RuntimeIntegrityAttestor.currentReport()
                matrix = try? BundledCompatibilityMatrix.load()
            }
        }
    }

    @ViewBuilder
    private var compatibilityMatrixRows: some View {
        if let matrix {
            LabeledContent("settings.matrix.snapshotID", value: matrix.sourceSnapshotID)
            LabeledContent(
                "settings.matrix.coverage",
                value: "\(matrix.sourceCount) / \(matrix.claimCount) / \(matrix.records.count)"
            )
            Text("settings.matrix.woaSplitNote")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(matrix.records) { record in
                let states = record.fiveDimensionStates
                let summary = "Perm: \(states.publisherPermission) | Sup: \(states.publisherSupport) | "
                    + "Drv: \(states.driverLoad) | Session: \(states.protectedSession)"
                LabeledContent("\(record.productName) (\(record.scopeID))", value: summary)
                    .font(.footnote)
            }
        } else {
            LabeledContent("settings.matrix.snapshotID", value: loc("runtime.unavailable"))
        }
    }

    @ViewBuilder
    private var integrityAndDisclaimerRows: some View {
        LabeledContent("integrity.sip.label", value: loc(integrityReport.sipStatus.localizationKey))
        LabeledContent(
            "integrity.signature.label",
            value: loc(integrityReport.codeSignatureState.localizationKey)
        )
        LabeledContent(
            "integrity.hardenedRuntime.label",
            value: loc(integrityReport.hardenedRuntimeEnabled ? "runtime.on" : "runtime.off")
        )
        LabeledContent(
            "integrity.host.label",
            value: loc(integrityReport.hostExecutionNature.localizationKey)
        )
        Text("disclaimer.openSourceBoundary")
            .font(.footnote)
            .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("settings.disclaimer.viewButton") {
                showDisclaimerSheet = true
            }
        }
        .sheet(isPresented: $showDisclaimerSheet) {
            ComplianceDisclaimerSheet(isPresented: $showDisclaimerSheet, requireAcceptance: false)
        }
    }

    private func routeLabel(for route: HostWineBackendRoute) -> String {
        guard let selected = route.selectedBackend else {
            return loc("runtime.unavailable")
        }
        let name = loc("config.graphicsBackend.mode.\(selected.rawValue)")
        if route.usedFallback {
            return "\(name) (\(loc("config.graphicsBackend.fallback")))"
        }
        return name
    }

    private func loc(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

struct BottleRemotePhysicsSection: View {
    @ObservedObject var bottle: Bottle
    @State private var hostText = ""
    @State private var portText = "47984"
    @State private var appNameText = ""
    @State private var transport: RemotePhysicsTransportKind = .moonlightClient
    @State private var clientPathText = ""
    @State private var statusText = ""
    @State private var isProbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("config.remotePhysics.host", text: $hostText)
            TextField("config.remotePhysics.port", text: $portText)
            TextField("config.remotePhysics.appName", text: $appNameText)
            Picker("config.remotePhysics.transport", selection: $transport) {
                Text("config.remotePhysics.transport.moonlight").tag(RemotePhysicsTransportKind.moonlightClient)
                Text("config.remotePhysics.transport.external").tag(RemotePhysicsTransportKind.externalClient)
            }
            TextField("config.remotePhysics.clientPath", text: $clientPathText)
            HStack {
                Button("config.remotePhysics.save") { saveConfiguration() }
                Button("config.remotePhysics.test") { probeAvailability() }
                    .disabled(isProbing || bottle.settings.remotePhysicsConfiguration == nil)
                if bottle.settings.remotePhysicsConfiguration != nil {
                    Button("config.remotePhysics.clear", role: .destructive) { clearConfiguration() }
                }
                if isProbing { ProgressView().controlSize(.small) }
            }
            if !statusText.isEmpty {
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: syncFromBottle)
    }

    private func syncFromBottle() {
        guard let config = bottle.settings.remotePhysicsConfiguration else { return }
        hostText = config.hostIdentifier
        portText = "\(config.controlPort)"
        appNameText = config.applicationName
        transport = config.transport
        clientPathText = config.clientExecutableURL?.path(percentEncoded: false) ?? ""
    }

    private func saveConfiguration() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            statusText = String(localized: "config.remotePhysics.invalidPort")
            return
        }
        let trimmedClient = clientPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientURL = trimmedClient.isEmpty ? nil : URL(fileURLWithPath: trimmedClient)
        let config = RemotePhysicsConfiguration(
            hostIdentifier: hostText.trimmingCharacters(in: .whitespacesAndNewlines),
            controlPort: port,
            transport: transport,
            applicationName: appNameText.trimmingCharacters(in: .whitespacesAndNewlines),
            clientExecutableURL: clientURL
        )
        do {
            try config.validate()
            bottle.settings.remotePhysicsConfiguration = config
            statusText = String(localized: "config.remotePhysics.saved")
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func clearConfiguration() {
        bottle.settings.remotePhysicsConfiguration = nil
        hostText = ""
        portText = "\(RemotePhysicsConfiguration.defaultControlPort)"
        appNameText = ""
        clientPathText = ""
        statusText = String(localized: "config.remotePhysics.cleared")
    }

    private func probeAvailability() {
        guard let config = bottle.settings.remotePhysicsConfiguration else { return }
        isProbing = true
        Task {
            let result = await ExternalClientRemotePhysicsProvider(configuration: config).checkAvailability()
            isProbing = false
            switch result {
            case .ready:
                statusText = String(localized: "runtime.readiness.ready")
            case .unconfigured:
                statusText = RuntimeIssue.remotePhysicsUnconfigured.localized()
            case .unverified:
                statusText = RuntimeIssue.remotePhysicsUnverified.localized()
            case .clientMissing(let detail):
                statusText = "\(RuntimeIssue.remotePhysicsClientMissing.localized()) (\(detail))"
            case .hostUnreachable(let detail):
                statusText = "\(RuntimeIssue.remotePhysicsHostUnreachable.localized()) (\(detail))"
            }
        }
    }
}
