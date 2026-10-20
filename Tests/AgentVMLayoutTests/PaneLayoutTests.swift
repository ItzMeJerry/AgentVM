//
//  PaneLayoutTests.swift
//  Split panes: what snapping a session to an edge does, what a template
//  builds, how dividers snap or move freely, and where a drop lands. Read as a
//  list, the test names are the specification of the feature.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentVMLayout

// MARK: - Helpers

private func s(_ id: UUID) -> PaneContent { .session(id) }

/// The shares of a split node, or nil for a leaf.
private func shares(_ node: PaneNode) -> [Double]? {
    if case .split(_, _, let shares) = node { return shares }
    return nil
}

private func children(_ node: PaneNode) -> [PaneNode] {
    if case .split(_, let children, _) = node { return children }
    return []
}

private func axis(_ node: PaneNode) -> SplitAxis? {
    if case .split(let axis, _, _) = node { return axis }
    return nil
}

private func approx(_ a: [Double]?, _ b: [Double], tolerance: Double = 1e-9) -> Bool {
    guard let a, a.count == b.count else { return false }
    return zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

/// A side-by-side pair, built the way a user builds it: drag b onto a's right.
private func pair(_ a: UUID, _ b: UUID) -> PaneLayout {
    var layout = PaneLayout(session: a)
    layout.snap(session: b, to: DropTarget(pane: s(a), zone: .right))
    return layout
}

private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

// MARK: - Snapping sessions

@Suite("Snapping sessions into panes")
struct SnappingTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test("One session fills the whole area")
    func single() {
        let layout = PaneLayout(session: a)
        #expect(layout.leaves == [s(a)])
        #expect(layout.focused == s(a))
        #expect(!layout.isSplit)
        #expect(layout.frames(in: area) == [s(a): area])
        #expect(layout.dividers(in: area).isEmpty)
    }

    @Test("Dropping a session on a pane's right edge splits it in half, the session on the right")
    func dropRight() {
        let layout = pair(a, b)
        #expect(layout.root == .split(.horizontal, [.leaf(s(a)), .leaf(s(b))], [0.5, 0.5]))
        #expect(layout.focused == s(b), "the session you dropped takes the keyboard")
    }

    @Test(
        "Each edge puts the session on that side",
        arguments: [
            (DropZone.left, SplitAxis.horizontal, true),
            (DropZone.right, SplitAxis.horizontal, false),
            (DropZone.top, SplitAxis.vertical, true),
            (DropZone.bottom, SplitAxis.vertical, false),
        ])
    func eachEdge(zone: DropZone, expectedAxis: SplitAxis, droppedFirst: Bool) {
        var layout = PaneLayout(session: a)
        let changed1 = layout.snap(session: b, to: DropTarget(pane: s(a), zone: zone))
        #expect(changed1)
        #expect(axis(layout.root) == expectedAxis)
        #expect(layout.leaves == (droppedFirst ? [s(b), s(a)] : [s(a), s(b)]))
        #expect(approx(shares(layout.root), [0.5, 0.5]))
    }

    @Test("A third pane along the same axis joins the split rather than nesting inside it")
    func sameAxisFlattens() {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .right))
        #expect(layout.root == .split(.horizontal, [.leaf(s(a)), .leaf(s(b)), .leaf(s(c))], [0.5, 0.25, 0.25]))
    }

    @Test("A drop across the split's axis nests a split inside that one pane")
    func crossAxisNests() {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .bottom))
        #expect(
            layout.root
                == .split(
                    .horizontal,
                    [.leaf(s(a)), .split(.vertical, [.leaf(s(b)), .leaf(s(c))], [0.5, 0.5])],
                    [0.5, 0.5]))
    }

    @Test("Dropping onto the center of a pane swaps two sessions that are both on screen")
    func centerSwaps() {
        var layout = pair(a, b)
        let changed2 = layout.snap(session: a, to: DropTarget(pane: s(b), zone: .center))
        #expect(changed2)
        #expect(layout.leaves == [s(b), s(a)])
        #expect(layout.focused == s(a))
    }

    @Test("Dropping a hidden session onto the center of a pane replaces what it shows")
    func centerReplaces() {
        var layout = pair(a, b)
        let changed3 = layout.snap(session: c, to: DropTarget(pane: s(a), zone: .center))
        #expect(changed3)
        #expect(layout.leaves == [s(c), s(b)])
        #expect(!layout.contains(session: a), "a is still a tab, just not on screen")
    }

    @Test("A session dropped onto its own pane changes nothing", arguments: DropZone.allCases)
    func ontoItself(zone: DropZone) {
        var layout = pair(a, b)
        let before = layout
        let changed4 = layout.snap(session: b, to: DropTarget(pane: s(b), zone: zone))
        #expect(!changed4)
        #expect(layout == before)
    }

    @Test("A drop onto a pane that isn't on screen is refused")
    func unknownTarget() {
        var layout = pair(a, b)
        let before = layout
        let changed5 = layout.snap(session: c, to: DropTarget(pane: s(d), zone: .left))
        #expect(!changed5)
        #expect(layout == before)
    }

    @Test("Moving a session that's on screen leaves no gap where it was")
    func moveVisible() {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .right))  // a | b | c
        let changed6 = layout.snap(session: a, to: DropTarget(pane: s(c), zone: .bottom))
        #expect(changed6)
        // a's half went to b and c in proportion; then c was split for a.
        #expect(
            layout.root
                == .split(
                    .horizontal,
                    [.leaf(s(b)), .split(.vertical, [.leaf(s(c)), .leaf(s(a))], [0.5, 0.5])],
                    [0.5, 0.5]))
        #expect(Set(layout.sessions) == [a, b, c], "every session still appears exactly once")
    }

    @Test("Snapping a session beside the only other pane re-pairs them on the new side")
    func moveWithinPair() {
        var layout = pair(a, b)
        let changed7 = layout.snap(session: a, to: DropTarget(pane: s(b), zone: .right))
        #expect(changed7)
        #expect(layout.leaves == [s(b), s(a)])
        #expect(approx(shares(layout.root), [0.5, 0.5]))
    }
}

