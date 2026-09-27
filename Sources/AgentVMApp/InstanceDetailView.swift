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
        VStack(spacing: 0) {
            header
            Divider()

            switch tab {
            case .sessions: SessionsView(instance: instance)
            case .logs: LogsView(instance: instance)
            case .inspect: InspectView(instance: instance)
            }
        }
        .background(.background)
        // The controls live in the toolbar, which the system renders as
        // Liquid Glass floating over the content.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab.animation(.snappy)) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openSession(in: instance)
                } label: {
                    Label("New Session", systemImage: "terminal")
                }
                .disabled(!instance.isRunning)
                .hoverHint(instance.isRunning
                    ? "New Session (⌘T)\nOpen another shell in this instance."
                    : "New Session (⌘T)\nStart the instance to open a shell.")

                if instance.isRunning {
                    Button {
                        Task { await model.stop(instance) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .hoverHint("Stop\nShut the VM down. Its sessions end until you start it again.")
                } else {
                    Button {
                        Task { await model.start(instance) }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .hoverHint("Start\nBoot the VM again, with the network it was created with.")
                }

                Button {
                    model.editingPorts = instance
                } label: {
                    Label("Ports", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .hoverHint(instance.canEditPorts
                    ? "Ports (⌥⌘P)\nForward ports on this Mac into the instance."
                    : "Ports (⌥⌘P)\nSee forwarded ports. Stop the instance to change them.")
            }
            // A gap splits the destructive action into a glass capsule of its own.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    model.pendingDelete = instance
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .hoverHint("Delete\nRemove this instance. Your mounted folders are kept.")
            }
        }
        // A new session, from anywhere, is something you want to look at.
        .onChange(of: model.sessions[instance.fullName]?.count ?? 0) { old, new in
            if new > old { tab = .sessions }
        }
    }

    private var portsSummary: String {
        switch instance.ports.count {
        case 0: "none"
        case 1: instance.ports[0].shortDescription
        default: "\(instance.ports[0].shortDescription) +\(instance.ports.count - 1)"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(instance.shortName)
                    .font(.system(size: 22, weight: .semibold))
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        StatePill(state: instance.stateLabel)
                        if instance.net == .killswitch {
                            Label("killswitch", systemImage: "lock.shield.fill")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(.orange)
                                .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                                .help(NetPosture.killswitch.summary)
                        }
                    }
                }
                .animation(.bouncy, value: instance.stateLabel)
                Spacer()
            }

            HStack(spacing: 18) {
                Fact(label: "Image", value: instance.image)
                Fact(label: "Mode", value: instance.mode.rawValue, help: instance.lifetimeDescription)
                Fact(label: "Network", value: instance.net.label, help: instance.net.summary)
                Fact(label: "IP", value: instance.ipv4 ?? "—",
                     help: instance.ipv4 == nil ? "A stopped instance has no VM: no IP, no route, no resolver." : nil)
                Fact(label: "Ports", value: portsSummary, help: instance.ports.map(\.spec).joined(separator: "\n"))
                Fact(label: "Resources", value: "\(instance.cpus) CPU · \(instance.memoryDescription)")
            }
            .font(.callout)

            if model.staleEnvironment.contains(instance.fullName) {
                Label(
                    "The env registry changed after this instance was created — it keeps the environment baked in at creation.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

struct StatePill: View {
    let state: String

    var body: some View {
        HStack(spacing: 5) {
            StateDot(state: state)
            Text(state)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular.tint(tint), in: .capsule)
    }

    private var tint: Color? {
        switch state {
        case "running": .green.opacity(0.22)
        case "stopping": .orange.opacity(0.22)
        default: nil
        }
    }
}

struct Fact: View {
    let label: String
    let value: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .help(help ?? value)
    }
}
