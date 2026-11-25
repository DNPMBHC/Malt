//
//  ContentView.swift
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
import SemanticVersion

@MainActor
final class FileOpenQueue: ObservableObject {
    static let shared = FileOpenQueue()
    @Published private(set) var pending: [URL] = []

    func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls.filter(\.isFileURL))
    }

    func takeFirst() -> URL? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

struct ContentView: View {
    @AppStorage("selectedBottleURL") private var selectedBottleURL: URL?
    @AppStorage("hasAcceptedComplianceDisclaimerV1") private var hasAcceptedDisclaimer: Bool = false
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var showSetup: Bool

    @ObservedObject private var fileQueue = FileOpenQueue.shared
    @StateObject private var launcher = RuntimeLaunchController()
    @StateObject private var libraryStore = UnifiedGameLibraryStore()
    @StateObject private var orchestrator: UnifiedRuntimeOrchestrator
    @StateObject private var preferences = UnifiedPreferencesModel()

    @State private var selectedSection: UnifiedSidebarSection? = .library
    @State private var selectedBottle: URL?
    @State private var showBottleCreation: Bool = false
    @State private var showComplianceDisclaimer: Bool = false
    @State private var showOnboarding: Bool = false
    @State private var bottlesLoaded: Bool = false
    @State private var newlyCreatedBottleURL: URL?
    @State private var openedFileURL: URL?
    @State private var refreshAnimation: Angle = .degrees(0)

    init(showSetup: Binding<Bool>) {
        self._showSetup = showSetup
        let store = UnifiedGameLibraryStore()
        _libraryStore = StateObject(wrappedValue: store)
        _orchestrator = StateObject(wrappedValue: UnifiedRuntimeOrchestrator(libraryStore: store))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Malt")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selectedSection = .install
                } label: {
                    Image(systemName: "plus")
                        .help("一键安装游戏")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    bottleVM.loadBottles()
                    libraryStore.load()
                    withAnimation(.default) {
                        refreshAnimation = .degrees(360)
                    } completion: {
                        refreshAnimation = .degrees(0)
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .help("button.refresh")
                        .rotationEffect(refreshAnimation)
                }
            }
        }
        .sheet(isPresented: $showBottleCreation, onDismiss: presentNextFile) {
            BottleCreationView(newlyCreatedBottleURL: $newlyCreatedBottleURL)
        }
        .sheet(isPresented: $showSetup, onDismiss: continueStartupFlow) {
            SetupView(showSetup: $showSetup, firstTime: false)
        }
        .sheet(isPresented: $showComplianceDisclaimer, onDismiss: continueStartupFlow) {
            ComplianceDisclaimerSheet(
                isPresented: $showComplianceDisclaimer,
                requireAcceptance: !hasAcceptedDisclaimer
            ) {
                hasAcceptedDisclaimer = true
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: presentNextFile) {
            FirstRunOnboardingView(
                orchestrator: orchestrator,
                preferences: preferences,
                isPresented: $showOnboarding,
                onOpenWineSetup: {
                    showOnboarding = false
                    showSetup = true
                }
            )
        }
        .sheet(item: $openedFileURL, onDismiss: presentNextFile) { url in
            FileOpenView(fileURL: url,
                         currentBottle: selectedBottle,
                         bottles: bottleVM.bottles,
                         launcher: launcher)
        }
        .runtimeLaunchFeedback($launcher.failure)
        .onChange(of: selectedBottle) {
            selectedBottleURL = selectedBottle
        }
        .onChange(of: newlyCreatedBottleURL) { _, url in
            selectedBottle = url
        }
        .onChange(of: fileQueue.pending) { presentNextFile() }
        .onChange(of: bottlesLoaded) { presentNextFile() }
        .task {
            bottleVM.loadBottles()
            libraryStore.load()
            bottlesLoaded = true

            if !bottleVM.bottles.isEmpty || bottleVM.countActive() != 0 {
                if let bottle = bottleVM.bottles.first(where: { $0.url == selectedBottleURL && $0.isAvailable }) {
                    selectedBottle = bottle.url
                } else {
                    selectedBottle = bottleVM.bottles[0].url
                }
            }

            continueStartupFlow()
            await checkWhiskyWineUpdateIfReady()
        }
    }

    private func continueStartupFlow() {
        if !hasAcceptedDisclaimer {
            showComplianceDisclaimer = true
            return
        }
        if !preferences.hasCompletedOnboarding {
            showOnboarding = true
            return
        }
        presentNextFile()
    }

    private func presentNextFile() {
        guard bottlesLoaded, !showSetup, !showBottleCreation,
              !showComplianceDisclaimer, !showOnboarding, openedFileURL == nil else { return }
        openedFileURL = fileQueue.takeFirst()
    }

    private func checkWhiskyWineUpdateIfReady() async {
        guard hasAcceptedDisclaimer, WhiskyWineInstaller.isWhiskyWineInstalled() else { return }
        let task = Task.detached {
            return await WhiskyWineInstaller.shouldUpdateWhiskyWine()
        }
        let updateInfo = await task.value
        if updateInfo.0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "update.whiskywine.title")
            alert.informativeText = String(format: String(localized: "update.whiskywine.description"),
                                           String(WhiskyWineInstaller.whiskyWineVersion()
                                                  ?? SemanticVersion(0, 0, 0)),
                                           String(updateInfo.1))
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "update.whiskywine.update"))
            alert.addButton(withTitle: String(localized: "button.removeAlert.cancel"))

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                WhiskyWineInstaller.uninstall()
                showSetup = true
            }
        }
    }

    var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Malt") {
                ForEach(UnifiedSidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
    }

    @ViewBuilder
    var detail: some View {
        switch selectedSection ?? .library {
        case .library:
            UnifiedGameLibraryView(
                libraryStore: libraryStore,
                orchestrator: orchestrator,
                onOpenInstaller: { selectedSection = .install }
            )
        case .install:
            UnifiedInstallerView(
                libraryStore: libraryStore,
                orchestrator: orchestrator,
                onInstallCompleted: { selectedSection = .library }
            )
        case .performance:
            UnifiedPerformanceView(preferences: preferences)
        case .runtimes:
            UnifiedRuntimeStorageView(
                orchestrator: orchestrator,
                preferences: preferences,
                launcher: launcher,
                onOpenSetup: { showSetup = true },
                onTriggerOnboarding: { showOnboarding = true },
                onCreateBottle: { showBottleCreation = true }
            )
        }
    }
}

#Preview {
    ContentView(showSetup: .constant(false))
        .environmentObject(BottleVM.shared)
}