// MARK: - Removing panes

@Suite("Removing panes")
struct RemovingTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func threeColumns() -> PaneLayout {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .right))  // .5 .25 .25
        return layout
    }

    @Test("A removed pane's space goes to the others in proportion to their size")
    func proportional() {
        var first = threeColumns()
        let changed8 = first.remove(pane: .session(a))
        #expect(changed8)
        #expect(approx(shares(first.root), [0.5, 0.5]))

        var middle = threeColumns()
        let changed9 = middle.remove(pane: .session(b))
        #expect(changed9)
        #expect(approx(shares(middle.root), [2.0 / 3, 1.0 / 3]))
        #expect(middle.leaves == [s(a), s(c)])
    }

    @Test("A split left with one pane collapses into that pane")
    func collapses() {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .bottom))  // a | (b / c)
        let changed10 = layout.remove(pane: .session(c))
        #expect(changed10)
        #expect(layout.root == .split(.horizontal, [.leaf(s(a)), .leaf(s(b))], [0.5, 0.5]))
    }

    @Test("A collapsing split flattens into a parent that runs the same way")
    func flattens() {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .bottom))  // a | (b / c)
        layout.snap(session: d, to: DropTarget(pane: s(c), zone: .right))  // a | (b / (c | d))
        let changed11 = layout.remove(pane: .session(b))
        #expect(changed11)
        // (c | d) is now directly inside a horizontal split: it joins it.
        #expect(layout.root == .split(.horizontal, [.leaf(s(a)), .leaf(s(c)), .leaf(s(d))], [0.5, 0.25, 0.25]))
    }

    @Test("The last pane can't be removed")
    func lastPane() {
        var layout = PaneLayout(session: a)
        let changed12 = layout.remove(pane: .session(a))
        #expect(!changed12)
        #expect(layout.leaves == [s(a)])
    }

    @Test("Removing a session that isn't on screen changes nothing")
    func notOnScreen() {
        var layout = pair(a, b)
        let before = layout
        let changed13 = layout.remove(pane: .session(c))
        #expect(!changed13)
        #expect(layout == before)
    }

    @Test("When the focused pane goes, the neighbour that took its space takes the focus")
    func focusMoves() {
        var layout = threeColumns()
        layout.focus(s(b))
        layout.remove(pane: .session(b))
        #expect(layout.focused == s(a), "the pane before it")

        var first = threeColumns()
        first.focus(s(a))
        first.remove(pane: .session(a))
        #expect(first.focused == s(b), "or the one after, if it was first")

        var other = threeColumns()
        other.focus(s(c))
        other.remove(pane: .session(a))
        #expect(other.focused == s(c), "removing another pane leaves the focus alone")
    }

    @Test("Closed sessions lose their panes; empty zones stay")
    func retain() {
        var layout = PaneLayout(template: .quarters, sessions: [a, b])
        let changed14 = layout.retain(sessions: [a])
        #expect(changed14)
        #expect(layout.sessions == [a])
        #expect(layout.leaves.filter(\.isEmpty).count == 2)

        var lone = PaneLayout(session: a)
        let changed15 = lone.retain(sessions: [])
        #expect(!changed15, "nothing would be left: the caller starts over")
    }

    @Test("A reopened session takes its predecessor's pane, and its focus")
    func replace() {
        var layout = pair(a, b)
        layout.focus(s(a))
        let changed16 = layout.replace(session: a, with: c)
        #expect(changed16)
        #expect(layout.leaves == [s(c), s(b)])
        #expect(layout.focused == s(c))
        let changed17 = layout.replace(session: d, with: a)
        #expect(!changed17, "a session that isn't on screen can't be replaced")
        let changed18 = layout.replace(session: b, with: c)
        #expect(!changed18, "nor can a session take a second pane")
    }
}

