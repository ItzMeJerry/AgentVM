//
//  AgentVMApp.swift
//  AgentVM — disposable Linux VMs for running agents, on apple/container.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import AgentVMLayout
import SwiftUI

@main
struct AgentVMApplication: App {
    @State private var model = AppModel()
    @State private var showingNewInstance = false

    var body: some Scene {
        WindowGroup("AgentVM") {
            ContentView(showingNewInstance: $showingNewInstance)
                .environment(model)
                .frame(minWidth: 940, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Instance…", systemImage: "plus") { showingNewInstance = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Instance") {
                Button("New Shell Session", systemImage: "terminal") {
                    if let instance = model.selectedInstance { model.openSession(in: instance) }
                }
                .keyboardShortcut("t")
                .disabled(model.selectedInstance?.isRunning != true)

                Button("Next Session", systemImage: "chevron.forward") { model.selectAdjacentSession(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled((model.sessions[model.selection ?? ""]?.count ?? 0) < 2)
                Button("Previous Session", systemImage: "chevron.backward") { model.selectAdjacentSession(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled((model.sessions[model.selection ?? ""]?.count ?? 0) < 2)
                Button("Close Session", systemImage: "xmark") {
                    if let session = model.selectedSessionForCurrentInstance { model.closeSession(session) }
                }
                .disabled(model.selectedSessionForCurrentInstance == nil)

                Menu("Go to Session", systemImage: "number") {
                    ForEach(1..<10) { number in
                        Button(number == 9 ? "Last" : "Session \(number)") { model.selectSession(number: number) }
                            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    }
                }

                Menu("Layout", systemImage: "rectangle.split.2x2") {
                    // Worked out once, not once per template.
                    let current = model.selectedLayout?.matchingTemplate
                    ForEach(LayoutTemplate.allCases) { template in
                        Toggle(
                            template.title,
                            isOn: Binding(
                                get: { current == template },
                                set: { _ in model.applyTemplateToSelection(template) }))
                    }
                    Divider()
                    Toggle(
                        "Snap Dividers",
                        isOn: Binding(
                            get: { model.paneResizeMode == .snap },
                            set: { model.paneResizeMode = $0 ? .snap : .free }))
                    Button("Remove Pane from Split", systemImage: "rectangle") { model.removeFocusedPane() }
                        .disabled(model.selectedLayout?.isSplit != true)
                }
                .disabled(model.selectedLayout == nil)

                Divider()

                Button("Start", systemImage: "play.fill") {
                    if let instance = model.selectedInstance {
                        Task { await model.start(instance) }
                    }
                }
                .disabled(model.selectedInstance == nil || model.selectedInstance?.isRunning == true)

                Button("Stop", systemImage: "stop.fill") {
                    if let instance = model.selectedInstance {
                        Task { await model.stop(instance) }
                    }
                }
                .disabled(model.selectedInstance?.isRunning != true)

                Button("Ports…", systemImage: "point.3.connected.trianglepath.dotted") {
                    if let instance = model.selectedInstance { model.editingPorts = instance }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.selectedInstance == nil)

                Button("Main Process…", systemImage: "gearshape.2") {
                    if let instance = model.selectedInstance { model.editingMainProcess = instance }
                }
                .disabled(model.selectedInstance.map(\.isOneShot) ?? true)

                Divider()

                if let instance = model.selectedInstance, model.isLocked(instance) {
                    Button("Unlock", systemImage: "lock.open") { model.setLocked(false, instance) }
                } else {
                    Button("Lock", systemImage: "lock") {
                        if let instance = model.selectedInstance { model.setLocked(true, instance) }
                    }
                    .disabled(model.selectedInstance?.canLock != true)
                }

                Button("Delete…", systemImage: "trash") {
                    if let instance = model.selectedInstance { model.requestDelete(instance) }
                }
                .disabled(model.selectedInstance.map { model.isLocked($0) } ?? true)

                Divider()

                Button(model.pruneMenuTitle, systemImage: "xmark.bin") { model.showingPrune = true }
                    .disabled(model.prunePlan.containers.isEmpty)
            }
            CommandGroup(before: .toolbar) {
                Button("Dashboard", systemImage: "gauge.with.dots.needle.33percent") {
                    model.selection = AppModel.dashboardID
                }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                // As in Safari and Finder.
                Button("Back", systemImage: "chevron.backward") { model.closeDashboardPage() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.showingDashboard || model.dashboardInstance == nil)
                Divider()
                Button("Bigger Text", systemImage: "textformat.size.larger") {
                    model.setTerminalFontSize(model.terminalFontSize + 1)
                }
                    .keyboardShortcut("+")
                Button("Smaller Text", systemImage: "textformat.size.smaller") {
                    model.setTerminalFontSize(model.terminalFontSize - 1)
                }
                    .keyboardShortcut("-")
                Button("Actual Size", systemImage: "textformat.size") {
                    model.setTerminalFontSize(AgentVMTerminalView.defaultFontSize)
                }
                    .keyboardShortcut("0")
                Toggle("Sessions as Glass", isOn: $model.glassSessions)
                Divider()
            }
            HelpCommands()
        }

        Window("AgentVM Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environment(model)
        }
    }
}
