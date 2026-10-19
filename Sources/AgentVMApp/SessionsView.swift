//
//  SessionsView.swift
//  Shell sessions as tabs, shown in one pane or several. Each session is an
//  independent exec process: open several, close them in any order — the
//  instance never notices. Drag a tab onto the terminal area to snap it into a
//  split; drag a pane back onto the tab bar to take it out again.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import AgentVMKit
import AgentVMLayout
import SwiftUI

struct SessionsView: View {
    /// The coordinate space drags are measured in: tab bar and panes alike.
    static let space = "sessions"

    @EnvironmentObject private var model: AppModel
    let instance: AgentVMInstance
    @Namespace private var glass

    @State private var drag: PaneDrag?
    @State private var tabBarFrame: CGRect = .zero
    @State private var paneAreaFrame: CGRect = .zero
    @State private var showingLayouts = false

    private var sessions: [TerminalSession] { model.sessions[instance.fullName] ?? [] }

    /// The model's layout. It exists whenever there are sessions; one pane of
    /// the newest is only a stand-in for the moment one is being opened.
    private var layout: PaneLayout? {
        model.layouts[instance.fullName] ?? sessions.last.map { PaneLayout(session: $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let layout, !sessions.isEmpty {
                tabBar(layout)
                    .overlay {
                        if drag.flatMap({ intent(for: $0, in: layout) }) == .unsplit {
                            Capsule()
                                .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                                .padding(3)
                                .allowsHitTesting(false)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                        tabBarFrame = $0
                    }
                Divider()
                PaneArea(
                    instance: instance, layout: layout, sessions: sessions,
                    dropPreview: drag.flatMap { preview(for: $0, in: layout) },
                    drag: PaneDragHandlers(changed: dragChanged, ended: dragEnded))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                        paneAreaFrame = $0
                    }
            } else {
                emptyState
            }
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) {
            if let drag {
                DragLabel(title: drag.title)
                    .position(x: drag.location.x + 14, y: drag.location.y + 16)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Dragging sessions

    /// What letting go here would do.
    private enum Intent: Equatable {
        case snap(DropTarget)
        /// Over the tab bar: take the session out of the split.
        case unsplit
    }

    private func intent(for drag: PaneDrag, in layout: PaneLayout) -> Intent? {
        if paneAreaFrame.contains(drag.location) {
            let point = CGPoint(x: drag.location.x - paneAreaFrame.minX, y: drag.location.y - paneAreaFrame.minY)
            guard
                let target = layout.dropTarget(
                    at: point, in: CGRect(origin: .zero, size: paneAreaFrame.size), gap: PaneMetrics.gap,
                    minimumSize: PaneMetrics.minimumSize),
                target.pane != .session(drag.sessionID)
            else { return nil }
            return .snap(target)
        }
        if tabBarFrame.contains(drag.location), layout.isSplit, layout.contains(session: drag.sessionID) {
            return .unsplit
        }
        return nil
    }

    /// The part of the pane area a drop would take, in the pane area's own
    /// coordinates.
    private func preview(for drag: PaneDrag, in layout: PaneLayout) -> CGRect? {
        guard case .snap(let target)? = intent(for: drag, in: layout) else { return nil }
        let bounds = CGRect(origin: .zero, size: paneAreaFrame.size)
        guard let frame = layout.frames(in: bounds, gap: PaneMetrics.gap)[target.pane] else { return nil }
        return PaneLayout.previewRect(for: target.zone, in: frame)
    }

    private func dragChanged(_ sessionID: UUID, _ title: String, _ location: CGPoint) {
        drag = PaneDrag(sessionID: sessionID, title: title, location: location)
    }

    private func dragEnded(_ location: CGPoint) {
        guard var finished = drag, let layout else {
            drag = nil
            return
        }
        finished.location = location
        let name = instance.fullName
        withAnimation(.snappy(duration: 0.25)) {
            switch intent(for: finished, in: layout) {
            case .snap(let target): model.snap(finished.sessionID, to: target, in: name)
            case .unsplit: model.removePane(.session(finished.sessionID), in: name)
            case nil: break
            }
            drag = nil
        }
    }

    // MARK: - Pieces

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

    private func tabBar(_ layout: PaneLayout) -> some View {
        let name = instance.fullName
        return GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                SessionTab(
                                    session: session,
                                    index: index + 1,
                                    isSelected: layout.focusedSession == session.id,
                                    isOnScreen: layout.isSplit && layout.contains(session: session.id),
                                    namespace: glass,
                                    select: {
                                        withAnimation(.bouncy(duration: 0.3)) { model.reveal(session.id, in: name) }
                                    },
                                    close: { withAnimation(.snappy) { model.closeSession(session) } },
                                    splitRight: splitAction(session, .right, layout),
                                    splitDown: splitAction(session, .bottom, layout),
                                    unsplit: layout.isSplit && layout.contains(session: session.id)
                                        ? {
                                            withAnimation(.snappy(duration: 0.25)) {
                                                model.removePane(.session(session.id), in: name)
                                            }
                                        } : nil,
                                    drag: PaneDragHandlers(changed: dragChanged, ended: dragEnded))
                                .id(session.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .onChange(of: layout.focusedSession) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }

                Button {
                    showingLayouts.toggle()
                } label: {
                    Image(systemName: "rectangle.split.2x2")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .featureTip("Snap layouts")
                .popover(isPresented: $showingLayouts, arrowEdge: .bottom) {
                    LayoutPicker(current: layout.matchingTemplate, mode: $model.paneResizeMode) { template, zone in
                        withAnimation(.snappy(duration: 0.25)) {
                            model.applyTemplate(template, focusZone: zone, in: name)
                        }
                        showingLayouts = false
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

    /// "Split Right" or "Split Down" from a tab's menu: the session snaps
    /// beside the focused pane. Not offered for the focused session itself.
    private func splitAction(_ session: TerminalSession, _ zone: DropZone, _ layout: PaneLayout) -> (() -> Void)? {
        guard layout.focused != .session(session.id) else { return nil }
        let target = DropTarget(pane: layout.focused, zone: zone)
        return {
            withAnimation(.snappy(duration: 0.25)) { model.snap(session.id, to: target, in: instance.fullName) }
        }
    }
}

/// The label that follows the pointer while a session is dragged.
private struct DragLabel: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "terminal")
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 220)
            .fixedSize()
    }
}

private struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    let index: Int
    /// The session in the focused pane.
    let isSelected: Bool
    /// In one of the split's other panes.
    let isOnScreen: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    let splitRight: (() -> Void)?
    let splitDown: (() -> Void)?
    let unsplit: (() -> Void)?
    let drag: PaneDragHandlers

    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            // The close button sits where the status dot is, as in Safari:
            // it appears under the pointer and on the selected tab.
            ZStack {
                Circle()
                    .fill(session.state.dotColor)
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
            if (hovering || isOnScreen) && !isSelected {
                Capsule().fill(.quaternary)
            }
        }
        // The selected tab is a lens of glass. Sharing one glass ID across
        // tabs makes it flow from the old tab to the new one.
        .glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(isSelected ? "selected" : "tab-\(session.id)", in: namespace)
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(SessionsView.space))
                .onChanged { drag.changed(session.id, session.title, $0.location) }
                .onEnded { drag.ended($0.location) })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if let splitRight { Button("Split Right", action: splitRight) }
            if let splitDown { Button("Split Down", action: splitDown) }
            if let unsplit { Button("Remove from Split", action: unsplit) }
            if splitRight != nil || unsplit != nil { Divider() }
            Button("Close Session", action: close)
        }
        .help(session.exitDescription.map { "\(session.title) — ended (\($0))" } ?? session.title)
    }

    private var showsClose: Bool { hovering || isSelected }
}

/// Floats over the terminal: a way back to the live screen while reading the
/// scrollback, and, once the session has ended, what happened and what next.
struct SessionOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    /// Only the focused pane's Reopen answers Return; in a split, another
    /// pane's Return belongs to the shell running there.
    let isFocused: Bool
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
                .keyboardShortcut(isFocused ? .defaultAction : nil)
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