// MARK: - Tabs and focus

@Suite("Tabs and focus")
struct TabTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test("Clicking the tab of a session that's on screen focuses its pane")
    func revealVisible() {
        var layout = pair(a, b)
        layout.reveal(session: a)
        #expect(layout.focused == s(a))
        #expect(layout.leaves == [s(a), s(b)], "nothing moves")
    }

    @Test("Clicking a hidden tab shows it in the focused pane")
    func revealHidden() {
        var layout = pair(a, b)
        layout.focus(s(a))
        layout.reveal(session: c)
        #expect(layout.leaves == [s(c), s(b)])
        #expect(layout.focused == s(c))
    }

    @Test("A hidden tab fills an empty zone that has the focus")
    func revealIntoEmpty() throws {
        var layout = PaneLayout(template: .halves, sessions: [a])
        let empty = try #require(layout.leaves.last)
        #expect(empty.isEmpty)
        layout.focus(empty)
        layout.reveal(session: b)
        #expect(layout.leaves == [s(a), s(b)])
    }

    @Test("Choosing a session for an empty zone puts it there; one on screen moves over")
    func showInEmpty() throws {
        var layout = PaneLayout(template: .quarters, sessions: [a])
        let zones = layout.leaves
        let changed19 = layout.show(session: b, in: zones[2])
        #expect(changed19)
        #expect(layout.leaves[2] == s(b))
        let changed20 = layout.show(session: a, in: zones[3])
        #expect(changed20)
        #expect(layout.leaves[3] == s(a))
        #expect(layout.leaves[0] == zones[3], "the empty zone took a's old place")
    }

    @Test("Focusing a pane that isn't there is refused")
    func focusUnknown() {
        var layout = pair(a, b)
        let changed21 = layout.focus(s(c))
        #expect(!changed21)
        #expect(layout.focused == s(b))
    }
}

// MARK: - Templates

