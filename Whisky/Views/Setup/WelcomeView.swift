//
//  WelcomeView.swift
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

struct WelcomeView: View {
    @State var rosettaInstalled: Bool?
    @State var whiskyWineInstalled: Bool?
    @State var shouldCheckInstallStatus: Bool = false
    @State private var runtimeFolder: URL = WhiskyWineInstaller.applicationFolder
    @State private var externalVolumes = WhiskyWineInstaller.mountedExternalVolumes()
    @Binding var path: [SetupStage]
    @Binding var showSetup: Bool
    var firstTime: Bool

    var body: some View {
        VStack {
            VStack {
                if firstTime {
                    Text("setup.welcome")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("setup.welcome.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("setup.title")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("setup.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            Spacer()
            Form {
                InstallStatusView(isInstalled: $rosettaInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "Rosetta")
                InstallStatusView(isInstalled: $whiskyWineInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  showUninstall: true,
                                  name: "WhiskyWine")
                runtimeStorageRow
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .onAppear {
                checkInstallStatus()
            }
            .onChange(of: shouldCheckInstallStatus) {
                checkInstallStatus()
            }
            Spacer()
            HStack {
                if let rosettaInstalled = rosettaInstalled,
                   let whiskyWineInstalled = whiskyWineInstalled {
                    if !rosettaInstalled || !whiskyWineInstalled {
                        Button("setup.quit") {
                            exit(0)
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    Button(rosettaInstalled && whiskyWineInstalled ? "setup.done" : "setup.next") {
                        if !rosettaInstalled {
                            path.append(.rosetta)
                            return
                        }

                        if !whiskyWineInstalled {
                            path.append(.whiskyWineDownload)
                            return
                        }

                        showSetup = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 440, height: 270)
    }

    @ViewBuilder
    private var runtimeStorageRow: some View {
        let freeText = WhiskyWineInstaller.availableCapacityBytes(for: runtimeFolder)
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.runtimePath")
                Text(freeText.isEmpty ? runtimeFolder.prettyPath() : "\(runtimeFolder.prettyPath()) (\(freeText))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let preferred = externalVolumes.first {
                Button("settings.storage.useExternal") {
                    let target = preferred.url
                        .appending(path: "WhiskyExternalData/Runtime", directoryHint: .isDirectory)
                    WhiskyWineInstaller.setCustomRuntimeLocation(target)
                    checkInstallStatus()
                }
            }
            Button("create.browse") { chooseRuntimeDirectory() }
        }
    }

    private func chooseRuntimeDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = runtimeFolder
        panel.begin { result in
            if result == .OK, let url = panel.urls.first {
                WhiskyWineInstaller.setCustomRuntimeLocation(url)
                checkInstallStatus()
            }
        }
    }

    func checkInstallStatus() {
        runtimeFolder = WhiskyWineInstaller.applicationFolder
        externalVolumes = WhiskyWineInstaller.mountedExternalVolumes()
        rosettaInstalled = Rosetta2.isRosettaInstalled
        whiskyWineInstalled = WhiskyWineInstaller.isWhiskyWineInstalled()
    }
}

struct InstallStatusView: View {
    @Binding var isInstalled: Bool?
    @Binding var shouldCheckInstallStatus: Bool
    @State var showUninstall: Bool = false
    @State var name: String
    @State var text: String = String(localized: "setup.install.checking")

    var body: some View {
        HStack {
            Group {
                if let installed = isInstalled {
                    Circle()
                        .foregroundColor(installed ? .green : .red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 10)
            Text(String.init(format: text, name))
            Spacer()
            if let installed = isInstalled {
                if installed && showUninstall {
                    Button("setup.uninstall") {
                        uninstall()
                    }
                }
            }
        }
        .onChange(of: isInstalled) {
            if let installed = isInstalled {
                if installed {
                    text = String(localized: "setup.install.installed")
                } else {
                    text = String(localized: "setup.install.notInstalled")
                }
            } else {
                text = String(localized: "setup.install.checking")
            }
        }
    }

    func uninstall() {
        if name == "WhiskyWine" {
            WhiskyWineInstaller.uninstall()
        }

        shouldCheckInstallStatus.toggle()
    }
}
