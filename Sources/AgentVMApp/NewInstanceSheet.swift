//
//  NewInstanceSheet.swift
//  Everything a new instance needs, with the decisions that are hard to undo
//  made visible: what it can reach, and what it can see.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import AgentVMKit
import SwiftUI
import UniformTypeIdentifiers

struct NewInstanceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var spec = RunSpec()
    @State private var commandText = ""
    @State private var cpusText = ""
    @State private var memoryText = ""
    @State private var creating = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Text("New Instance")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Form {
                imageSection
                networkSection
                mountSection
                environmentSection
                resourceSection
            }
            .formStyle(.grouped)
            // Folders dropped anywhere on the sheet become mounts.
            .dropDestination(for: URL.self) { urls, _ in
                addMounts(urls)
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    // Concentric with the sheet's own corners.
                    ConcentricRectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(9)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaBar(edge: .bottom) { footer }
            // A dense form under buttons: the firmer edge keeps both legible.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
        .frame(width: 560, height: 620)
        .onAppear { spec = RunSpec(config: model.config) }
    }

    private var footer: some View {
        HStack {
            if creating, let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            } else if let problem = commandProblem {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(problem).font(.callout).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
            Button(creating ? "Creating…" : "Create") { create() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(
                    creating || spec.image.trimmingCharacters(in: .whitespaces).isEmpty || commandProblem != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sections

    private var imageSection: some View {
        Section {
            TextField("Image", text: $spec.image, prompt: Text("ubuntu:24.04"))
            TextField(text: $spec.name, prompt: Text("random")) {
                Text("Name")
                Text("Created as \(model.config.namePrefix)\(spec.name.isEmpty ? "…" : spec.name)")
            }
            Picker("Runs as", selection: $spec.mode) {
                Text("Instance").tag(AgentVMMode.instance)
                Text("Task").tag(AgentVMMode.task)
            }
            .pickerStyle(.segmented)
            if spec.mode == .task {
                TextField("Command", text: $commandText, prompt: Text("sh -c 'make test'"))
                Toggle("Remove when the command exits", isOn: $spec.removeOnExit)
            }
        } header: {
            Text("Image and Lifetime")
        } footer: {
            Text(spec.mode.summary)
        }
    }

    private var networkSection: some View {
        Section {
            Picker("Posture", selection: $spec.net) {
                Text("Open").tag(NetPosture.open)
                Text("Killswitch").tag(NetPosture.killswitch)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Network")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.net.summary)
                if spec.net == .open {
                    Label(
                        "Open is open: the instance reaches the internet and your Mac, and your Mac reaches it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Label(
                        "Services on your Mac bound to 0.0.0.0 are still reachable from inside. Bind them to 127.0.0.1.",
                        systemImage: "info.circle")
                }
            }
        }
    }

    private var mountSection: some View {
        Section {
            ForEach($spec.mounts) { $mount in
                HStack(spacing: 6) {
                    TextField("Host folder", text: $mount.hostPath, prompt: Text("Host folder"))
                        .labelsHidden()
                    Button {
                        chooseDirectory(into: $mount)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose a folder")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("Path in the guest", text: $mount.guestPath, prompt: Text("/work"))
                        .labelsHidden()
                        .frame(width: 120)
                    Toggle("Read-only", isOn: $mount.readOnly)
                        .toggleStyle(.checkbox)
                    Button {
                        spec.mounts.removeAll { $0.id == mount.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this mount")
                }
            }
            Button {
                spec.mounts.append(MountSpec(guestPath: "/work"))
            } label: {
                Label("Add Mount", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Mounts")
        } footer: {
            Text(
                "The guest sees exactly these folders and nothing else; / and your home folder are refused. Drop folders on this sheet to add them."
            )
        }
    }

    /// Dropped folders become mounts at /<folder name>; a first mount lands on
    /// /work, which is what an empty row would have suggested anyway.
    private func addMounts(_ urls: [URL]) -> Bool {
        let folders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard !folders.isEmpty else { return false }
        // Fill an untouched empty row before adding new ones.
        spec.mounts.removeAll { $0.hostPath.isEmpty }
        for folder in folders {
            let path = folder.path(percentEncoded: false)
            guard !spec.mounts.contains(where: { $0.hostPath == path }) else { continue }
            let guest = spec.mounts.isEmpty ? "/work" : "/" + folder.lastPathComponent
            spec.mounts.append(MountSpec(hostPath: path, guestPath: guest))
        }
        return true
    }

    private var environmentSection: some View {
        Section {
            Toggle(isOn: $spec.useRegistry) {
                Text("Shared env registry")
                Text("\(model.registry.load().count) variables")
            }
            ForEach($spec.env) { $entry in
                HStack(spacing: 6) {
                    TextField("Name", text: $entry.key, prompt: Text("KEY"))
                        .labelsHidden()
                        .font(.callout.monospaced())
                        .frame(width: 160)
                    Text("=").foregroundStyle(.tertiary)
                    TextField("Value", text: $entry.value, prompt: Text("value"))
                        .labelsHidden()
                    Button {
                        spec.env.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this variable")
                }
            }
            Button {
                spec.env.append(EnvEntry(key: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Environment")
        } footer: {
            Text("Variables here override the registry. Both are baked in at creation.")
        }
    }

    private var resourceSection: some View {
        Section {
            TextField("CPUs", text: $cpusText, prompt: Text("Default (4)"))
            TextField("Memory", text: $memoryText, prompt: Text("Default (1G)"))
            Toggle(isOn: $spec.rosetta) {
                Text("Rosetta")
                Text("For x86 images only; needs the Rosetta runtime on this Mac.")
            }
        } header: {
            Text("Resources")
        } footer: {
            Text("A guest sees one CPU more than you allocate: the VM runtime adds an overhead core.")
        }
    }

    // MARK: - Actions

    private func chooseDirectory(into mount: Binding<MountSpec>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            mount.wrappedValue.hostPath = url.path(percentEncoded: false)
            if mount.wrappedValue.guestPath.isEmpty {
                mount.wrappedValue.guestPath = "/" + url.lastPathComponent
            }
        }
    }

    private func create() {
        var spec = self.spec
        spec.cpus = Int(cpusText.trimmingCharacters(in: .whitespaces))
        let memory = memoryText.trimmingCharacters(in: .whitespaces)
        spec.memory = memory.isEmpty ? nil : memory
        spec.command = (try? ShellWords.split(commandText)) ?? []
        spec.env = spec.env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        spec.mounts = spec.mounts.filter { !$0.hostPath.isEmpty || !$0.guestPath.isEmpty }

        creating = true
        Task {
            let created = await model.create(spec: spec)
            creating = false
            if created { dismiss() }
        }
    }

    /// Why the task's command can't be split into arguments, while it can't —
    /// a quote left open, say. `sh -c 'make test'` is three arguments.
    private var commandProblem: String? {
        guard spec.mode == .task else { return nil }
        do {
            _ = try ShellWords.split(commandText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
