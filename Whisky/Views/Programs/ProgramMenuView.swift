//
//  ProgramMenuView.swift
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

struct ProgramMenuView: View {
    @ObservedObject var program: Program
    @Binding var path: NavigationPath
    @ObservedObject var launcher: RuntimeLaunchController

    var body: some View {
        if launcher.isLaunching(program) {
            Button("runtime.cancelLaunch", systemImage: "stop.circle") {
                launcher.cancel(program)
            }
        } else {
            Button("button.run", systemImage: "play") {
                launcher.launch(program)
            }
            Button("runtime.runInTerminal", systemImage: "terminal") {
                launcher.launch(program, inTerminal: true)
            }
        }
        Section("program.settings") {
            Button("program.config", systemImage: "gearshape") {
                path.append(program)
            }
            .labelStyle(.titleAndIcon)

            let buttonName = program.pinned
            ? String(localized: "button.unpin")
            : String(localized: "button.pin")

            Button(buttonName, systemImage: "pin") {
                program.pinned.toggle()
            }
            .labelStyle(.titleAndIcon)
            .symbolVariant(program.pinned ? .slash : .none)
        }
    }
}
