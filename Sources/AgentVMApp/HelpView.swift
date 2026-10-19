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
            Button("AgentVM Help") { openWindow(id: "help") }
                .keyboardShortcut("?")
        }
    }
}
