//
//  LayoutTemplate.swift
//  Ready-made arrangements, as Windows' Snap Layouts offers them: pick a
//  template and the zone the focused session goes in; the other sessions fill
//  the remaining zones, and any zone left over stays empty for you to fill.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation

public enum LayoutTemplate: String, CaseIterable, Identifiable, Sendable {
    case single
    case halves
    case stacked
    case mainAndSide
    case thirds
    case mainAndStack
    case quarters

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .single: "Single"
        case .halves: "Two Columns"
        case .stacked: "Two Rows"
        case .mainAndSide: "Two Thirds and One Third"
        case .thirds: "Three Columns"
        case .mainAndStack: "Half and Two Quarters"
        case .quarters: "Four Quarters"
        }
    }

    public var zoneCount: Int {
        switch self {
        case .single: 1
        case .halves, .stacked, .mainAndSide: 2
        case .thirds, .mainAndStack: 3
        case .quarters: 4
        }
    }

    /// The zones in reading order, as parts of a unit square — what the picker
    /// draws. Derived from the same tree the template builds, so the picture
    /// can't disagree with the result.
    public var zones: [CGRect] {
        let contents = (0..<zoneCount).map { _ in PaneContent.empty(UUID()) }
        let side = 1200.0  // divisible by 2, 3 and 4, so rounding never shows
        let frames = PaneLayout(root: node(contents), focused: contents[0])
            .frames(in: CGRect(x: 0, y: 0, width: side, height: side))
        return contents.map { content in
            let frame = frames[content]!
            return CGRect(
                x: frame.minX / side, y: frame.minY / side, width: frame.width / side, height: frame.height / side)
        }
    }

    /// The tree for this template, its zones filled with `contents` in reading
    /// order. `contents` must have `zoneCount` elements.
    func node(_ contents: [PaneContent]) -> PaneNode {
        let leaves = contents.map(PaneNode.leaf)
        switch self {
        case .single:
            return leaves[0]
        case .halves:
            return .split(.horizontal, [leaves[0], leaves[1]], [1.0 / 2, 1.0 / 2])
        case .stacked:
            return .split(.vertical, [leaves[0], leaves[1]], [1.0 / 2, 1.0 / 2])
        case .mainAndSide:
            return .split(.horizontal, [leaves[0], leaves[1]], [2.0 / 3, 1.0 / 3])
        case .thirds:
            return .split(.horizontal, [leaves[0], leaves[1], leaves[2]], [1.0 / 3, 1.0 / 3, 1.0 / 3])
        case .mainAndStack:
            return .split(
                .horizontal,
                [leaves[0], .split(.vertical, [leaves[1], leaves[2]], [1.0 / 2, 1.0 / 2])],
                [1.0 / 2, 1.0 / 2])
        case .quarters:
            return .split(
                .vertical,
                [
                    .split(.horizontal, [leaves[0], leaves[1]], [1.0 / 2, 1.0 / 2]),
                    .split(.horizontal, [leaves[2], leaves[3]], [1.0 / 2, 1.0 / 2]),
                ],
                [1.0 / 2, 1.0 / 2])
        }
    }
}

extension PaneLayout {
    /// A layout from a template. `focus` goes into zone `focusZone`; the other
    /// `sessions` fill the remaining zones in order; zones still left are empty.
    /// Sessions beyond the zones aren't shown (they stay tabs).
    public init(
        template: LayoutTemplate, sessions: [UUID], focus: UUID? = nil, focusZone: Int = 0
    ) {
        var seen = Set<UUID>()
        var queue = sessions.filter { $0 != focus && seen.insert($0).inserted }
        let zone = min(max(focusZone, 0), template.zoneCount - 1)
        var contents: [PaneContent] = []
        for index in 0..<template.zoneCount {
            if index == zone, let focus {
                contents.append(.session(focus))
            } else if !queue.isEmpty {
                contents.append(.session(queue.removeFirst()))
            } else {
                contents.append(.empty(UUID()))
            }
        }
        self.init(root: template.node(contents), focused: contents[zone])
    }

    /// Rearranges into `template`, keeping the focused session focused and in
    /// `focusZone`. Sessions on screen keep priority over hidden tabs, in
    /// reading order, then the rest in `tabOrder`.
    public mutating func apply(
        _ template: LayoutTemplate, focusZone: Int = 0, tabOrder: [UUID]
    ) {
        let onScreen = sessions
        let hidden = tabOrder.filter { !onScreen.contains($0) }
        self = PaneLayout(
            template: template, sessions: onScreen + hidden, focus: focusedSession, focusZone: focusZone)
    }

    /// The template this layout currently has the exact shape of, if any.
    public var matchingTemplate: LayoutTemplate? {
        let contents = leaves
        return LayoutTemplate.allCases.first { template in
            template.zoneCount == contents.count && Self.sameShape(template.node(contents), root)
        }
    }

    static func sameShape(_ a: PaneNode, _ b: PaneNode) -> Bool {
        switch (a, b) {
        case (.leaf, .leaf):
            return true
        case (.split(let axisA, let childrenA, let sharesA), .split(let axisB, let childrenB, let sharesB)):
            return axisA == axisB && childrenA.count == childrenB.count
                && zip(sharesA, sharesB).allSatisfy { abs($0 - $1) < 1e-6 }
                && zip(childrenA, childrenB).allSatisfy { sameShape($0, $1) }
        default:
            return false
        }
    }
}