@Suite("Layout templates")
struct TemplateTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test("Every template's zones cover the square exactly once", arguments: LayoutTemplate.allCases)
    func zonesTile(template: LayoutTemplate) {
        let zones = template.zones
        #expect(zones.count == template.zoneCount)
        let total = zones.map { $0.width * $0.height }.reduce(0, +)
        #expect(approx(total, 1, tolerance: 1e-9))
        for zone in zones {
            #expect(zone.minX >= 0 && zone.minY >= 0 && zone.maxX <= 1 + 1e-12 && zone.maxY <= 1 + 1e-12)
        }
        for i in zones.indices {
            for j in zones.indices where j > i {
                let overlap = zones[i].intersection(zones[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 1e-12)
            }
        }
    }

    @Test("Zones are numbered in reading order")
    func readingOrder() {
        let quarters = LayoutTemplate.quarters.zones
        #expect(quarters[0].origin == .zero)
        #expect(approx(quarters[1].minX, 0.5) && approx(quarters[1].minY, 0))
        #expect(approx(quarters[2].minX, 0) && approx(quarters[2].minY, 0.5))
        #expect(approx(quarters[3].minX, 0.5) && approx(quarters[3].minY, 0.5))

        let thirds = LayoutTemplate.thirds.zones
        #expect(thirds.map(\.minX).sorted() == thirds.map(\.minX))
        #expect(approx(thirds[1].minX, 1.0 / 3) && approx(thirds[2].minX, 2.0 / 3))

        let main = LayoutTemplate.mainAndSide.zones
        #expect(approx(main[0].width, 2.0 / 3) && approx(main[1].width, 1.0 / 3))

        let stack = LayoutTemplate.mainAndStack.zones
        #expect(approx(stack[0].height, 1) && approx(stack[1].height, 0.5) && approx(stack[2].minY, 0.5))
    }

    @Test("The focused session goes into the zone you pick; the others fill the rest in order")
    func focusZone() {
        let layout = PaneLayout(template: .quarters, sessions: [a, b, c], focus: b, focusZone: 2)
        #expect(Array(layout.leaves.prefix(3)) == [s(a), s(c), s(b)])
        #expect(layout.leaves[3].isEmpty)
        #expect(layout.focused == s(b))
    }

    @Test("Zones nobody fills stay empty, and sessions beyond the zones stay tabs")
    func filling() {
        let quarters = PaneLayout(template: .quarters, sessions: [a])
        #expect(quarters.sessions == [a])
        #expect(quarters.leaves.filter(\.isEmpty).count == 3)

        let halves = PaneLayout(template: .halves, sessions: [a, b, c, d, e])
        #expect(halves.sessions == [a, b])
    }

    @Test("A session listed twice still gets one zone")
    func duplicates() {
        let layout = PaneLayout(template: .thirds, sessions: [a, a, b])
        #expect(layout.sessions == [a, b])
        #expect(layout.leaves[2].isEmpty)
    }

    @Test("Applying a template keeps the sessions on screen ahead of hidden tabs")
    func applyKeepsVisibleFirst() {
        var layout = pair(c, a)  // c | a, a focused
        layout.focus(s(c))
        layout.apply(.thirds, tabOrder: [a, b, c, d])
        #expect(layout.leaves == [s(c), s(a), s(b)])
        #expect(layout.focused == s(c))
    }

    @Test("Applying Single keeps only the focused session")
    func applySingle() {
        var layout = pair(a, b)
        layout.apply(.single, tabOrder: [a, b])
        #expect(layout.leaves == [s(b)])
    }

    @Test("A layout knows which template it has the shape of", arguments: LayoutTemplate.allCases)
    func recognizes(template: LayoutTemplate) {
        let layout = PaneLayout(template: template, sessions: [a, b, c, d])
        #expect(layout.matchingTemplate == template)
    }

    @Test("Dragging a divider off the template's shape stops it matching")
    func stopsMatching() throws {
        var layout = PaneLayout(template: .halves, sessions: [a, b])
        let divider = try #require(layout.dividers(in: area).first)
        layout.moveDivider(divider.id, to: 1.0 / 3, mode: .snap, length: divider.length, minimumLength: 0)
        #expect(layout.matchingTemplate == nil)
    }

    @Test("Every template starts with its dividers on snap points", arguments: LayoutTemplate.allCases)
    func templatesOnSnapPoints(template: LayoutTemplate) {
        let layout = PaneLayout(template: template, sessions: [a, b, c, d])
        func check(_ node: PaneNode) {
            guard case .split(_, let children, let shares) = node else { return }
            var boundary = 0.0
            let points = PaneLayout.snapPoints(splitting: children.count)
            for share in shares.dropLast() {
                boundary += share
                #expect(points.contains { abs($0 - boundary) < 1e-9 }, "\(template): \(boundary)")
            }
            children.forEach(check)
        }
        check(layout.root)
    }
}

// MARK: - Dividers

@Suite("Dividers")
struct DividerTests {
    let a = UUID(), b = UUID(), c = UUID()

    private func halves() -> PaneLayout { PaneLayout(template: .halves, sessions: [a, b]) }
    /// The one divider of `halves()`.
    private let middle = DividerID(path: [], index: 0)

    @Test(
        "In snap mode a divider lands on the nearest half, third or quarter",
        arguments: [(0.45, 0.5), (0.30, 1.0 / 3), (0.28, 0.25), (0.05, 0.25), (0.70, 2.0 / 3), (0.95, 0.75)])
    func snaps(requested: Double, expected: Double) {
        var layout = halves()
        layout.moveDivider(middle, to: requested, mode: .snap, length: 1000, minimumLength: 0)
        #expect(approx(shares(layout.root), [expected, 1 - expected]))
    }

