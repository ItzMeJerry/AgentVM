//
//  SplitPanesView.swift
//  The terminal area, split into panes. Where everything goes comes from
//  AgentVMLayout's PaneLayout; this file draws it and turns gestures into the
//  layout operations — a tab or pane header dragged onto a pane, a divider
//  dragged or double-clicked, an empty zone filled.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import AgentVMLayout
import SwiftUI

/// The sizes the split-pane UI and the layout model agree on.
enum PaneMetrics {
    /// The space between two panes: a hairline between solid ones, a margin
    /// of backdrop between panes of glass.
    static func gap(glass: Bool) -> Double { glass ? 8 : 1 }
    /// Around the panes of glass, so they float clear of the window's edges.
    static let glassMargin = 8.0
    /// The smallest a glass pane's corners get; near the window's own
    /// corners they follow its curve.
    static let glassCornerRadius = 12.0
    /// The smallest a pane may get, header included: about 20 columns by 5 rows
    /// at the default text size.
    static let minimumSize = CGSize(width: 160, height: 100)
    /// The strip above each pane, shown once there is more than one.
    static let headerHeight = 22.0
    /// How wide the grabbable band around a divider's line is.
    static let dividerGrabWidth = 9.0
}

/// A session being dragged by its tab or its pane's header.
struct PaneDrag: Equatable {
    let sessionID: UUID
    let title: String
    var location: CGPoint
}

/// What a pane's header reports while it's dragged, in the sessions view's
/// coordinate space.
struct PaneDragHandlers {
    let changed: (_ sessionID: UUID, _ title: String, _ location: CGPoint) -> Void
    let ended: (_ location: CGPoint) -> Void
}

extension TerminalSession.State {
    /// The status dot shown on tabs and pane headers.
    var dotColor: Color {
        switch self {
        case .starting: .yellow
        case .running: .green
        case .exited: .secondary
        case .failed: .red
        }
    }
}

struct PaneArea: View {
    let instance: AgentVMInstance
    let layout: PaneLayout
    let sessions: [TerminalSession]
    /// Where a drop would land, in this view's coordinates, while dragging.
    let dropPreview: CGRect?
    let drag: PaneDragHandlers

    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let frames = layout.frames(in: bounds, gap: PaneMetrics.gap(glass: model.glassSessions))
            let hidden = sessions.filter { !layout.contains(session: $0.id) }
            // One container for all the panes of glass: it renders them
            // together, as Apple advises, and lets them morph as the split
            // changes. No spacing, so panes a gap apart stay apart.
            GlassEffectContainer(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.leaves, id: \.self) { content in
                        if let frame = frames[content] {
                            PaneView(
                                instance: instance,
                                content: content,
                                session: content.sessionID.flatMap { id in sessions.first { $0.id == id } },
                                isFocused: layout.focused == content,
                                showsHeader: layout.isSplit,
                                hiddenSessions: hidden,
                                drag: drag)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                    ForEach(layout.dividers(in: bounds, gap: PaneMetrics.gap(glass: model.glassSessions)), id: \.id) {
                        divider in
                        PaneDividerHandle(
                            divider: divider,
                            move: { model.moveDivider(divider, to: $0, in: instance.fullName) },
                            equalize: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    model.equalizeSplit(at: divider.id.path, in: instance.fullName)
                                }
                            })
                    }
                    if let dropPreview {
                        DropHighlight()
                            .frame(width: dropPreview.width, height: dropPreview.height)
                            .position(x: dropPreview.midX, y: dropPreview.midY)
                            .animation(.snappy(duration: 0.15), value: dropPreview)
                    }
                }
            }
        }
        // Between solid panes the gap shows through as a separator line;
        // between panes of glass, the backdrop does.
        .background(model.glassSessions ? Color.clear : Color(nsColor: .separatorColor))
    }
}

