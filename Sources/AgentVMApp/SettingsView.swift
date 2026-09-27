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
                Text(draft.net.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Defaults for a new instance")
            }

            Section {
                Toggle("One-shot by default (remove when the command exits)", isOn: $draft.removeOnExit)
                TextField("CPUs", text: $cpusText, prompt: Text("daemon default (4)"))
                TextField("Memory", text: $memoryText, prompt: Text("daemon default (1G)"))
            }

            Section {
                LabeledContent("Name prefix", value: draft.namePrefix)
                LabeledContent("Env registry", value: draft.envFilePath)
                Text(
                    "AgentVM only ever lists, deletes or prunes containers carrying the name prefix. Edit the file directly to change it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !model.config.warnings.isEmpty {
                Section("Config file warnings") {
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
