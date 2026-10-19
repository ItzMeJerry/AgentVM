//
//  PortsSheet.swift
//  Which ports on this Mac forward into an instance. Read when the VM boots,
//  so they can change only while it's stopped.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import SwiftUI

struct PortsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The instance as it was when the sheet opened; the live one is looked up
    /// by name, so a Stop from here unlocks the editor.
    let instance: AgentVMInstance

    @State private var rows: [PortRow] = []
    @State private var original: [PortMapping] = []
    @State private var saving = false
    @State private var error: String?

    private var live: AgentVMInstance {
        model.instances.first { $0.fullName == instance.fullName } ?? instance
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ports").font(.title3.weight(.semibold))
                Text(live.shortName).font(.title3).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Form {
                if !live.canEditPorts { stopSection }
                portsSection
            }
            .formStyle(.grouped)
            // A bar the form scrolls under, not a section behind a rule; the
            // firmer edge keeps buttons legible over a long list of ports.
            .safeAreaBar(edge: .bottom) { footer }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
        .frame(width: 600, height: 470)
        .onAppear {
            original = live.ports
            rows = live.ports.map(PortRow.init)
            if rows.isEmpty && live.canEditPorts { rows = [PortRow()] }
        }
        .onChange(of: live.canEditPorts) { _, editable in
            if editable && rows.isEmpty { rows = [PortRow()] }
        }
    }

    // MARK: - Parts

    private var stopSection: some View {
        Section {
            HStack(spacing: 10) {
                Label(
                    live.isRunning
                        ? "\(live.shortName) is running. Stop it to change its ports; its sessions end."
                        : "\(live.shortName) is \(live.stateLabel). Ports can change once it has stopped.",
                    systemImage: "lock.fill")
                Spacer()
                if live.isRunning {
                    Button("Stop") { Task { await model.stop(live) } }
                        .disabled(model.busy != nil)
                }
            }
        }
    }

    private var portsSection: some View {
        Section {
            if !rows.isEmpty {
                HStack(spacing: 6) {
                    Text("Address").frame(width: 130, alignment: .leading)
                    Text("Port on this Mac").frame(width: 112, alignment: .leading)
                    Spacer().frame(width: 14)
                    Text("Guest port").frame(width: 92, alignment: .leading)
                    Text("Protocol")
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                PortRowView(row: $row) {
                    rows.removeAll { $0.id == row.id }
                }
            }
            if rows.isEmpty {
                Text("No ports are published. Your Mac reaches an open instance at its IP address either way.")
                    .foregroundStyle(.secondary)
            }
            Button {
                rows.append(PortRow())
            } label: {
                Label("Add Port", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(rows.count >= PortMapping.limit)
        } header: {
            Text("Forwarded Ports")
        } footer: {
            notes
        }
        .disabled(!live.canEditPorts || saving)
    }

    @ViewBuilder
    private var notes: some View {
        let mappings = rows.compactMap { try? $0.mapping() }
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "A port on this Mac forwards to a port inside the guest. Ports are read when the VM boots, so they change only while the instance is stopped. With no address, a port listens on this Mac only."
            )
            if mappings.contains(where: { !$0.isLoopback }) {
                Label(
                    "A port on an address other than 127.0.0.1 is reachable from other machines on your network.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            if mappings.contains(where: \.isIPv6) {
                Label(
                    "An IPv6 address needs the instance to have an IPv6 address too, or it won't start.",
                    systemImage: "info.circle")
            }
            if live.net == .killswitch {
                Label(
                    "Ports only let this Mac connect in. The killswitch still gives the guest no route out.",
                    systemImage: "lock.shield")
            }
            if original.isEmpty && !mappings.isEmpty {
                Label(
                    "The first time an instance publishes a port, macOS may ask to allow local network access.",
                    systemImage: "info.circle")
            }
        }
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
            if live.canEditPorts {
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

    /// Rows with nothing typed in them don't count.
    private var filledRows: [PortRow] { rows.filter { !$0.isBlank } }

    private var parsed: Result<[PortMapping], Error> {
        Result {
            let mappings = try filledRows.map { try $0.mapping() }
            try PortMapping.validate(mappings)
            return mappings
        }
    }

    private var validationProblem: String? {
        if case .failure(let failure) = parsed { return failure.localizedDescription }
        return nil
    }

    private var canSave: Bool {
        guard !saving, case .success(let mappings) = parsed else { return false }
        return mappings != original
    }

    private func save(start: Bool) {
        guard case .success(let mappings) = parsed else { return }
        saving = true
        error = nil
        Task {
            let failure = await model.setPorts(mappings, on: live, thenStart: start)
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}

/// One mapping as typed: the fields stay text until saved, so a half-typed
/// range isn't rejected keystroke by keystroke.
struct PortRow: Identifiable, Equatable {
    let id = UUID()
    var address = ""
    var hostPort = ""
    var guestPort = ""
    var proto = "tcp"

    init() {}

    init(_ mapping: PortMapping) {
        address = mapping.hostAddress == PortMapping.defaultHostAddress ? "" : mapping.hostAddress
        let parts = mapping.spec.split(separator: "/").first.map { String($0) } ?? ""
        // The last two colon-separated fields are the ports; everything before
        // is the address, which may itself contain colons (IPv6).
        let fields = parts.split(separator: ":", omittingEmptySubsequences: false)
        hostPort = fields.dropLast().last.map(String.init) ?? "\(mapping.hostPort)"
        guestPort = fields.last.map(String.init) ?? "\(mapping.containerPort)"
        proto = mapping.proto
    }

    var isBlank: Bool {
        address.trimmingCharacters(in: .whitespaces).isEmpty
            && hostPort.trimmingCharacters(in: .whitespaces).isEmpty
            && guestPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func mapping() throws -> PortMapping {
        let host = hostPort.trimmingCharacters(in: .whitespaces)
        // Guest port defaults to the host port, as in "just forward 8080".
        let guest = guestPort.trimmingCharacters(in: .whitespaces).isEmpty
            ? host : guestPort.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw AgentVMError("a port mapping needs a host port") }
        var spec = "\(host):\(guest)/\(proto)"
        let address = address.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if !address.isEmpty {
            spec = (address.contains(":") ? "[\(address)]" : address) + ":" + spec
        }
        return try PortMapping.parse(spec)
    }
}

private struct PortRowView: View {
    @Binding var row: PortRow
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(PortMapping.defaultHostAddress, text: $row.address)
                .frame(width: 130)
            TextField("8080", text: $row.hostPort)
                .frame(width: 112)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            TextField(row.hostPort.isEmpty ? "80" : row.hostPort, text: $row.guestPort)
                .frame(width: 92)
            Picker("Protocol", selection: $row.proto) {
                Text("TCP").tag("tcp")
                Text("UDP").tag("udp")
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            if !row.isBlank, let problem = problem {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(problem)
            }
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this port")
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout.monospacedDigit())
    }

    private var problem: String? {
        do {
            _ = try row.mapping()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
