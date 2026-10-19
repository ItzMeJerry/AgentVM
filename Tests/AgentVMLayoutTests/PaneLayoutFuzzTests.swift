//
//  PaneLayoutFuzzTests.swift
//  Thousands of random operations — everything a user can do to split panes,
//  in any order — with the layout checked for well-formedness after every one.
//  Seeded, so a failure names the seed and step that reproduce it.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentVMLayout

/// SplitMix64: small, fast, and the same sequence on every machine.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Everything that must hold of any layout, whatever was done to it.
func problems(in layout: PaneLayout, tabs: [UUID]) -> [String] {
    var found: [String] = []
    func check(_ node: PaneNode, parentAxis: SplitAxis?) {
        guard case .split(let axis, let children, let shares) = node else { return }
        if children.count < 2 { found.append("a split with \(children.count) child") }
        if children.count != shares.count { found.append("\(children.count) children but \(shares.count) shares") }
        if axis == parentAxis { found.append("a split directly inside one along the same axis") }
        if shares.contains(where: { !($0 > 0) }) { found.append("a share that isn't positive: \(shares)") }
        let total = shares.reduce(0, +)
        if abs(total - 1) > 1e-9 { found.append("shares adding up to \(total)") }
        children.forEach { check($0, parentAxis: axis) }
    }
    check(layout.root, parentAxis: nil)

    let leaves = layout.leaves
    if Set(leaves).count != leaves.count { found.append("a pane that appears twice") }
    if !leaves.contains(layout.focused) { found.append("focus on a pane that isn't there") }
    let ghosts = Set(layout.sessions).subtracting(tabs)
    if !ghosts.isEmpty { found.append("\(ghosts.count) session(s) on screen that aren't tabs") }

    func dividerCount(_ node: PaneNode) -> Int {
        guard case .split(_, let children, _) = node else { return 0 }
        return children.count - 1 + children.map(dividerCount).reduce(0, +)
    }
    // A window-sized area, and one far too small for its gaps: both must tile.
    for (rect, gap) in [(CGRect(x: 0, y: 0, width: 1280, height: 720), 1.0), (CGRect(x: 3, y: 4, width: 7, height: 5), 2.0)] {
        let frames = layout.frames(in: rect, gap: gap)
        let dividers = layout.dividers(in: rect, gap: gap)
        let size = "\(Int(rect.width))×\(Int(rect.height))"
        if Set(frames.keys) != Set(leaves) { found.append("\(size): frames for \(frames.count) of \(leaves.count) panes") }
        let covered =
            frames.values.map { $0.width * $0.height }.reduce(0, +)
            + dividers.map { $0.rect.width * $0.rect.height }.reduce(0, +)
        if abs(covered - rect.width * rect.height) > 1e-6 { found.append("\(size): panes and gaps cover \(covered) points²") }
        let pieces = Array(frames.values) + dividers.map(\.rect)
        if pieces.contains(where: { !rect.contains($0) || $0.width < 0 || $0.height < 0 }) {
            found.append("\(size): a pane or gap outside the area")
        }
        if dividers.count != dividerCount(layout.root) { found.append("\(size): \(dividers.count) dividers laid out") }
    }
    return found
}

@Suite("Split panes under random use")
struct PaneLayoutFuzzTests {

    @Test(
        "Thousands of random operations never leave a malformed layout",
        arguments: [1, 2, 3, 42, 2026] as [UInt64])
    func randomOperations(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        var tabs = (0..<3).map { _ in UUID() }
        var layout = PaneLayout(session: tabs[0])
        let rect = CGRect(x: 0, y: 0, width: 1280, height: 720)

        for step in 0..<2_000 {
            let operation = Int.random(in: 0..<12, using: &random)
            let leaf = layout.leaves.randomElement(using: &random)!
            let tab = tabs.randomElement(using: &random)!
            var name = ""

            switch operation {
            case 0:
                let zone = DropZone.allCases.randomElement(using: &random)!
                name = "snap to \(zone)"
                if layout.snap(session: tab, to: DropTarget(pane: leaf, zone: zone)) {
                    if layout.focused != .session(tab) || !layout.contains(session: tab) {
                        Issue.record("seed \(seed) step \(step): a snapped session isn't focused and on screen")
                        return
                    }
                }
            case 1:
                name = "remove a pane"
                if layout.remove(pane: leaf), layout.contains(leaf) {
                    Issue.record("seed \(seed) step \(step): a removed pane is still there")
                    return
                }
            case 2:
                name = "click a tab"
                layout.reveal(session: tab)
                if layout.focused != .session(tab) {
                    Issue.record("seed \(seed) step \(step): a clicked tab isn't focused")
                    return
                }
            case 3:
                name = "show in a pane"
                layout.show(session: tab, in: leaf)
            case 4:
                name = "drag a divider"
                if let divider = layout.dividers(in: rect, gap: 1).randomElement(using: &random) {
                    let requested = Double.random(in: -0.2...1.2, using: &random)
                    let mode = ResizeMode.allCases.randomElement(using: &random)!
                    if Bool.random(using: &random) {
                        layout.moveDivider(
                            divider.id, to: requested, mode: mode, length: divider.length,
                            minimumLength: [0, 40, 120].randomElement(using: &random)!)
                    } else {
                        // As the app calls it: room for every nested pane.
                        layout.moveDivider(
                            divider.id, to: requested, mode: mode, length: divider.length,
                            minimumSize: CGSize(width: 120, height: 60), gap: 1)
                    }
                }
            case 5:
                name = "equalize"
                if let divider = layout.dividers(in: rect, gap: 1).randomElement(using: &random) {
                    layout.equalize(splitAt: divider.id.path)
                }
            case 6:
                let template = LayoutTemplate.allCases.randomElement(using: &random)!
                name = "apply \(template)"
                layout.apply(template, focusZone: Int.random(in: 0..<4, using: &random), tabOrder: tabs)
                if layout.matchingTemplate != template {
                    Issue.record("seed \(seed) step \(step): applying \(template) didn't produce it")
                    return
                }
            case 7:
                name = "open a session"
                if tabs.count < 10 {
                    let new = UUID()
                    tabs.append(new)
                    layout.reveal(session: new)
                }
            case 8:
                name = "close a session"
                if tabs.count > 1 {
                    tabs.removeAll { $0 == tab }
                    if !layout.retain(sessions: Set(tabs)) { layout = PaneLayout(session: tabs[0]) }
                }
            case 9:
                name = "reopen a session"
                if let old = layout.sessions.randomElement(using: &random) {
                    let new = UUID()
                    tabs[tabs.firstIndex(of: old)!] = new
                    layout.replace(session: old, with: new)
                }
            case 10:
                name = "focus a pane"
                layout.focus(leaf)
            default:
                name = "drop at a random point"
                let point = CGPoint(
                    x: Double.random(in: -10...1290, using: &random), y: Double.random(in: -10...730, using: &random))
                if let target = layout.dropTarget(
                    at: point, in: rect, gap: 1, minimumSize: CGSize(width: 120, height: 60))
                {
                    layout.snap(session: tab, to: target)
                }
            }

            let found = problems(in: layout, tabs: tabs)
            if !found.isEmpty {
                Issue.record("seed \(seed) step \(step), after “\(name)”: \(found.joined(separator: "; "))")
                return
            }
        }
    }
}
