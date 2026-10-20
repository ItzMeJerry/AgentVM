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
    @Environment(AppModel.self) private var model

    /// The instance as it was when the sheet opened; the live one is looked up
    /// by name, so a Stop from here unlocks the editor.
    let instance: AgentVMInstance
    /// What the editor starts out showing, when not what the instance runs.
    var draft: (mode: AgentVMMode, command: String)?

    @State private var mode: AgentVMMode = .instance
    @State private var commandText = ""

    private var live: AgentVMInstance {
        model.instances.first { $0.fullName == instance.fullName } ?? instance
    }

    var body: some View {
        InstanceEditSheet(
            title: "Main Process", instance: live, what: "what it runs", canChange: live.canChangeMainProcess,
            size: CGSize(width: 560, height: 430), problem: validationProblem, canSave: canSave
        ) { thenStart in
            guard case .success(let process) = parsed else { return nil }
            return await model.setMainProcess(process, on: live, thenStart: thenStart)
        } content: {
            processSection
        }
        .onAppear {
            mode = draft?.mode ?? live.mode
            commandText = draft?.command ?? (live.mode == .task ? ShellWords.join(live.command) : "")
        }
    }

    // MARK: - Parts

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
        guard case .success(let process) = parsed else { return false }
        return process != current
    }
}