    @Test("Snap mode never squeezes a pane below the minimum size")
    func snapRespectsMinimum() {
        var layout = halves()
        // 300 of 1000 points each: a quarter (250) would be too small.
        layout.moveDivider(middle, to: 0.25, mode: .snap, length: 1000, minimumLength: 300)
        #expect(approx(shares(layout.root), [1.0 / 3, 2.0 / 3]))
    }

    @Test("In free mode a divider goes exactly where it's dragged")
    func free() {
        var layout = halves()
        let changed22 = layout.moveDivider(middle, to: 0.437, mode: .free, length: 1000, minimumLength: 100)
        #expect(changed22)
        #expect(approx(shares(layout.root), [0.437, 0.563]))
    }

    @Test("In free mode a divider stops at the minimum size")
    func freeClamps() {
        var layout = halves()
        layout.moveDivider(middle, to: 0.01, mode: .free, length: 1000, minimumLength: 100)
        #expect(approx(shares(layout.root), [0.1, 0.9]))
        layout.moveDivider(middle, to: 1.5, mode: .free, length: 1000, minimumLength: 100)
        #expect(approx(shares(layout.root), [0.9, 0.1]))
    }

    @Test("Moving one divider leaves the panes beyond its neighbours alone")
    func localMove() {
        var layout = PaneLayout(template: .thirds, sessions: [a, b, c])
        let first = layout.dividers(in: area)[0]
        layout.moveDivider(first.id, to: 0.26, mode: .snap, length: 1000, minimumLength: 0)
        #expect(approx(shares(layout.root), [0.25, 1.0 / 3 + 1.0 / 12, 1.0 / 3]))
    }

    @Test("A divider is never dragged past its neighbour")
    func neverCrosses() {
        var layout = PaneLayout(template: .thirds, sessions: [a, b, c])
        let first = layout.dividers(in: area)[0]
        layout.moveDivider(first.id, to: 0.9, mode: .free, length: 1000, minimumLength: 50)
        // The second divider is at 2/3: the first stops 50 points short of it.
        #expect(approx(shares(layout.root)![0], 2.0 / 3 - 0.05))
        #expect(approx(shares(layout.root)![2], 1.0 / 3), "the far pane didn't move")
    }

    @Test("A divider that doesn't move reports no change")
    func noChange() {
        var layout = halves()
        let changed23 = layout.moveDivider(middle, to: 0.5, mode: .snap, length: 1000, minimumLength: 0)
        #expect(!changed23)
        let changed24 = layout.moveDivider(middle, to: 0.51, mode: .snap, length: 1000, minimumLength: 0)
        #expect(!changed24)
        let changed25 = layout.moveDivider(DividerID(path: [7], index: 0), to: 0.3, mode: .free, length: 1000, minimumLength: 0)
        #expect(!changed25)
        let changed26 = layout.moveDivider(DividerID(path: [], index: 1), to: 0.3, mode: .free, length: 1000, minimumLength: 0)
        #expect(!changed26)
    }

    @Test("When no snap point leaves room for both panes, the divider stays put")
    func noRoom() {
        var layout = halves()
        // 450 points minimum each in 1000: only 0.45–0.55 is allowed, and the
        // only snap point there is where it already is.
        let changed27 = layout.moveDivider(middle, to: 0.2, mode: .snap, length: 1000, minimumLength: 450)
        #expect(!changed27)
        #expect(approx(shares(layout.root), [0.5, 0.5]))
    }

    @Test("Double-clicking a divider evens out its split")
    func equalize() {
        var layout = PaneLayout(template: .thirds, sessions: [a, b, c])
        let first = layout.dividers(in: area)[0]
        layout.moveDivider(first.id, to: 0.25, mode: .snap, length: 1000, minimumLength: 0)
        let changed28 = layout.equalize(splitAt: first.id.path)
        #expect(changed28)
        #expect(approx(shares(layout.root), [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let changed29 = layout.equalize(splitAt: first.id.path)
        #expect(!changed29, "already even")
        let changed30 = layout.equalize(splitAt: [0])
        #expect(!changed30, "a leaf is not a split")
    }

    @Test("Snap points include equal shares for however many panes the split has")
    func snapPoints() {
        let five = PaneLayout.snapPoints(splitting: 5)
        for point in [0.2, 0.25, 1.0 / 3, 0.4, 0.5, 0.6, 2.0 / 3, 0.75, 0.8] {
            #expect(five.contains { abs($0 - point) < 1e-12 }, "\(point)")
        }
        #expect(five == five.sorted())
        #expect(Set(five.map { ($0 * 1e9).rounded() }).count == five.count, "no duplicates")
        #expect(PaneLayout.snapPoints(splitting: 2).count == 5, "a half is both familiar and equal")
    }

