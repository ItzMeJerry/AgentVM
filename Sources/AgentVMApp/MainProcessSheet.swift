//
//  MainProcessSheet.swift
//  What an instance runs as its main process — the keepalive, or a command —
//  and so how long it lives. Read when the VM boots, so it can change only
//  while the instance is stopped.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

struct MainProcessSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The instance as it was when the sheet opened; the live one is looked up
    /// by name, so a Stop from here unlocks the editor.
    let instance: AgentVMInstance
    /// What the editor starts out showing, when not what the instance runs.
    var draft: (mode: AgentVMMode, command: String)?

    @State private var mode: AgentVMMode = .instance
    @State private var commandText = ""
    @State private var saving = false
    @State private var error: String?

    private var live: AgentVMInstance {
        model.instances.first { $0.fullName == instance.fullName } ?? instance
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Main Process").font(.title3.weight(.semibold))
                Text(live.shortName).font(.title3).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Form {
                if !live.canChangeMainProcess { stopSection }
                processSection
            }
            .formStyle(.grouped)
            .safeAreaBar(edge: .bottom) { footer }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
        .frame(width: 560, height: 430)
        .onAppear {
            mode = draft?.mode ?? live.mode
            commandText = draft?.command ?? (live.mode == .task ? ShellWords.join(live.command) : "")
        }
    }

    // MARK: - Parts

    private var stopSection: some View {
        Section {
            HStack(spacing: 10) {
                Label(
                    live.isRunning
                        ? "\(live.shortName) is running. Stop it to change what it runs; its sessions end."
                        : "\(live.shortName) is \(live.stateLabel). What it runs can change once it has stopped.",
                    systemImage: "stop.circle")
                Spacer()
                if live.isRunning {
                    Button("Stop") { Task { await model.stop(live) } }
                        .disabled(model.busy != nil)
                }
            }
        }
    }

    private var processSection: some View {
        Section {
            Picker("Runs as", selection: $mode) {
                Text("Instance").tag(AgentVMMode.instance)
                Text("Task").tag(AgentVMMode.task)
            }
            .pickerStyle(.segmented)
            if mode == .task {
                TextField("Command", text: $commandText, prompt: Text("sh -c 'make test'"))
                    .font(.body.monospaced())
            } else {
                LabeledContent("Main process") {
                    Text(ShellWords.join(MainProcess.keepalive.command))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Lifetime")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.summary)
                if mode == .task {
                    Text(
                        "It runs exactly as written, not through a shell: for pipes, && or $VARIABLES, use sh -c '…'. The image's entrypoint isn't put in front of it."
                    )
                }
                Text(
                    "Read when the VM boots, so a change applies on the next start. Its environment, working directory and user stay as they were created."
                )
            }
        }
        .disabled(!live.canChangeMainProcess || saving)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if saving, let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            } else if let problem = error ?? validationProblem {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(problem)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
            if live.canChangeMainProcess {
                Button("Save") { save(start: false) }
                    .buttonStyle(.glass)
                    .disabled(!canSave)
                Button("Save and Start") { save(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - State

    private var parsed: Result<MainProcess, Error> {
        Result { try MainProcess(mode: mode, command: mode == .task ? ShellWords.split(commandText) : []) }
    }

    /// Only once something is typed: an empty field is unfinished, not wrong.
    private var validationProblem: String? {
        guard mode == .task, !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            case .failure(let failure) = parsed
        else { return nil }
        return failure.localizedDescription
    }

    /// What it runs now, to tell a change from none.
    private var current: MainProcess? { try? MainProcess(mode: live.mode, command: live.command) }

    private var canSave: Bool {
        guard !saving, case .success(let process) = parsed else { return false }
        return process != current
    }

    private func save(start: Bool) {
        guard case .success(let process) = parsed else { return }
        saving = true
        error = nil
        Task {
            let failure = await model.setMainProcess(process, on: live, thenStart: start)
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
