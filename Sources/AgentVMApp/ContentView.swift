//
//  ContentView.swift
//  The window: instances on the left, the selected instance on the right.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingNewInstance: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(showingNewInstance: $showingNewInstance)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            Group {
                if model.showingDashboard {
                    DashboardScreen(monitor: model.resources, showingNewInstance: $showingNewInstance)
                } else if let instance = model.selectedInstance {
                    InstanceDetailView(instance: instance)
                } else {
                    EmptyStateView(showingNewInstance: $showingNewInstance)
                }
            }
        }
        .task {
            model.startPolling()
        }
        // Sampled while the window is open, so the dashboard opens onto
        // history rather than an empty chart.
        .onAppear { model.resources.begin(model) }
        .onDisappear { model.resources.end() }
        #if DEBUG
            .task {
                if let directory = UITour.directory { await UITour.run(model: model, in: directory) }
            }
        #endif
        .sheet(isPresented: $showingNewInstance) {
            NewInstanceSheet()
                .environmentObject(model)
        }
        .sheet(item: $model.editingPorts) { instance in
            PortsSheet(instance: instance)
                .environmentObject(model)
        }
        .sheet(item: $model.editingMainProcess) { instance in
            MainProcessSheet(instance: instance)
                .environmentObject(model)
        }
        .confirmationDialog(
            model.prunePlan.kept.isEmpty ? "Remove every AgentVM instance?" : "Remove every unlocked AgentVM instance?",
            isPresented: $model.showingPrune,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) { Task { await model.prune() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pruneMessage)
        }
        .confirmationDialog(
            "Delete \(model.pendingDelete?.shortName ?? "")?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingDelete
        ) { instance in
            Button("Delete", role: .destructive) {
                Task { await model.delete(instance, force: instance.isRunning) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text(
                instance.isRunning
                    ? "It is still running. Deleting stops it first, removes its killswitch network, and leaves your mounted directories alone."
                    : "Its VM is already gone. Deleting removes the container and its killswitch network; your mounted directories are left alone."
            )
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .overlay(alignment: .bottom) {
            if let busy = model.busy {
                BusyBar(text: busy)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .blurReplace))
            }
        }
        .animation(.bouncy(duration: 0.35), value: model.busy)
    }

    /// The rule, led by the locked instances it keeps, named.
    private var pruneMessage: String {
        let prefix = model.config.namePrefix
        let rule =
            "Containers without the prefix are never touched, and writable mounts are left alone."
        let kept = model.prunePlan.kept.map(model.config.shortName)
        guard !kept.isEmpty else {
            return "Every container named '\(prefix)…' is removed, along with its killswitch network. \(rule)"
        }
        let stays = kept.count == 1 ? "is locked, so it stays" : "are locked, so they stay"
        return "\(Self.listed(kept)) \(stays). Every other container named '\(prefix)…' is removed, along with its killswitch network. \(rule)"
    }

    /// "coder", "coder and web", "coder, web, and 3 more".
    static func listed(_ names: [String], limit: Int = 3) -> String {
        guard names.count > limit else { return names.formatted(.list(type: .and)) }
        let shown = Array(names.prefix(limit - 1))
        return (shown + ["\(names.count - shown.count) more"]).formatted(.list(type: .and))
    }
}

private struct BusyBar: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingNewInstance: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No Instance Selected", systemImage: "shippingbox")
        } description: {
            Text("A Linux VM with its own kernel, seeing only the folders you mount. It runs until you stop it.")
        } actions: {
            Button("New Instance…") { showingNewInstance = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.daemon?.running != true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
