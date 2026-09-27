//
//  HoverHint.swift
//  A small popup that says what a button does when the pointer rests on it.
//  Toolbar buttons show only an icon, and a `.help` tooltip on one doesn't
//  reliably appear, so these use a popover, which the toolbar can't swallow.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI

extension View {
    /// Shows `text` in a small popup under the view after the pointer has
    /// rested on it briefly; it goes away when the pointer leaves or clicks.
    /// The first line is the button's name, in bold; the rest says what it does.
    func hoverHint(_ text: String) -> some View {
        modifier(HoverHint(text: text))
    }
}

private struct HoverHint: ViewModifier {
    let text: String

    private var title: Substring { text.split(separator: "\n", maxSplits: 1).first ?? "" }
    private var detail: Substring? { text.split(separator: "\n", maxSplits: 1).dropFirst().first }

    @State private var showing = false
    @State private var pending: Task<Void, Never>?

    /// Long enough that sweeping across the toolbar doesn't flash every hint.
    private static let delay = Duration.milliseconds(550)

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: Self.delay)
                        if !Task.isCancelled { showing = true }
                    }
                } else {
                    showing = false
                }
            }
            // A click means the pointer's owner knows what it does.
            .simultaneousGesture(TapGesture().onEnded {
                pending?.cancel()
                showing = false
            })
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .onDisappear {
                pending?.cancel()
                showing = false
            }
    }
}
