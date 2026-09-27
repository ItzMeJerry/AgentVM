//
//  InspectView.swift
//  What this instance can see and reach — the guarantees, made checkable.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

struct InspectView: View {
    @EnvironmentObject private var model: AppModel
    let instance: AgentVMInstance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Lifetime", systemImage: "clock.arrow.circlepath") {
                    Text(instance.lifetimeDescription)
                    LabeledContent("Main process", value: instance.command.joined(separator: " "))
                    LabeledContent("Created", value: instance.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let started = instance.startedAt {
                        LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                section("Network", systemImage: instance.net == .killswitch ? "lock.shield" : "globe") {
                    Text(instance.net.summary)
                    LabeledContent("Posture", value: "\(instance.net.label) — fixed at creation")
                    LabeledContent("Address", value: instance.ipv4 ?? "none while stopped")
                    if let networkName = instance.networkName {
                        LabeledContent("Dedicated network") {
                            HStack(spacing: 6) {
                                Text(networkName)
                                if !model.networkNames.contains(networkName) {
                                    Text("missing — recreated on start")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                section("Ports", systemImage: "point.3.connected.trianglepath.dotted") {
                    if instance.ports.isEmpty {
                        Text("No ports on this Mac forward into the guest.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(instance.ports) { port in
                            HStack(spacing: 8) {
                                Image(systemName: port.isLoopback ? "laptopcomputer" : "network")
                                    .foregroundStyle(port.isLoopback ? Color.secondary : Color.orange)
                                    .help(port.isLoopback ? "this Mac only" : "reachable from your network")
                                Text(port.spec)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                    HStack {
                        Text(instance.canEditPorts
                             ? "Read when the VM boots; changes apply on the next start."
                             : "Read when the VM boots. Stop the instance to change them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(instance.canEditPorts ? "Edit Ports…" : "Ports…") { model.editingPorts = instance }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }

                section("Mounts", systemImage: "externaldrive") {
                    if instance.mounts.isEmpty {
                        Text("No host directories are mounted: the guest sees only its own image.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(instance.mounts) { mount in
                            HStack(spacing: 8) {
                                Image(systemName: mount.readOnly ? "lock" : "pencil")
                                    .foregroundStyle(.secondary)
                                    .help(mount.readOnly ? "read-only" : "writable")
                                Text(mount.source)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(mount.destination)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                        }
                        Text("Nothing else on the host is reachable: apple/container grants no ambient access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Environment", systemImage: "key") {
                    if instance.envKeys.isEmpty {
                        Text("No variables were injected.").foregroundStyle(.secondary)
                    } else {
                        Text(instance.envKeys.sorted().joined(separator: "   "))
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Names only. Values were baked in at creation and are not read back here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Platform", systemImage: "cpu") {
                    LabeledContent("Architecture", value: instance.architecture)
                    LabeledContent("Rosetta", value: instance.rosetta ? "enabled" : "off")
                    LabeledContent("Container name", value: instance.fullName)
                    Text("One Linux kernel per instance, on Virtualization.framework — no kernel shared with the host or with other instances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func section(
        _ title: String, systemImage: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
