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
        Form {
            Section {
                LabeledContent("Mode", value: instance.mode == .instance ? "Instance" : "Task")
                LabeledContent("Main process") {
                    Text(instance.command.joined(separator: " "))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Created", value: instance.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let started = instance.startedAt {
                    LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Lifetime")
            } footer: {
                Text(instance.lifetimeDescription)
            }

            Section {
                LabeledContent(
                    "Posture", value: instance.net == .killswitch ? "Killswitch, fixed at creation" : "Open, fixed at creation")
                LabeledContent("Address") {
                    Text(instance.ipv4 ?? "None while stopped")
                        .textSelection(.enabled)
                }
                if let networkName = instance.networkName {
                    LabeledContent("Dedicated network") {
                        Text(
                            model.networkNames.contains(networkName)
                                ? networkName : "\(networkName) — missing, recreated on start")
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text(instance.net.summary)
            }

            Section {
                ForEach(instance.ports) { port in
                        LabeledContent {
                            Text(port.spec)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        } label: {
                            Label(
                                port.isLoopback ? "This Mac only" : "Your network",
                                systemImage: port.isLoopback ? "laptopcomputer" : "network")
                        }
                }
                // One row: what's forwarded, and the way to change it.
                LabeledContent {
                    Button(instance.canEditPorts ? "Edit Ports…" : "Ports…") { model.editingPorts = instance }
                } label: {
                    Text(
                        instance.ports.isEmpty
                            ? "No ports on this Mac forward into the guest."
                            : "\(instance.ports.count) forwarded"
                    )
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Ports")
            } footer: {
                Text(
                    instance.canEditPorts
                        ? "Read when the VM boots; changes apply on the next start."
                        : "Read when the VM boots. Stop the instance to change them.")
            }

            Section {
                if instance.mounts.isEmpty {
                    Text("No host folders are mounted: the guest sees only its own image.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(instance.mounts) { mount in
                        LabeledContent {
                            Text(mount.source)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                        } label: {
                            Label(mount.destination, systemImage: mount.readOnly ? "lock" : "pencil")
                                .help(mount.readOnly ? "Read-only" : "Writable")
                        }
                    }
                }
            } header: {
                Text("Mounts")
            } footer: {
                Text("Nothing else on the host is reachable: apple/container grants no ambient access.")
            }

            Section {
                if instance.envKeys.isEmpty {
                    Text("No variables were injected.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(instance.envKeys.sorted().joined(separator: "   "))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if model.staleEnvironment.contains(instance.fullName) {
                    Label(
                        "The env registry changed after this instance was created. It keeps the environment it was created with.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("Names only. Values were baked in at creation and are not read back here.")
            }

            Section {
                LabeledContent("CPUs", value: "\(instance.cpus)")
                LabeledContent("Memory", value: instance.memoryDescription)
                LabeledContent("Architecture", value: instance.architecture)
                LabeledContent("Rosetta", value: instance.rosetta ? "On" : "Off")
                LabeledContent("Container name") {
                    Text(instance.fullName)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Platform")
            } footer: {
                Text(
                    "One Linux kernel per instance, on Virtualization.framework — no kernel shared with the host or with other instances."
                )
            }
        }
        .formStyle(.grouped)
    }
}
