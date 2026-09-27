//
//  AgentVMApp.swift
//  AgentVM — disposable Linux VMs for running agents, on apple/container.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

@main
struct AgentVMApplication: App {
    @StateObject private var model = AppModel()
    @State private var showingNewInstance = false

    var body: some Scene {
        WindowGroup("AgentVM") {
            ContentView(showingNewInstance: $showingNewInstance)
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Instance…") { showingNewInstance = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Instance") {
                Button("New Shell Session") {
                    if let instance = model.selectedInstance { model.openSession(in: instance) }
                }
                .keyboardShortcut("t")
                .disabled(model.selectedInstance?.isRunning != true)

                Button("Next Session") { model.selectAdjacentSession(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled((model.sessions[model.selection ?? ""]?.count ?? 0) < 2)
                Button("Previous Session") { model.selectAdjacentSession(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled((model.sessions[model.selection ?? ""]?.count ?? 0) < 2)
                Button("Close Session") {
                    if let session = model.selectedSessionForCurrentInstance { model.closeSession(session) }
                }
                .disabled(model.selectedSessionForCurrentInstance == nil)

                Menu("Go to Session") {
                    ForEach(1..<10) { number in
                        Button(number == 9 ? "Last" : "Session \(number)") { model.selectSession(number: number) }
                            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    }
                }

                Divider()

                Button("Start") {
                    if let instance = model.selectedInstance {
                        Task { await model.start(instance) }
                    }
                }
                .disabled(model.selectedInstance == nil || model.selectedInstance?.isRunning == true)

                Button("Stop") {
                    if let instance = model.selectedInstance {
                        Task { await model.stop(instance) }
                    }
                }
                .disabled(model.selectedInstance?.isRunning != true)

                Button("Ports…") {
                    if let instance = model.selectedInstance { model.editingPorts = instance }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.selectedInstance == nil)

                Divider()

                Button("Delete…") {
                    if let instance = model.selectedInstance { model.pendingDelete = instance }
                }
                .disabled(model.selectedInstance == nil)

                Divider()

                Button("Prune All AgentVM Instances…") { model.showingPrune = true }
            }
            CommandGroup(before: .toolbar) {
                Button("Bigger Text") { model.setTerminalFontSize(model.terminalFontSize + 1) }
                    .keyboardShortcut("+")
                Button("Smaller Text") { model.setTerminalFontSize(model.terminalFontSize - 1) }
                    .keyboardShortcut("-")
                Button("Actual Size") { model.setTerminalFontSize(AgentVMTerminalView.defaultFontSize) }
                    .keyboardShortcut("0")
                Divider()
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
