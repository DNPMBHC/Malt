//
//  ProgramView.swift
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
import UniformTypeIdentifiers

struct ProgramView: View {
    @ObservedObject var program: Program
    @ObservedObject var launcher: RuntimeLaunchController
    @State var cachedIconImage: Image?
    @State private var runtimePlan: RuntimePlan?
    @State private var shortcutWorking = false
    @AppStorage("configSectionExapnded") private var configSectionExpanded: Bool = true
    @AppStorage("envArgsSectionExpanded") private var envArgsSectionExpanded: Bool = true

    var body: some View {
        Form {
            Section("program.config", isExpanded: $configSectionExpanded) {
                Picker("locale.title", selection: $program.settings.locale) {
                    ForEach(Locales.allCases, id: \.self) { locale in
                        Text(locale.pretty()).id(locale)
                    }
                }
                VStack {
                    HStack {
                        Text("program.args")
                        Spacer()
                    }
                    TextField("program.args", text: $program.settings.arguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                    Text("runtime.args.help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                RuntimeTargetPicker(selection: Binding(
                    get: { program.runtimeSelection },
                    set: { program.settings.launchTarget = $0 == .automatic ? nil : $0 }
                ))
                Picker("runtime.backend", selection: Binding<RuntimeBackendKind?>(
                    get: { program.runtimeBackend },
                    set: { program.settings.preferredBackend = $0 }
                )) {
                    Text("runtime.target.automatic").tag(RuntimeBackendKind?.none)
                    ForEach(RuntimeBackendKind.allCases, id: \.self) { kind in
                        Text(localized(kind.localizationKey)).tag(Optional(kind))
                    }
                }
            }
            if let runtimePlan {
                Section("runtime.section") {
                    KernelAntiCheatComplianceBanner(plan: runtimePlan)
                    RuntimeStatusRows(plan: runtimePlan)
                    if runtimePlan.preferredBackend == .wine {
                        let route = runtimePlan.wineGraphicsRoute(for: program.bottle.settings)
                        let selectedLabel = route.selectedBackend.map {
                            localized("config.graphicsBackend.mode.\($0.rawValue)")
                        } ?? localized("runtime.unavailable")
                        LabeledContent("config.graphicsBackend.selected", value: selectedLabel)
                        LabeledContent("config.graphicsBackend.fallback",
                                       value: localized(route.usedFallback ? "runtime.on" : "runtime.off"))
                        GraphicsFallbackWarningBanner(route: route)
                        Text(route.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    let host = runtimePlan.host
                    let spatial = host.metalFXSpatialScalingAvailable ? "runtime.available" : "runtime.unavailable"
                    let temporal = host.metalFXTemporalScalingAvailable ? "runtime.available" : "runtime.unavailable"
                    let gameMode = host.gameModePlatformAvailable ? "runtime.platformAvailable"
                        : "runtime.platformUnavailable"
                    LabeledContent("runtime.performancePolicy",
                                   value: localized(host.performancePolicy.localizationKey))
                    LabeledContent("runtime.thermalState", value: localized(host.thermalState.localizationKey))
                    LabeledContent("runtime.lowPowerMode",
                                   value: localized(host.isLowPowerModeEnabled ? "runtime.on" : "runtime.off"))
                    LabeledContent("runtime.metalDevice",
                                   value: host.metalDeviceName ?? localized("runtime.unavailable"))
                    LabeledContent("runtime.metalFXSpatial", value: localized(spatial))
                    LabeledContent("runtime.metalFXTemporal", value: localized(temporal))
                    Text("runtime.graphicsPipelineNote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("runtime.gameMode", value: localized(gameMode))
                    LabeledContent("runtime.macOSVersion", value: host.operatingSystemVersion.title)
                    if runtimePlan.host.isMacOS27OrLater {
                        Text("runtime.macOS27Note")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("runtime.gameModeNote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            RuntimeStorageSection(program: program, selection: program.runtimeSelection)
                .disabled(launcher.isLaunching(program))
            EnvironmentArgView(program: program, isExpanded: $envArgsSectionExpanded)
        }
        .bottomBar {
            HStack {
                Spacer()
                Button("button.showInFinder") {
                    NSWorkspace.shared.activateFileViewerSelecting([program.url])
                }
                Menu("runtime.shortcutActions") {
                    Button("button.createShortcut", action: createShortcut)
                    Button("button.migrateShortcut") {
                        handleShortcut { try await ProgramShortcut.chooseAndMigrate(program) }
                    }
                }
                .disabled(shortcutWorking)
                if launcher.isLaunching(program) {
                    Button("runtime.cancelLaunch") { launcher.cancel(program) }
                    ProgressView().controlSize(.small)
                } else {
                    Button("button.run") { launcher.launch(program) }
                        .help("runtime.shiftTerminalHelp")
                }
            }
            .padding()
        }
        .toolbar {
            if let image = cachedIconImage {
                ToolbarItem(id: "ProgramViewIcon", placement: .navigation) {
                    image
                        .resizable()
                        .frame(width: 25, height: 25)
                        .padding(.trailing, 5)
                }
            } else {
                ToolbarItem(id: "ProgramViewIcon", placement: .navigation) {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: 25, height: 25)
                        .padding(.trailing, 5)
                }
            }
        }
        .navigationTitle(program.name)
        .formStyle(.grouped)
        .animation(.whiskyDefault, value: configSectionExpanded)
        .animation(.whiskyDefault, value: envArgsSectionExpanded)
        .task {
            if let fetchedImage = program.peFile?.bestIcon() { self.cachedIconImage = Image(nsImage: fetchedImage) }
        }
        .task(id: program.url) {
            refreshRuntimePlan()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            refreshRuntimePlan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            refreshRuntimePlan()
        }
        .onChange(of: program.runtimeSelection) { refreshRuntimePlan() }
        .onChange(of: program.runtimeBackend) { refreshRuntimePlan() }
        .onChange(of: program.bottle.settings.remotePhysicsConfiguration) { refreshRuntimePlan() }
    }

    private func createShortcut() {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = true
        panel.nameFieldStringValue = program.url.deletingPathExtension().lastPathComponent + ".app"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            handleShortcut {
                try await ProgramShortcut.createShortcut(program, app: url,
                                                        name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func handleShortcut(_ operation: @escaping @MainActor () async throws -> Void) {
        shortcutWorking = true
        Task(priority: .userInitiated) {
            defer { shortcutWorking = false }
            do { try await operation() } catch { launcher.present(error) }
        }
    }

    private func refreshRuntimePlan() {
        let coordinator = program.runtimeCoordinator()
        let url = program.url
        let selection = program.runtimeSelection
        let backend = program.runtimeBackend
        runtimePlan = coordinator.plan(for: url, selection: selection, backend: backend)
        guard backend == .remotePhysics else { return }
        Task {
            runtimePlan = await coordinator.resolvePlan(for: url, selection: selection, backend: backend)
        }
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

struct RuntimeTargetPicker: View {
    @Binding var selection: RuntimeTargetSelection

    var body: some View {
        Picker("runtime.targetProfile", selection: $selection) {
            Text("runtime.target.automatic").tag(RuntimeTargetSelection.automatic)
            Text("runtime.target.generic").tag(RuntimeTargetSelection.ordinary)
            ForEach(GameCompatibilityDatabase.profiles) { profile in
                Text(profile.displayName).tag(RuntimeTargetSelection.profile(profile.id))
            }
            if case .profile(let id) = selection, !GameCompatibilityDatabase.profiles.contains(where: { $0.id == id }) {
                Text("runtime.unavailable").tag(selection)
            }
        }
        Text("runtime.target.help")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct RuntimeStatusRows: View {
    let plan: RuntimePlan

    var body: some View {
        LabeledContent("runtime.backend", value: localized(plan.preferredBackend.localizationKey))
        LabeledContent("runtime.backendReadiness", value: localized(plan.capability.readiness.localizationKey))
        LabeledContent("runtime.kernelDiagnostics", value: localized(plan.capability.kernelDiagnostics.localizationKey))
        LabeledContent("runtime.vendorSupport", value: localized(plan.capability.vendorSupport.localizationKey))
        LabeledContent("runtime.gameVerification", value: localized(plan.capability.gameVerification.localizationKey))
        if let profile = plan.profile {
            LabeledContent("runtime.protection", value: localized(profile.antiCheat.localizationKey))
            Text(profile.localizedNotes())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(plan.capability.issues, id: \.self) { issue in
            Label(issue.localized(), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

@MainActor
final class RuntimeLaunchController: ObservableObject {
    private struct LaunchKey: Hashable {
        let programURL: URL
        let bottleURL: URL

        init(_ program: Program) {
            programURL = program.identityURL
            bottleURL = Program.identity(for: program.bottle.url)
        }
    }

    @Published private var tasks: [LaunchKey: Task<Void, Never>] = [:]
    @Published var failure: String?

    func isLaunching(_ program: Program) -> Bool {
        tasks[LaunchKey(program)] != nil
    }

    func launch(_ program: Program, selection: RuntimeTargetSelection? = nil,
                inTerminal: Bool = NSEvent.modifierFlags.contains(.shift),
                onSuccess: @escaping @MainActor () -> Void = {},
                onFailure: (@MainActor (Error) -> Void)? = nil) {
        start(LaunchKey(program), action: {
            if inTerminal {
                try Self.openTerminal(for: program, selection: selection)
            } else {
                try await program.launchWithRuntime(selection: selection)
            }
        }, onSuccess: onSuccess, onFailure: onFailure ?? present)
    }

    private static func openTerminal(for program: Program, selection: RuntimeTargetSelection?) throws {
        try program.validateRuntimeLaunch(selection: selection)
        guard let appExecutable = Bundle.main.executableURL?.lastPathComponent,
              let executableURL = Bundle.main.url(forResource: appExecutable + "Cmd", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)) else {
            throw RuntimeLaunchError.issue(.terminalUnavailable)
        }
        var arguments = [executableURL.path(percentEncoded: false), "run", "--bottle-path"]
        if let selection {
            arguments += ["--profile", selection.commandLineValue]
        }
        arguments += ["--", program.bottle.url.path(percentEncoded: false), program.url.path(percentEncoded: false)]
        let command = arguments
            .map(RuntimeArguments.quote)
            .joined(separator: " ")
        let literal = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\" & return & \"")
            .replacingOccurrences(of: "\n", with: "\" & linefeed & \"")
        let source = """
        tell application id "com.apple.Terminal"
            activate
            do script "\(literal)"
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw RuntimeLaunchError.issue(.terminalUnavailable) }
        script.executeAndReturnError(&error)
        guard error == nil else { throw RuntimeLaunchError.issue(.terminalUnavailable) }
    }

    private func start(
        _ key: LaunchKey,
        action: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard tasks[key] == nil else { return }
        tasks[key] = Task(priority: .userInitiated) {
            defer { tasks[key] = nil }
            do {
                try await action()
                try Task.checkCancellation()
                onSuccess()
            } catch {
                if !(error is CancellationError) && !Task.isCancelled {
                    onFailure(error)
                }
            }
        }
    }

    func cancel(_ program: Program) {
        tasks[LaunchKey(program)]?.cancel()
    }

    func present(_ error: Error) {
        failure = error.localizedDescription
    }
}

extension View {
    @MainActor
    func runtimeLaunchFeedback(_ failure: Binding<String?>) -> some View {
        alert("runtime.errorTitle", isPresented: Binding(
            get: { failure.wrappedValue != nil },
            set: { if !$0 { failure.wrappedValue = nil } }
        )) {
            Button("button.ok", role: .cancel) { }
        } message: {
            Text(failure.wrappedValue ?? "")
        }
    }
}
