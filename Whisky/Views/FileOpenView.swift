//
//  FileOpenView.swift
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
import UniformTypeIdentifiers
import WhiskyKit

struct FileOpenView: View {
    var fileURL: URL
    var currentBottle: URL?
    var bottles: [Bottle]
    @ObservedObject var launcher: RuntimeLaunchController

    @State private var bottleURL: URL?
    @State private var program: Program?
    @State private var selection = RuntimeTargetSelection.automatic
    @State private var host: RuntimeHostSnapshot?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    private var availableBottles: [Bottle] { bottles.filter(\.isAvailable) }
    private var isLaunching: Bool { program.map(launcher.isLaunching) ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if availableBottles.isEmpty {
                    Text("runtime.noAvailableBottle")
                } else {
                    Picker("run.bottle", selection: $bottleURL) {
                        ForEach(availableBottles) {
                            Text($0.settings.name).tag(Optional($0.url))
                        }
                    }
                    .disabled(isLaunching)
                    RuntimeTargetPicker(selection: $selection)
                        .disabled(isLaunching)
                    if let host {
                        Section("runtime.section") {
                            let plan = RuntimeCoordinator().plan(for: fileURL, selection: selection, host: host)
                            RuntimeStatusRows(plan: plan)
                        }
                    }
                    if let program {
                        RuntimeStorageSection(program: program, selection: selection)
                            .disabled(isLaunching)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(format: String(localized: "run.title"), fileURL.lastPathComponent))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isLaunching {
                        Button("runtime.cancelLaunch") { if let program { launcher.cancel(program) } }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("create.cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isLaunching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("button.run") {
                            if let program {
                                launcher.launch(program, selection: selection, onSuccess: { dismiss() },
                                                onFailure: { failure = $0.localizedDescription })
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(program == nil)
                    }
                }
            }
        }
        .frame(width: ViewWidth.medium, height: 490)
        .interactiveDismissDisabled(isLaunching)
        .runtimeLaunchFeedback($failure)
        .task {
            bottleURL = availableBottles.first(where: { $0.url == currentBottle })?.url ?? availableBottles.first?.url
            host = .current()
        }
        .onChange(of: bottleURL, initial: true) {
            program = availableBottles.first(where: { $0.url == bottleURL }).map { Program(url: fileURL, bottle: $0) }
            selection = program?.runtimeSelection ?? .automatic
        }
    }
}

struct RuntimeStorageSection: View {
    private struct CheckInput: Equatable {
        let programURL: URL
        let bottleURL: URL
        let directory: URL?
        let selection: RuntimeTargetSelection
        let guestConfiguration: RuntimeGuestConfiguration?
    }

    private enum ImportKind {
        case directory
        case mapping

        var contentType: UTType { self == .directory ? .folder : .json }
    }

    @ObservedObject private var bottle: Bottle
    @State private var preflight: RuntimeStoragePreflight?
    @State private var importKind = ImportKind.directory
    @State private var showImporter = false
    @State private var showImportError = false
    private let program: Program
    private let selection: RuntimeTargetSelection

    init(program: Program, selection: RuntimeTargetSelection) {
        self.program = program
        self.selection = selection
        self.bottle = program.bottle
    }

    private var directory: URL? { bottle.settings.runtimeStorageDirectory }
    private var guestConfiguration: RuntimeGuestConfiguration? { bottle.settings.runtimeStorageGuestConfiguration }
    private var checkInput: CheckInput {
        CheckInput(programURL: program.url, bottleURL: bottle.url, directory: directory,
                   selection: selection, guestConfiguration: guestConfiguration)
    }

    var body: some View {
        Section("runtime.storage.section") {
            LabeledContent("runtime.storage.directory") {
                if let directory {
                    Text(directory.path(percentEncoded: false))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                } else {
                    Text("runtime.storage.noDirectory").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("runtime.storage.chooseDirectory") { select(.directory) }
                if directory != nil {
                    Button("runtime.storage.clearDirectory") { bottle.settings.runtimeStorageDirectory = nil }
                    Spacer()
                    Button("runtime.storage.refresh", action: refresh)
                }
            }
            Text("runtime.storage.directoryHelp")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if directory != nil {
                mappingControls
                if let preflight { storageRows(preflight) }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [importKind.contentType]) { result in
            do { try applyImport(result.get()) } catch { showImportError = true }
        }
        .alert(importErrorTitle, isPresented: $showImportError) {
            Button("button.ok", role: .cancel) { }
        } message: {
            if importKind == .directory {
                Text("runtime.storage.pickerErrorMessage")
            } else {
                Text("runtime.cli.storageGuestConfigInvalid")
            }
        }
        .onChange(of: checkInput, initial: true) { refresh() }
    }

    private var importErrorTitle: LocalizedStringKey {
        importKind == .directory ? "runtime.storage.pickerErrorTitle" : "runtime.storage.mappingErrorTitle"
    }

    private var mappingControls: some View {
        Group {
            LabeledContent("runtime.storage.mappingFile") {
                if guestConfiguration == nil {
                    Text("runtime.storage.mapping.notConfigured").foregroundStyle(.secondary)
                } else {
                    Text("runtime.storage.mappingLoaded")
                }
            }
            HStack {
                Button("runtime.storage.importMapping") { select(.mapping) }
                if guestConfiguration != nil {
                    Button("runtime.storage.clearMapping") { bottle.settings.runtimeStorageGuestConfiguration = nil }
                }
            }
            Text("runtime.storage.mappingHelp")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func select(_ kind: ImportKind) {
        importKind = kind
        showImporter = true
    }

    private func applyImport(_ url: URL) throws {
        switch importKind {
        case .directory:
            bottle.settings.runtimeStorageDirectory = url.standardizedFileURL
        case .mapping:
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let configuration = try JSONDecoder().decode(RuntimeGuestConfiguration.self, from: Data(contentsOf: url))
            bottle.settings.runtimeStorageGuestConfiguration = configuration
        }
    }

    private func storageRows(_ preflight: RuntimeStoragePreflight) -> some View {
        Group {
            LabeledContent("runtime.storage.check", value: localized(preflight.state.localizationKey))
            LabeledContent("runtime.storage.writability", value: localized(
                preflight.isWritable ? "runtime.storage.writable" : "runtime.storage.notWritable"
            ))
            LabeledContent("runtime.storage.availableBytes", value: formattedBytes(preflight.availableBytes))
            LabeledContent("runtime.storage.installerBytes", value: formattedBytes(preflight.installerBytes))
            LabeledContent("runtime.storage.requiredBytes", value: formattedBytes(preflight.requiredBytes))
            LabeledContent("runtime.storage.guestMapping", value: localized(preflight.guestMapping.localizationKey))
        }
    }

    private func refresh() {
        preflight = directory.map { program.runtimeStoragePreflight(selection: selection, targetDirectory: $0) }
    }

    private func formattedBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return localized("runtime.storage.unknownSize") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}
