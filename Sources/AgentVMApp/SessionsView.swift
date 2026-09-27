//
//  SessionsView.swift
//  Shell sessions as tabs. Each one is an independent exec process: open
//  several, close them in any order — the instance never notices.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import AgentVMKit
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel
    let instance: AgentVMInstance
    @Namespace private var glass

    private var sessions: [TerminalSession] { model.sessions[instance.fullName] ?? [] }

    private var selected: TerminalSession? {
        let id = model.selectedSession[instance.fullName]
        return sessions.first { $0.id == id } ?? sessions.last
    }

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                emptyState
            } else {
                tabBar
                Divider()
                if let selected {
                    // Only the selected session is mounted. Its view belongs to
                    // the session, so scrollback and process survive the switch,
                    // and scrolls and clicks can't land on a hidden tab.
                    TerminalPane(session: selected)
                        .id(selected.id)
                        .overlay(alignment: .bottom) { SessionOverlay(session: selected) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(instance.isRunning ? "No sessions open" : "\(instance.shortName) is \(instance.stateLabel)")
                .font(.title3.weight(.medium))
            Text(
                instance.isRunning
                    ? "A session is a shell process inside the instance. Ending one never stops the instance."
                    : "Start the instance to open a shell session in it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            if instance.isRunning {
                Button("Open Shell Session") { model.openSession(in: instance) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            } else {
                Button("Start Instance") { Task { await model.start(instance) } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                SessionTab(
                                    session: session,
                                    index: index + 1,
                                    isSelected: session.id == selected?.id,
                                    namespace: glass,
                                    select: {
                                        withAnimation(.bouncy(duration: 0.3)) {
                                            model.selectedSession[instance.fullName] = session.id
                                        }
                                    },
                                    close: { withAnimation(.snappy) { model.closeSession(session) } })
                                .id(session.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .onChange(of: selected?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }

                Button {
                    withAnimation(.snappy) { _ = model.openSession(in: instance) }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!instance.isRunning)
                .help("Another session (⌘T)")
                .padding(.trailing, 10)
            }
        }
    }
}

private struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    let index: Int
    let isSelected: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            // The close button sits where the status dot is, as in Safari:
            // it appears under the pointer and on the selected tab.
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .opacity(showsClose ? 0 : 1)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(
                            Circle().fill(hoveringClose ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(showsClose ? 1 : 0)
                .onHover { hoveringClose = $0 }
                .help("Close this session — the instance keeps running")
            }
            .frame(width: 14, height: 14)

            Text(session.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .foregroundStyle(session.state.isFinished ? .secondary : .primary)

            if index <= 9 {
                Text("⌘\(index)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .padding(.vertical, 2)
        .background {
            if hovering && !isSelected {
                Capsule().fill(.quaternary)
            }
        }
        // The selected tab is a lens of glass. Sharing one glass ID across
        // tabs makes it flow from the old tab to the new one.
        .glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(isSelected ? "selected" : "tab-\(session.id)", in: namespace)
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Close Session", action: close)
        }
        .help(session.exitDescription.map { "\(session.title) — ended (\($0))" } ?? session.title)
    }

    private var showsClose: Bool { hovering || isSelected }

    private var dotColor: Color {
        switch session.state {
        case .starting: .yellow
        case .running: .green
        case .exited: .secondary
        case .failed: .red
        }
    }
}

/// Floats over the terminal: a way back to the live screen while reading the
/// scrollback, and, once the session has ended, what happened and what next.
private struct SessionOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .trailing, spacing: 10) {
                if session.isScrolledBack {
                    Button {
                        withAnimation(.snappy) { session.scrollToBottom() }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .labelStyle(.iconOnly)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Back to the live screen")
                    .glassEffectID("jump", in: glass)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 22)
                }

                if session.state.isFinished {
                    endedBar
                        .glassEffectID("ended", in: glass)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 14)
        }
        .animation(.bouncy(duration: 0.35), value: session.isScrolledBack)
        .animation(.bouncy(duration: 0.35), value: session.state.isFinished)
    }

    private var endedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(failed ? .red : .secondary)
            Text("Session ended\(session.exitDescription.map { " · \($0)" } ?? "")")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 16)
            Button("Close") { withAnimation(.snappy) { model.closeSession(session) } }
                .buttonStyle(.glass)
            Button("Reopen") { withAnimation(.snappy) { model.reopenSession(session) } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.instances.first { $0.fullName == session.instanceName }?.isRunning != true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 480)
    }

    private var failed: Bool {
        if case .failed = session.state { return true }
        return false
    }
}
