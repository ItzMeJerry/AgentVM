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
                if let instance = model.selectedInstance {
                    InstanceDetailView(instance: instance)
                } else {
                    EmptyStateView(showingNewInstance: $showingNewInstance)
                }
            }
        }
        .task {
            model.startPolling()
        }
        .sheet(isPresented: $showingNewInstance) {
            NewInstanceSheet()
                .environmentObject(model)
        }
        .sheet(item: $model.editingPorts) { instance in
            PortsSheet(instance: instance)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Remove every AgentVM instance?",
            isPresented: $model.showingPrune,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) { Task { await model.prune() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every container named '\(model.config.namePrefix)…' is removed, along with its killswitch network. Containers without the prefix are never touched, and writable mounts are left alone."
            )
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
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No instance selected")
                .font(.title3.weight(.medium))
            Text(
                "An instance is a Linux VM with its own kernel. It sees only the directories you mount, and runs until you stop it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            Button("New Instance…") { showingNewInstance = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.daemon?.running != true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
