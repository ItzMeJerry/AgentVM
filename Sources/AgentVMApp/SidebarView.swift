//
//  SidebarView.swift
//  The instance list, plus the daemon's status at the bottom.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import AgentVMKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingNewInstance: Bool

    var body: some View {
        List(selection: $model.selection) {
            Section("Instances") {
                ForEach(model.instances) { instance in
                    InstanceRow(instance: instance)
                        .tag(instance.fullName)
                        // Two-finger swipes, as in Mail: left to delete,
                        // right to start or stop.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.pendingDelete = instance
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if instance.isRunning {
                                Button {
                                    Task { await model.stop(instance) }
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                }
                                .tint(.orange)
                            } else {
                                Button {
                                    Task { await model.start(instance) }
                                } label: {
                                    Label("Start", systemImage: "play.fill")
                                }
                                .tint(.green)
                            }
                        }
                }
                if model.instances.isEmpty {
                    Text(model.daemon?.running == true ? "Nothing running yet" : "Service not running")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first, let instance = model.instances.first(where: { $0.fullName == name }) {
                contextMenu(for: instance)
            }
        } primaryAction: { names in
            // Double-click (or Return): into a shell, starting it first if needed.
            guard let name = names.first,
                let instance = model.instances.first(where: { $0.fullName == name })
            else { return }
            if instance.isRunning {
                model.openSession(in: instance)
            } else {
                Task {
                    await model.start(instance)
                    if let started = model.instances.first(where: { $0.fullName == name }), started.isRunning {
                        model.openSession(in: started)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { DaemonStatusBar() }
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewInstance = true
                } label: {
                    Label("New Instance", systemImage: "plus")
                }
                .hoverHint("New Instance\nBoot a new Linux VM.")
                .disabled(model.daemon?.running != true)
            }
            ToolbarItem {
                Menu {
                    Button("Prune All AgentVM Instances…") { model.showingPrune = true }
                        .disabled(model.instances.isEmpty)
                    Button("Refresh Now") { Task { await model.refresh() } }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .hoverHint("More\nPrune all AgentVM instances, or refresh the list.")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for instance: AgentVMInstance) -> some View {
        Button("New Shell Session") { model.openSession(in: instance) }
            .disabled(!instance.isRunning)
        Divider()
        if instance.isRunning {
            Button("Stop") { Task { await model.stop(instance) } }
        } else {
            Button("Start") { Task { await model.start(instance) } }
        }
        Button(instance.canEditPorts ? "Edit Ports…" : "Ports…") { model.editingPorts = instance }
        Divider()
        Button("Copy IP Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(instance.ipv4 ?? "", forType: .string)
        }
        .disabled(instance.ipv4 == nil)
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(instance.fullName, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDelete = instance }
    }
}

struct InstanceRow: View {
    @EnvironmentObject private var model: AppModel
    let instance: AgentVMInstance

    var body: some View {
        HStack(spacing: 9) {
            StateDot(state: instance.stateLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.shortName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(instance.image)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if instance.net == .killswitch {
                        Label("killswitch", systemImage: "lock.shield")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .help("No DNS, no route off the host")
                    }
                    if model.staleEnvironment.contains(instance.fullName) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.yellow)
                            .help("The env registry changed since this instance was created")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(instance.mode == .instance ? "inst" : "task")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 3)
    }
}

struct StateDot: View {
    let state: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(state)
    }

    private var color: Color {
        switch state {
        case "running": .green
        case "stopping": .orange
        default: .secondary
        }
    }
}

struct DaemonStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.daemon?.running == true ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.daemon?.running == true ? "container service running" : "service not running")
                    .font(.caption.weight(.medium))
                if let version = model.daemon?.version {
                    Text("apiserver \(version) · XPC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("start it with `container system start`")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error = model.lastRefreshError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(error)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Floats over the list as a glass card, like the sidebar itself.
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(8)
        .animation(.bouncy, value: model.daemon?.running)
    }
}