    @Test("A divider leaves room for every pane nested beside it, not just its neighbour")
    func nestedRoom() throws {
        // a | (b / (c | d)): the right side holds c and d side by side.
        var layout = pair(a, b)
        let d = UUID()
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .bottom))
        layout.snap(session: d, to: DropTarget(pane: s(c), zone: .right))
        let outer = try #require(layout.dividers(in: area).first { $0.id.path.isEmpty })
        let changed = layout.moveDivider(
            outer.id, to: 0.9, mode: .free, length: 1000, minimumSize: CGSize(width: 200, height: 50))
        #expect(changed)
        // c and d need 200 each: the right side keeps 400 of 1000.
        #expect(approx(shares(layout.root), [0.6, 0.4]))
    }

    @Test("Panes along an axis add up their minimums; panes across it need only the largest")
    func minimumLength() {
        let size = CGSize(width: 100, height: 40)
        let leaf = PaneNode.leaf(.empty(UUID()))
        let row = PaneNode.split(.horizontal, [leaf, leaf, leaf], [1.0 / 3, 1.0 / 3, 1.0 / 3])
        let column = PaneNode.split(.vertical, [leaf, row], [0.5, 0.5])
        #expect(PaneLayout.minimumLength(of: leaf, along: .horizontal, minimumSize: size) == 100)
        #expect(PaneLayout.minimumLength(of: leaf, along: .vertical, minimumSize: size) == 40)
        #expect(PaneLayout.minimumLength(of: row, along: .horizontal, minimumSize: size, gap: 2) == 304)
        #expect(PaneLayout.minimumLength(of: row, along: .vertical, minimumSize: size, gap: 2) == 40)
        #expect(PaneLayout.minimumLength(of: column, along: .horizontal, minimumSize: size, gap: 2) == 304)
        #expect(PaneLayout.minimumLength(of: column, along: .vertical, minimumSize: size, gap: 2) == 82)
    }

    @Test("When a pair can't give both sides their minimum, they share the space in proportion")
    func proportionalMinimums() throws {
        var layout = PaneLayout(template: .halves, sessions: [a, b])
        let changed = layout.moveDivider(
            DividerID(path: [], index: 0), to: 0.9, mode: .free, length: 1000,
            minimumBefore: 900, minimumAfter: 300)
        #expect(changed)
        // 1200 needed, 1000 there: 3/4 and 1/4, and the divider can't go further.
        #expect(approx(shares(layout.root), [0.75, 0.25]))
    }

    @Test("A nested divider belongs to its own split, and moving it leaves the outer one alone")
    func nested() throws {
        var layout = PaneLayout(template: .mainAndStack, sessions: [a, b, c])
        let dividers = layout.dividers(in: area)
        #expect(Set(dividers.map(\.id)) == [DividerID(path: [], index: 0), DividerID(path: [1], index: 0)])
        let inner = try #require(dividers.first { $0.id.path == [1] })
        #expect(inner.axis == .vertical)
        layout.moveDivider(inner.id, to: 0.25, mode: .snap, length: inner.length, minimumLength: 0)
        #expect(approx(shares(layout.root), [0.5, 0.5]))
        #expect(approx(shares(children(layout.root)[1]), [0.25, 0.75]))
    }
}

// MARK: - Geometry

@Suite("Pane geometry")
struct GeometryTests {
    let ids = (0..<4).map { _ in UUID() }

