//
//  FeatureTip.swift
//  The standard macOS tooltip for a toolbar button: a few words naming the
//  feature, drawn by the system after the pointer rests. What a button does in
//  detail lives in Help > AgentVM Help, not in a bubble over the window.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import SwiftUI

extension View {
    /// Names the feature in a native tooltip.
    ///
    /// Set twice on purpose: SwiftUI's `.help` doesn't reliably reach a toolbar
    /// button, so an AppKit view carries the same `toolTip`. The system shows
    /// one tooltip at a time, so they never stack.
    func featureTip(_ name: String) -> some View {
        help(name).overlay(ToolTipArea(text: name))
    }
}

/// An invisible AppKit view whose only job is to own a `toolTip`.
private struct ToolTipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = text
    }

    /// Tooltips come from tracking, not hit-testing, so clicks can fall through
    /// to the button underneath.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
