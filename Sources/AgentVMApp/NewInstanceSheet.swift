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
            HStack {
                Text("New Instance").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    imageSection
                    networkSection
                    mountSection
                    environmentSection
                    resourceSection
                }
                .padding(20)
            }
            .frame(height: 430)

            Divider()

            HStack {
                if creating, let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(creating ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(creating || spec.image.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620)
        .onAppear { spec = RunSpec(config: model.config) }
    }

    // MARK: - Sections

    private var imageSection: some View {
        FormSection("Image and lifetime") {
            LabeledContent("Image") {
                TextField("ubuntu:24.04", text: $spec.image)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Name") {
                HStack(spacing: 6) {
                    Text(model.config.namePrefix)
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                    TextField("random", text: $spec.name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Picker("Runs as", selection: $spec.mode) {
                Text("Instance — long-lived").tag(AgentVMMode.instance)
                Text("Task — one command").tag(AgentVMMode.task)
            }
            .pickerStyle(.radioGroup)

            Text(spec.mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if spec.mode == .task {
                LabeledContent("Command") {
                    TextField("sh -c 'make test'", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("One-shot: remove the instance when the command exits", isOn: $spec.removeOnExit)
                    .font(.callout)
            }
        }
    }

    private var networkSection: some View {
        FormSection("Network") {
            Picker("Posture", selection: $spec.net) {
                Text("Open").tag(NetPosture.open)
                Text("Killswitch").tag(NetPosture.killswitch)
            }
            .pickerStyle(.segmented)

            Text(spec.net.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if spec.net == .open {
                Label(
                    "Open is open: the instance reaches the internet and your host, and the host reaches it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Label(
                    "Host services bound to 0.0.0.0 are still reachable from inside. Bind them to 127.0.0.1.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var mountSection: some View {
        FormSection("Mounts") {
            Text("The guest sees exactly these directories and nothing else. / and your home folder are refused. Drop folders here to add them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($spec.mounts) { $mount in
                HStack(spacing: 6) {
                    TextField("host directory", text: $mount.hostPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        chooseDirectory(into: $mount)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    TextField("/work", text: $mount.guestPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Toggle("ro", isOn: $mount.readOnly)
                        .toggleStyle(.checkbox)
                        .help("Read-only")
                    Button {
                        spec.mounts.removeAll { $0.id == mount.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                spec.mounts.append(MountSpec(guestPath: "/work"))
            } label: {
                Label("Add mount", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .opacity(dropTargeted ? 1 : 0)
        )
        .padding(-8)
        .dropDestination(for: URL.self) { urls, _ in
            addMounts(urls)
        } isTargeted: { dropTargeted = $0 }
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
        FormSection("Environment") {
            Toggle(
                "Inject the shared registry (\(model.registry.load().count) variables)",
                isOn: $spec.useRegistry)

            ForEach($spec.env) { $entry in
                HStack(spacing: 6) {
                    TextField("KEY", text: $entry.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("=").foregroundStyle(.tertiary)
                    TextField("value", text: $entry.value)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        spec.env.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                spec.env.append(EnvEntry(key: "", value: ""))
            } label: {
                Label("Add variable", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Text("Per-instance variables override the registry. Both are baked in at creation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resourceSection: some View {
        FormSection("Resources") {
            HStack(spacing: 14) {
                LabeledContent("CPUs") {
                    TextField("default (4)", text: $cpusText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                LabeledContent("Memory") {
                    TextField("default (1G)", text: $memoryText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }
            Text("A guest sees one CPU more than you allocate: the VM runtime adds an overhead core.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Rosetta (x86 images only)", isOn: $spec.rosetta)
                .help("Requires the Rosetta runtime on this Mac. Do not enable it for arm64 images.")
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
        spec.command = Self.splitCommand(commandText)
        spec.env = spec.env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        spec.mounts = spec.mounts.filter { !$0.hostPath.isEmpty || !$0.guestPath.isEmpty }

        creating = true
        Task {
            let created = await model.create(spec: spec)
            creating = false
            if created { dismiss() }
        }
    }

    /// Splits a typed command the way a shell would for the simple cases, so
    /// `sh -c 'make test'` arrives as three arguments rather than five.
    static func splitCommand(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }
}

struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