    @Test(
        "Panes and the gaps between them cover the area with nothing left over",
        arguments: LayoutTemplate.allCases, [0.0, 1.0, 3.0])
    func tiles(template: LayoutTemplate, gap: Double) {
        let layout = PaneLayout(template: template, sessions: ids)
        let rect = CGRect(x: 20, y: 40, width: 1001, height: 667)
        let frames = layout.frames(in: rect, gap: gap)
        let dividers = layout.dividers(in: rect, gap: gap)
        #expect(frames.count == layout.leaves.count)
        #expect(Set(frames.keys) == Set(layout.leaves))
        for frame in frames.values { #expect(rect.contains(frame)) }
        let paneArea = frames.values.map { $0.width * $0.height }.reduce(0, +)
        let gapArea = dividers.map { $0.rect.width * $0.rect.height }.reduce(0, +)
        #expect(approx(paneArea + gapArea, rect.width * rect.height, tolerance: 1e-6))
        let all = Array(frames.values) + dividers.map(\.rect)
        for i in all.indices {
            for j in all.indices where j > i {
                let overlap = all[i].intersection(all[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 1e-9)
            }
        }
    }

    @Test(
        "In an area too small for its gaps, panes and gaps still cover it exactly and stay inside it",
        arguments: LayoutTemplate.allCases)
    func tooSmall(template: LayoutTemplate) {
        let layout = PaneLayout(template: template, sessions: ids)
        let rect = CGRect(x: 5, y: 5, width: 2, height: 3)  // smaller than the 4-point gaps
        let frames = layout.frames(in: rect, gap: 4)
        let dividers = layout.dividers(in: rect, gap: 4)
        for frame in Array(frames.values) + dividers.map(\.rect) {
            #expect(frame.width >= 0 && frame.height >= 0)
            #expect(rect.contains(frame), "\(template): \(frame) is outside \(rect)")
        }
        let covered =
            frames.values.map { $0.width * $0.height }.reduce(0, +)
            + dividers.map { $0.rect.width * $0.rect.height }.reduce(0, +)
        #expect(approx(covered, rect.width * rect.height, tolerance: 1e-9))
    }

    @Test("Pane edges land on whole points", arguments: LayoutTemplate.allCases)
    func wholePoints(template: LayoutTemplate) {
        let layout = PaneLayout(template: template, sessions: ids)
        for frame in layout.frames(in: CGRect(x: 0, y: 0, width: 997, height: 613), gap: 1).values {
            for value in [frame.minX, frame.minY, frame.maxX, frame.maxY] {
                #expect(value == value.rounded(), "\(template): \(value)")
            }
        }
    }

    @Test("Each divider sits exactly in the gap between the panes it separates")
    func dividerBetweenPanes() throws {
        let layout = PaneLayout(template: .halves, sessions: ids)
        let frames = layout.frames(in: area, gap: 1)
        let divider = try #require(layout.dividers(in: area, gap: 1).first)
        let left = try #require(frames[.session(ids[0])])
        let right = try #require(frames[.session(ids[1])])
        #expect(divider.rect.minX == left.maxX)
        #expect(divider.rect.maxX == right.minX)
        #expect(divider.rect.width == 1)
        #expect(divider.length == 999, "the length panes share, without the gap")
        #expect(approx(divider.boundary, 0.5))
    }
}

// MARK: - Drop zones

@Suite("Drop zones")
struct DropZoneTests {
    let pane = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test(
        "Each edge of a pane is its own zone, and the middle is the center",
        arguments: [
            (CGPoint(x: 10, y: 150), DropZone.left),
            (CGPoint(x: 390, y: 150), DropZone.right),
            (CGPoint(x: 200, y: 10), DropZone.top),
            (CGPoint(x: 200, y: 290), DropZone.bottom),
            (CGPoint(x: 200, y: 150), DropZone.center),
            (CGPoint(x: 250, y: 170), DropZone.center),
        ])
    func zones(point: CGPoint, expected: DropZone) {
        #expect(PaneLayout.zone(at: point, in: pane) == expected)
    }

    @Test("Near a corner the closer edge wins, measured against the pane's own shape")
    func corners() {
        let wide = CGRect(x: 0, y: 0, width: 800, height: 200)
        #expect(PaneLayout.zone(at: CGPoint(x: 60, y: 20), in: wide) == .left)  // 7.5% vs 10%
        #expect(PaneLayout.zone(at: CGPoint(x: 100, y: 10), in: wide) == .top)  // 12.5% vs 5%
    }

    @Test("The highlight shows the half a drop would take")
    func preview() {
        #expect(PaneLayout.previewRect(for: .left, in: pane) == CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(PaneLayout.previewRect(for: .right, in: pane) == CGRect(x: 200, y: 0, width: 200, height: 300))
        #expect(PaneLayout.previewRect(for: .top, in: pane) == CGRect(x: 0, y: 0, width: 400, height: 150))
        #expect(PaneLayout.previewRect(for: .bottom, in: pane) == CGRect(x: 0, y: 150, width: 400, height: 150))
        #expect(PaneLayout.previewRect(for: .center, in: pane) == pane)
    }

    @Test("The pane under the pointer is the target, in a split too")
    func targetInSplit() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout(template: .halves, sessions: [a, b])
        #expect(layout.dropTarget(at: CGPoint(x: 900, y: 250), in: area) == DropTarget(pane: .session(b), zone: .right))
        #expect(layout.dropTarget(at: CGPoint(x: 20, y: 300), in: area) == DropTarget(pane: .session(a), zone: .left))
    }

    @Test(
        "A pane too narrow to split side by side takes left and right drops as the center",
        arguments: [CGPoint(x: 5, y: 150), CGPoint(x: 395, y: 150)])
    func narrow(point: CGPoint) {
        let a = UUID()
        let layout = PaneLayout(session: a)
        let target = layout.dropTarget(at: point, in: pane, minimumSize: CGSize(width: 250, height: 50))
        #expect(target == DropTarget(pane: .session(a), zone: .center))
    }

    @Test("A pane too short to split top and bottom takes those drops as the center, but still splits sideways")
    func short() {
        let a = UUID()
        let layout = PaneLayout(session: a)
        let minimum = CGSize(width: 50, height: 200)
        #expect(layout.dropTarget(at: CGPoint(x: 200, y: 5), in: pane, minimumSize: minimum)?.zone == .center)
        #expect(layout.dropTarget(at: CGPoint(x: 200, y: 295), in: pane, minimumSize: minimum)?.zone == .center)
        #expect(layout.dropTarget(at: CGPoint(x: 5, y: 150), in: pane, minimumSize: minimum)?.zone == .left)
    }

    @Test("Outside the panes, and in the gap between them, nothing is a target")
    func outside() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout(template: .halves, sessions: [a, b])
        #expect(layout.dropTarget(at: CGPoint(x: -1, y: 10), in: area) == nil)
        #expect(layout.dropTarget(at: CGPoint(x: 1000, y: 10), in: area) == nil)
        let gap = layout.dividers(in: area, gap: 6)[0].rect
        #expect(layout.dropTarget(at: CGPoint(x: gap.midX, y: 300), in: area, gap: 6) == nil)
    }
}

