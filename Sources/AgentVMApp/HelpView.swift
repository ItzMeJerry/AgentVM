//
//  HelpView.swift
//  Help > AgentVM Help: what each toolbar button does, in full, and how split
//  panes work. The buttons' tooltips only name them; this is where the detail
//  lives.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI

struct HelpView: View {
    private struct Entry: Identifiable {
        let symbol: String
        let name: String
        let shortcut: String?
        let detail: String
        var id: String { name }
    }

    private static let instanceButtons = [
        Entry(
            symbol: "terminal", name: "New Session", shortcut: "⌘T",
            detail: "Opens another shell in the selected instance. The instance has to be running; start it first if it's stopped. Closing a session never stops the instance."),
        Entry(
            symbol: "play.fill", name: "Start", shortcut: nil,
            detail: "Boots the VM again, with the network it was created with."),
        Entry(
            symbol: "stop.fill", name: "Stop", shortcut: nil,
            detail: "Shuts the VM down. Its sessions end until you start it again."),
        Entry(
            symbol: "point.3.connected.trianglepath.dotted", name: "Ports", shortcut: "⌥⌘P",
            detail: "Forwards ports on this Mac into the instance. While the instance is running you can see the forwarded ports; stop it to change them."),
        Entry(
            symbol: "trash", name: "Delete", shortcut: nil,
            detail: "Removes the instance. Your mounted folders are kept."),
    ]

    private static let sidebarButtons = [
        Entry(
            symbol: "plus", name: "New Instance", shortcut: "⌘N",
            detail: "Boots a new Linux VM. You choose its image, network, mounts and environment before it starts."),
        Entry(
            symbol: "ellipsis.circle", name: "More", shortcut: nil,
            detail: "Prune removes every AgentVM instance and its network, and nothing else. Refresh re-reads the list from the container service."),
    ]

    private static let dashboard = [
        Entry(
            symbol: "gauge.with.dots.needle.33percent", name: "Dashboard", shortcut: "⇧⌘D",
            detail: "The top row of the sidebar. CPU, memory, network and disk activity for the running instances, with the last two minutes drawn as a line; each instance's figures in a table below; and this Mac's CPU, memory pressure, free disk space and what the container service stores. Readings are taken while AgentVM's window is open: every 2 seconds, or as often as Read every says — on the dashboard, or in Settings > Dashboard."),
        Entry(
            symbol: "chart.xyaxis.line", name: "An instance's charts", shortcut: nil,
            detail: "Click an instance's row for its own page: CPU, memory, network and disk activity over the last 2 or 10 minutes, and a ring for how full its disk is — what df inside it would say. Right-click a row to open the instance itself, start or stop it, or open a shell."),
        Entry(
            symbol: "hand.point.up.left", name: "Reading back", shortcut: nil,
            detail: "Point at a line to see the figure as it was at that moment, and how long ago. On an instance's page every chart marks the same moment."),
        Entry(
            symbol: "chevron.backward", name: "Back", shortcut: "⌘[",
            detail: "Swipe right with two fingers and the page follows them back to the dashboard, as in Safari — or with three, if that's how Swipe between pages is set in Trackpad settings. The back button in the toolbar and a mouse's back button do the same."),
    ]

    private static let sessionLook = [
        Entry(
            symbol: "square.on.square.intersection.dashed", name: "Panes of glass", shortcut: nil,
            detail: "Each session floats on Liquid Glass, with the desktop blurred behind it; in a split, the focused pane is tinted. Only the terminal's background turns to glass — text, the cursor and coloured output stay solid. Turn it off in View > Sessions as Glass or Settings > Sessions for solid terminals."),
    ]

    private static let splitPanes = [
        Entry(
            symbol: "rectangle.split.2x1", name: "Split panes", shortcut: nil,
            detail: "Drag a session's tab onto the terminal area. Drop it on a pane's edge to split that pane and put the session on that side; drop it in the middle to swap the two or show it there. A tab's right-click menu has Split Right and Split Down too."),
        Entry(
            symbol: "rectangle.split.2x2", name: "Snap Layouts", shortcut: nil,
            detail: "The button beside + shows ready-made arrangements. Click the zone the focused session should go in; the other sessions fill the rest. A zone with no session lets you pick one that isn't on screen, or start a new one there."),
        Entry(
            symbol: "arrow.left.and.right", name: "Dividers", shortcut: nil,
            detail: "Drag the line between two panes to resize them. In Snap mode, the default, it jumps between halves, thirds and quarters; switch to Free in Snap Layouts or Instance > Layout to place it anywhere. Double-click a divider to even out its panes."),
        Entry(
            symbol: "xmark", name: "Removing a pane", shortcut: nil,
            detail: "Click × on a pane's header, or drag the header back onto the tab bar. The session stays open as a tab; only closing its tab ends it."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Instance toolbar", Self.instanceButtons)
                section("Sidebar toolbar", Self.sidebarButtons)
                section("Dashboard", Self.dashboard)
                section("Sessions", Self.sessionLook)
                section("Split panes", Self.splitPanes)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 520)
    }

    private func section(_ title: String, _ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: entry.symbol)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name).fontWeight(.semibold)
                            if let shortcut = entry.shortcut {
                                Text(shortcut).foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Replaces the stock Help item — which only says no help is available — with
/// one that opens the window above.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("AgentVM Help", systemImage: "questionmark.circle") { openWindow(id: "help") }
                .keyboardShortcut("?")
        }
    }
}
