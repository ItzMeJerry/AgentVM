//
//  SettingsView.swift
//  The config file and the env registry, edited in place. Both stay plain
//  KEY=VALUE files, editable by hand just as well.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import AgentVMKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            DefaultsSettings()
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
            RegistrySettings()
                .tabItem { Label("Environment", systemImage: "key") }
            SessionSettings()
                .tabItem { Label("Sessions", systemImage: "terminal") }
            DashboardSettings()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct DefaultsSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = AgentVMConfig()
    @State private var cpusText = ""
    @State private var memoryText = ""

    var body: some View {
        Form {
            Section {
                Picker("Network", selection: $draft.net) {
                    Text("Open").tag(NetPosture.open)
                    Text("Killswitch").tag(NetPosture.killswitch)
                }
            } header: {
                Text("Defaults for a New Instance")
            } footer: {
                Text(draft.net.summary)
            }

            Section {
                Toggle(isOn: $draft.removeOnExit) {
                    Text("One-shot by default")
                    Text("Remove a task's instance when its command exits.")
                }
                TextField("CPUs", text: $cpusText, prompt: Text("Default (4)"))
                TextField("Memory", text: $memoryText, prompt: Text("Default (1G)"))
            }

            Section {
                LabeledContent("Name prefix", value: draft.namePrefix)
                LabeledContent("Env registry", value: draft.envFilePath)
            } footer: {
                Text(
                    "AgentVM only ever lists, deletes or prunes containers carrying the name prefix. Edit the config file to change it."
                )
            }

            if !model.config.warnings.isEmpty {
                Section("Config File Warnings") {
                    ForEach(model.config.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
            }

            Section {
                HStack {
                    Button("Reveal Config File") {
                        NSWorkspace.shared.activateFileViewerSelecting([AgentVMConfig.defaultPath])
                    }
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        draft = model.config
        cpusText = draft.cpus.map(String.init) ?? ""
        memoryText = draft.memory ?? ""
    }

    private func save() {
        var updated = draft
        updated.cpus = Int(cpusText.trimmingCharacters(in: .whitespaces))
        let memory = memoryText.trimmingCharacters(in: .whitespaces)
        updated.memory = memory.isEmpty ? nil : memory
        model.saveConfig(updated)
    }
}

/// How shell sessions look. Like the dashboard's interval, it takes effect as
/// soon as it's chosen.
private struct SessionSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.glassSessions) {
                    Text("Panes of glass")
                    Text("Each session floats on Liquid Glass, with the desktop showing through behind it.")
                }
            } footer: {
                Text(
                    "Only the terminal's own background turns to glass: text, the cursor, selections and coloured output stay solid. With Reduce Transparency on in Accessibility settings, the glass turns opaque."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// How often the dashboard reads. Unlike the config file, it takes effect as
/// soon as it's chosen.
private struct DashboardSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Read figures every", selection: $model.samplingInterval) {
                    ForEach(SamplingInterval.choices, id: \.self) { interval in
                        Text(SamplingInterval.describe(interval)).tag(interval)
                    }
                }
            } footer: {
                Text(
                    "How often the dashboard reads each running instance and this Mac, while AgentVM's window is open. More often draws finer lines and wakes each instance's VM more often. Disk use is read every 20 seconds either way."
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct RegistrySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [EnvEntry] = []
    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                "Injected into every instance created from now on. A running instance keeps the environment baked in at creation."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            List {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("KEY", text: $entry.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        if revealed.contains(entry.id) {
                            TextField("value", text: $entry.value)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("value", text: $entry.value)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            if revealed.contains(entry.id) {
                                revealed.remove(entry.id)
                            } else {
                                revealed.insert(entry.id)
                            }
                        } label: {
                            Image(systemName: revealed.contains(entry.id) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Button {
                    entries.append(EnvEntry(key: "", value: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("mode 0600 · \(model.config.envFilePath)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Save") {
                    model.saveRegistry(entries.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { entries = model.registry.load() }
    }
}
