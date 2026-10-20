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
            Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent")
                .tag(AppModel.dashboardID)
            Section("Instances") {
                ForEach(model.instances) { instance in
                    InstanceRow(instance: instance)
                        .tag(instance.fullName)
                        // Two-finger swipes, as in Mail: left to delete or
                        // lock, right to start or stop. A locked instance
                        // offers its unlock where Delete would be.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if model.isLocked(instance) {
                                Button {
                                    model.setLocked(false, instance)
                                } label: {
                                    Label("Unlock", systemImage: "lock.open")
                                }
                                .tint(.indigo)
                            } else {
                                Button(role: .destructive) {
                                    model.requestDelete(instance)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if instance.canLock {
                                    Button {
                                        model.setLocked(true, instance)
                                    } label: {
                                        Label("Lock", systemImage: "lock")
                                    }
                                    .tint(.indigo)
                                }
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
        // A bar of its own at the bottom of the sidebar: the list scrolls
        // under it behind the system's scroll edge effect, not a hard line.
        .safeAreaBar(edge: .bottom) { DaemonStatusBar() }
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewInstance = true
                } label: {
                    Label("New Instance", systemImage: "plus")
                }
                .featureTip("New instance")
                .disabled(model.daemon?.running != true)
            }
            ToolbarItem {
                Menu {
                    Button("Refresh Now", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    Divider()
                    Button(model.pruneMenuTitle, systemImage: "trash", role: .destructive) {
                        model.showingPrune = true
                    }
                    .disabled(model.prunePlan.containers.isEmpty)
                } label: {
                    // The glass is already the circle: no enclosed symbol.
                    Label("More", systemImage: "ellipsis")
                }
                .featureTip("More actions")
            }
        }
    }

    /// Led by what the leading swipe does, as Apple asks of a context menu,
    /// and ended by what the trailing swipe does.
    @ViewBuilder
    private func contextMenu(for instance: AgentVMInstance) -> some View {
        if instance.isRunning {
            Button("Stop", systemImage: "stop.fill") { Task { await model.stop(instance) } }
        } else {
            Button("Start", systemImage: "play.fill") { Task { await model.start(instance) } }
        }
        Button("New Shell Session", systemImage: "terminal") { model.openSession(in: instance) }
            .disabled(!instance.isRunning)
        Button(instance.canEditPorts ? "Edit Ports…" : "Ports…", systemImage: "point.3.connected.trianglepath.dotted") {
            model.editingPorts = instance
        }
        Button(
            instance.canChangeMainProcess ? "Edit Main Process…" : "Main Process…", systemImage: "gearshape.2"
        ) {
            model.editingMainProcess = instance
        }
        .disabled(instance.isOneShot)
        Divider()
        Button("Copy IP Address", systemImage: "network") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(instance.ipv4 ?? "", forType: .string)
        }
        .disabled(instance.ipv4 == nil)
        Button("Copy Name", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(instance.fullName, forType: .string)
        }
        Divider()
        if model.isLocked(instance) {
            Button("Unlock", systemImage: "lock.open") { model.setLocked(false, instance) }
        } else {
            Button("Lock", systemImage: "lock") { model.setLocked(true, instance) }
                .disabled(!instance.canLock)
        }
        Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDelete(instance) }
            .disabled(model.isLocked(instance))
    }
}

struct InstanceRow: View {
    @EnvironmentObject private var model: AppModel
    let instance: AgentVMInstance

    var body: some View {
        HStack(spacing: 9) {
            StateDot(state: instance.stateLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(instance.shortName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if model.isLocked(instance) {
                        LockBadge()
                    }
                }
                HStack(spacing: 5) {
                    Text(instance.imageDisplayName)
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
            // Instances are the usual kind; only the exception is marked.
            if instance.mode == .task {
                Text("task")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .help(instance.lifetimeDescription)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Marks a locked instance, beside its name.
struct LockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("Locked: Prune leaves it alone, and Delete waits until it's unlocked")
            .accessibilityLabel("Locked")
            .transition(.scale.combined(with: .opacity))
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

    private var running: Bool { model.daemon?.running == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(running ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(running ? "Container service \(model.daemon?.release ?? "")" : "Container service not running")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(model.daemon?.version.map { "\($0), over XPC" } ?? "")
            if !running {
                Text("Start it with container system start")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
            }
            ForEach([model.lastRefreshError, model.lockError].compactMap { $0 }, id: \.self) { error in
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.bouncy, value: running)
    }
}
