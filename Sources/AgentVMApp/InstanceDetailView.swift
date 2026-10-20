//
//  InstanceDetailView.swift
//  One instance: what it is, what it can reach, and its shell sessions.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

struct InstanceDetailView: View {
    @EnvironmentObject private var model: AppModel
    let instance: AgentVMInstance

    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case logs = "Logs"
        case inspect = "Inspect"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .sessions

    var body: some View {
        Group {
            switch tab {
            case .sessions: SessionsView(instance: instance)
            case .logs: LogsView(instance: instance)
            case .inspect: InspectView(instance: instance)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // The window's own title says which instance this is and how it stands,
        // so the terminals get the space a header would take. Inspect has the
        // rest.
        .navigationTitle(instance.shortName)
        .navigationSubtitle(subtitle)
        // The controls live in the toolbar, which the system renders as
        // Liquid Glass floating over the content.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab.animation(.snappy)) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Its own width: a fixed one wider than the segments leaves the
                // toolbar's glass with empty space at both ends.
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openSession(in: instance)
                } label: {
                    Label("New Session", systemImage: "terminal")
                }
                .disabled(!instance.isRunning)
                .featureTip("New shell session")

                if instance.isRunning {
                    Button {
                        Task { await model.stop(instance) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .featureTip("Stop instance")
                } else {
                    Button {
                        Task { await model.start(instance) }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .featureTip("Start instance")
                }

                Button {
                    model.editingPorts = instance
                } label: {
                    Label("Ports", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .featureTip("Port forwarding")
            }
            // A gap gives the destructive action a glass capsule of its own,
            // shared with the lock that holds it off.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { locked }, set: { model.setLocked($0, instance) })) {
                    Label("Lock", systemImage: locked ? "lock.fill" : "lock.open")
                }
                .disabled(!locked && !instance.canLock)
                .featureTip(locked ? "Locked" : "Lock instance")

                Button(role: .destructive) {
                    model.requestDelete(instance)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(locked)
                .featureTip(locked ? "Locked: unlock it to delete it" : "Delete instance")
            }
        }
        // A new session, from anywhere, is something you want to look at.
        .onChange(of: model.sessions[instance.fullName]?.count ?? 0) { old, new in
            if new > old { tab = .sessions }
        }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: UITour.showTab)) { note in
                if let name = note.object as? String, let shown = Tab(rawValue: name) { tab = shown }
            }
        #endif
    }

    private var locked: Bool { model.isLocked(instance) }

    /// State, whether it's locked, posture when it's the killswitch, image,
    /// and address while there is one: what you'd otherwise look for in a
    /// header.
    private var subtitle: String {
        var parts = [instance.stateLabel]
        if locked { parts.append("locked") }
        if instance.net == .killswitch { parts.append("killswitch") }
        parts.append(instance.imageDisplayName)
        if let address = instance.ipv4 { parts.append(address) }
        return parts.joined(separator: " · ")
    }
}