/// What's behind the window, blurred: the standard macOS material for a
/// background in the content layer, and what the panes of glass refract.
/// Reduce Transparency makes it opaque.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct PaneView: View {
    let instance: AgentVMInstance
    let content: PaneContent
    let session: TerminalSession?
    let isFocused: Bool
    let showsHeader: Bool
    let hiddenSessions: [TerminalSession]
    let drag: PaneDragHandlers

    @EnvironmentObject private var model: AppModel

    /// Concentric with the window where a pane meets its corners, and never
    /// tighter than the minimum elsewhere.
    private var shape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(PaneMetrics.glassCornerRadius)))
    }

    var body: some View {
        let glass = model.glassSessions
        VStack(spacing: 0) {
            if showsHeader {
                PaneHeader(
                    instance: instance, content: content, session: session, isFocused: isFocused, drag: drag)
            }
            if let session {
                TerminalPane(session: session, isFocused: isFocused)
                    .overlay(alignment: .bottom) { SessionOverlay(session: session, isFocused: isFocused) }
            } else {
                EmptyPane(instance: instance, content: content, hiddenSessions: hiddenSessions)
            }
        }
        .clipShape(glass ? AnyShape(shape) : AnyShape(Rectangle()))
        // A pane of glass under the terminal; in a split, the focused one is
        // tinted with the accent, as Apple suggests for prominence.
        .glassEffect(
            glass ? (showsHeader && isFocused ? .regular.tint(Color.accentColor.opacity(0.1)) : .regular) : .identity,
            in: shape
        )
        .overlay {
            if showsHeader && isFocused {
                if glass {
                    shape
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                } else {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// A pane's title strip in a split: what's in it, a handle to drag it
/// elsewhere, and a way to take it out of the split.
private struct PaneHeader: View {
    let instance: AgentVMInstance
    let content: PaneContent
    let session: TerminalSession?
    let isFocused: Bool
    let drag: PaneDragHandlers

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if let session {
                PaneHeaderTitle(session: session)
            } else {
                Text("Empty pane")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.removePane(content, in: instance.fullName) }
            } label: {
                Label(session == nil ? "Remove Pane" : "Remove from Split", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(session == nil ? "Remove this pane" : "Remove from split — the session stays a tab")
        }
        .padding(.horizontal, model.glassSessions ? 12 : 8)
        .frame(height: PaneMetrics.headerHeight)
        // On glass the strip is part of the pane, whose tint marks the focus.
        .background(
            model.glassSessions
                ? Color.clear
                : isFocused ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.focusPane(content, in: instance.fullName) }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(SessionsView.space))
                .onChanged { value in
                    guard let session else { return }
                    drag.changed(session.id, session.title, value.location)
                }
                .onEnded { value in drag.ended(value.location) },
            including: session == nil ? .subviews : .all)
    }
}

private struct PaneHeaderTitle: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.state.dotColor)
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(session.state.isFinished ? .secondary : .primary)
        }
    }
}

/// A zone a template left open — Snap Assist, in Windows' terms: pick one of
/// the sessions that aren't on screen, or start a new one here.
private struct EmptyPane: View {
    let instance: AgentVMInstance
    let content: PaneContent
    let hiddenSessions: [TerminalSession]

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            if !hiddenSessions.isEmpty {
                Text("Show a session here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(hiddenSessions.prefix(6)) { session in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                model.show(session.id, inPane: content, in: instance.fullName)
                            }
                        } label: {
                            Text(session.title)
                                .lineLimit(1)
                                .frame(maxWidth: 200)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            Button("New Session") {
                withAnimation(.snappy(duration: 0.2)) {
                    _ = model.openSession(in: instance, intoPane: content)
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!instance.isRunning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.glassSessions ? Color.clear : Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.focusPane(content, in: instance.fullName) }
    }
}

/// The grabbable band over a divider's line. Snapping or free movement is the
/// model's call; this only reports where the pointer wants the divider.
private struct PaneDividerHandle: View {
    let divider: PaneDivider
    let move: (Double) -> Void
    let equalize: () -> Void

    /// The divider's position when the drag began; translations add to it.
    @State private var start: Double?

    var body: some View {
        let sideways = divider.axis == .horizontal
        Color.clear
            .frame(
                width: sideways ? PaneMetrics.dividerGrabWidth : divider.rect.width,
                height: sideways ? divider.rect.height : PaneMetrics.dividerGrabWidth)
            .contentShape(Rectangle())
            .pointerStyle(sideways ? .columnResize : .rowResize)
            .gesture(
                // Global coordinates: the handle itself moves as the divider does,
                // which would shift a local coordinate space mid-drag.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = start ?? divider.boundary
                        if start == nil { start = origin }
                        let points = sideways ? value.translation.width : value.translation.height
                        move(origin + points / max(divider.length, 1))
                    }
                    .onEnded { _ in start = nil })
            .onTapGesture(count: 2, perform: equalize)
            .position(x: divider.rect.midX, y: divider.rect.midY)
            .accessibilityElement()
            .accessibilityLabel(sideways ? "Divider between columns" : "Divider between rows")
            .accessibilityAction(named: "Even out") { equalize() }
    }
}

/// Where a dragged session would land.
private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
            }
            .padding(4)
            .allowsHitTesting(false)
    }
}