// MARK: - Closing tabs

@Suite("Closing session tabs")
struct ClosingTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test("Closing the last tab leaves no layout")
    func lastTab() {
        #expect(PaneLayout.closing(a, from: PaneLayout(session: a), remaining: [], at: 0) == nil)
    }

    @Test("Closing the only pane's session shows the neighbouring tab, as a browser does")
    func onlyPane() throws {
        let next = try #require(PaneLayout.closing(b, from: PaneLayout(session: b), remaining: [a, c], at: 1))
        #expect(next.layout.leaves == [.session(c)], "the tab that slid into its place")
        #expect(next.selected == c)

        let last = try #require(PaneLayout.closing(c, from: PaneLayout(session: c), remaining: [a, b], at: 2))
        #expect(last.layout.leaves == [.session(b)], "or the one before, if it was last")
    }

    @Test("Closing a session in a split leaves the other panes where they are")
    func inSplit() throws {
        var layout = pair(a, b)
        layout.snap(session: c, to: DropTarget(pane: s(b), zone: .right))  // a | b | c
        layout.focus(s(b))
        let next = try #require(PaneLayout.closing(b, from: layout, remaining: [a, c, d], at: 1))
        #expect(next.layout.leaves == [s(a), s(c)])
        #expect(next.selected == a, "the pane that took its space has the focus")
    }

    @Test("Closing a tab that isn't on screen changes no pane")
    func hiddenTab() throws {
        let layout = pair(a, b)
        let next = try #require(PaneLayout.closing(c, from: layout, remaining: [a, b], at: 2))
        #expect(next.layout == layout)
        #expect(next.selected == b)
    }

    @Test("When only empty zones would be left, the neighbouring tab fills the focused one")
    func onlyEmptyZonesLeft() throws {
        let layout = PaneLayout(template: .quarters, sessions: [a])  // a, three empty zones
        let next = try #require(PaneLayout.closing(a, from: layout, remaining: [b], at: 0))
        #expect(next.layout.sessions == [b])
        #expect(next.layout.leaves.count == 3, "the empty zones stay for you to fill")
        #expect(next.selected == b)
    }

    @Test("With no layout yet, the neighbour gets one pane")
    func noLayout() throws {
        let next = try #require(PaneLayout.closing(a, from: nil, remaining: [b], at: 0))
        #expect(next.layout.leaves == [.session(b)])
    }
}
