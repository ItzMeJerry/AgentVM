//
//  SettingsView.swift
//  The config file's defaults and the env registry, edited in place — both
//  stay plain KEY=VALUE files, editable by hand just as well — and how
//  sessions and the dashboard behave.
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
    @Environment(AppModel.self) private var model
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
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
            Section {
                Toggle(isOn: $model.metalSessions) {
                    Text("Draw with Metal")
                    Text("Terminal text is drawn on the GPU by SwiftTerm's own renderer.")
                }
            } footer: {
                Text(
                    "Turn it off only if text looks wrong. The other renderer can make AgentVM quit the first time a terminal draws text, because of a bug in macOS 27."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// How often the dashboard reads. Unlike the config file, it takes effect as
/// soon as it's chosen.
private struct DashboardSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Read every", selection: Bindable(model).samplingInterval) {
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
    @Environment(AppModel.self) private var model
    @State private var rows: [EnvRow] = []
    @State private var revealed: Set<UUID> = []

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
                ForEach($rows) { $entry in
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
                            rows.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Button {
                    rows.append(EnvRow())
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("mode 0600 · \(model.config.envFilePath)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Save") {
                    model.saveRegistry(EnvRow.entries(rows))
                }
                .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { rows = model.registry.load().map(EnvRow.init) }
    }
}

/// A variable being edited. A row has an identity of its own rather than
/// its name's: it keeps its place, and its field the focus, while the name in
/// it is typed, and two new rows are two rows.
struct EnvRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""

    init() {}

    init(_ entry: EnvEntry) {
        key = entry.key
        value = entry.value
    }

    /// The rows given a name, as entries; the rest were left blank.
    static func entries(_ rows: [EnvRow]) -> [EnvEntry] {
        rows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { EnvEntry(key: $0.key, value: $0.value) }
    }
}
