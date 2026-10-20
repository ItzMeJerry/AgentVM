//
//  InstanceEditSheet.swift
//  The frame of a sheet that changes what a stopped instance starts with —
//  its ports, its main process: the instance's name in the title, a way to
//  stop it while it runs, and Save, or Save and Start.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

struct InstanceEditSheet<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let title: String
    /// The instance as it is now, so a Stop from here unlocks the editor.
    let instance: AgentVMInstance
    /// What stopping it lets you change: "its ports", "what it runs".
    let what: String
    let canChange: Bool
    let size: CGSize
    /// Why what's there can't be saved, while it can't.
    let problem: String?
    /// Whether there's a change, and one that can be saved.
    let canSave: Bool
    /// Saves, starting the instance afterwards if asked; the failure, if any.
    let save: (_ thenStart: Bool) async -> String?
    @ViewBuilder let content: Content

    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text(instance.shortName).font(.title3).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Form {
                if !canChange { stopSection }
                content.disabled(!canChange || saving)
            }
            .formStyle(.grouped)
            // A bar the form scrolls under, not a section behind a rule; the
            // firmer edge keeps the buttons legible over a long form.
            .safeAreaBar(edge: .bottom) { footer }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }

    private var stopSection: some View {
        Section {
            HStack(spacing: 10) {
                Label(
                    instance.isRunning
                        ? "\(instance.shortName) is running. Stop it to change \(what); its sessions end."
                        : "\(instance.shortName) is \(instance.stateLabel). \(what.prefix(1).uppercased() + what.dropFirst()) can change once it has stopped.",
                    systemImage: "stop.circle")
                Spacer()
                if instance.isRunning {
                    Button("Stop") { Task { await model.stop(instance) } }
                        .disabled(model.busy != nil)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if saving, let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            } else if let problem = error ?? problem {
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
            if canChange {
                Button("Save") { run(thenStart: false) }
                    .buttonStyle(.glass)
                    .disabled(!canSave || saving)
                Button("Save and Start") { run(thenStart: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave || saving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func run(thenStart: Bool) {
        saving = true
        error = nil
        Task {
            let failure = await save(thenStart)
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
